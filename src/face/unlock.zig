// 顔認証: ロック画面で、登録した顔がカメラに写ったらロックを外す。登録もここ(ame-ctl face enroll / ランチャー)。
//
//   ロック画面を触った時(パスワードの入力画面を開いた時)だけ … 別スレッドでカメラを開き、0.15 秒おきに顔を探して
//       特徴を比べる(最長 6 秒)。照合の決まりは ame-face の core.zig(赤外線のみ・近い 2 つの平均 ≥ threshold・3 コマ続けて)。
//       パスワードはいつでも使える(顔認証はその横で動くだけ)。続けて 3 回一致しなければ、パスワードで外すまで使わない(lock.zig)
//   登録 … パスワードで本人を確かめた後(lock.zig の lockForEnroll)、7 秒ほどカメラを見てもらい、
//       向きの違う顔の特徴を最大 12 個 $XDG_DATA_HOME/ame-shell/face.bin(0600)に
//
// ログイン画面(greetd)では、同じ照合を PAM モジュール(ame-face の pam_face.zig)が行う。
//
// モデル(初めて登録するときに取ってきて $XDG_DATA_HOME/ame-shell/models に置く。SHA-256 を確かめる):
//   顔の検出 … MediaPipe の BlazeFace short range(Apache-2.0)
//   顔の特徴 … OpenCV Zoo の SFace(Apache-2.0、ONNX。ame-face の onnx.zig で自作のエンジンの形に直す)
const std = @import("std");
const c = @import("../c.zig");
const App = @import("../core/app.zig").App;
const loop = @import("../platform/loop.zig");
const sys = @import("../platform/sys.zig");
// 顔の検出・特徴・照合の決まりは別のリポジトリ ame-face
const core = @import("ame-face").core;
const face = @import("ame-face").face;

const log = std.log.scoped(.face);

const ENROLL_MS = 7000;

pub const Phase = enum(u8) { idle, loading, scanning, matched, failed };

const Mode = enum(u8) { verify, enroll };

const Code = enum(u8) {
    // 途中の知らせ
    loading,
    downloading,
    scanning,
    progress,
    // 終わり
    matched,
    enrolled,
    no_face,
    no_match,
    no_camera,
    no_ir_camera,
    no_model,
    no_enroll,
    ir_required,
    failed,
    enroll_few,
    enroll_mixed,
    too_dark,
};

const Msg = extern struct {
    code: u8,
    n: u8 = 0,
    _r: [2]u8 = .{ 0, 0 },
    score: f32 = 0,
};

var st: struct {
    app: ?*App = null,
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rfd: c_int = -1,
    wfd: c_int = -1,
    mode: Mode = .verify,
    running: bool = false,
    phase: Phase = .idle,
    /// ロック画面に出す一言
    msg: [160]u8 = undefined,
    msg_len: usize = 0,
    ended_ms: u64 = 0,
    device: [64]u8 = undefined,
    device_len: usize = 0,
    threshold: f32 = core.DEFAULT_THRESHOLD,
    require_ir: bool = true,
    debug: bool = false,
} = .{};

// ---------------------------------------------------------------------------
// メイン側
// ---------------------------------------------------------------------------

pub fn phase() Phase {
    return st.phase;
}

/// ロック画面に出す一言(空なら出さない)
pub fn message() []const u8 {
    return st.msg[0..st.msg_len];
}

fn setMsg(s: []const u8) void {
    const n = @min(s.len, st.msg.len);
    @memcpy(st.msg[0..n], s[0..n]);
    st.msg_len = n;
}

/// ログイン画面(顔の照合は greetd の中の PAM モジュール)から、ロック画面と同じ表示を出すため
pub fn setStatus(p: Phase, s: []const u8) void {
    st.phase = p;
    setMsg(s);
}

/// 顔が登録されているか
pub fn enrolled() bool {
    var pb: [512]u8 = undefined;
    const p = dataPath(&pb, "face.bin") orelse return false;
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

/// ロック画面を触った(lock.zig から): 登録してあれば照合を始める。直前に終わったばかりなら何もしない
pub fn tryUnlock(app: *App) void {
    if (!app.cfg.face_enabled or st.running or !enrolled()) return;
    if (st.phase == .failed and loop.nowMs() -| st.ended_ms < 2500) return;
    start(app, .verify);
}

/// 登録を始める。パスワードで本人を確かめた後に lock.zig(finish)からだけ呼ぶ(ame-ctl / ランチャーは lockForEnroll)
pub fn enroll(app: *App) []const u8 {
    if (st.running) return "error: 顔認証がすでに動いています";
    start(app, .enroll);
    if (!st.running) return "error: 始められませんでした";
    app.osd.info("顔を登録します。カメラを見て、顔を少しずつ左右上下に向けてください");
    return "ok";
}

/// 登録を消す
pub fn clear() []const u8 {
    var pb: [512]u8 = undefined;
    const p = dataPath(&pb, "face.bin") orelse return "error: 場所が分かりません";
    std.fs.cwd().deleteFile(p) catch |e| if (e != error.FileNotFound) return "error: 消せませんでした";
    return "ok";
}

pub fn status(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}", .{ if (enrolled()) "enrolled" else "not-enrolled", @tagName(st.phase) }) catch "?";
}

/// ロックが外れた・やめた: 照合を止める(カメラを閉じる)
pub fn stop() void {
    if (st.running) {
        st.quit.store(true, .release);
        if (st.thread) |t| t.join();
        st.thread = null;
        finish();
    }
    st.phase = .idle;
    st.msg_len = 0;
}

fn finish() void {
    if (st.app) |app| app.loop.remove(st.rfd);
    if (st.rfd >= 0) _ = c.close(st.rfd);
    if (st.wfd >= 0) _ = c.close(st.wfd);
    st.rfd = -1;
    st.wfd = -1;
    st.running = false;
    st.ended_ms = loop.nowMs();
}

fn start(app: *App, mode: Mode) void {
    st.app = app;
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return;
    st.rfd = fds[0];
    st.wfd = fds[1];
    app.loop.add(st.rfd, c.EPOLLIN, app, onMsg) catch {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return;
    };
    const dev = app.cfg.face_camera.get();
    st.device_len = @min(dev.len, st.device.len);
    @memcpy(st.device[0..st.device_len], dev[0..st.device_len]);
    st.threshold = app.cfg.face_threshold;
    st.require_ir = app.cfg.face_require_ir;
    st.debug = std.posix.getenv("AME_DEBUG") != null;
    st.mode = mode;
    st.quit.store(false, .release);
    st.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, worker, .{mode}) catch {
        app.loop.remove(st.rfd);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return;
    };
    st.running = true;
    st.phase = .loading;
    setMsg(if (mode == .verify) "顔を確認しています…" else "顔を登録しています…");
    redraw(app);
}

fn redraw(app: *App) void {
    if (app.lock.locked) app.lock.scheduleAll();
}

fn onMsg(ctx: *anyopaque, fd: c_int, _: u32) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    var m: Msg = undefined;
    var done = false;
    var code: Code = .failed;
    while (c.read(fd, &m, @sizeOf(Msg)) == @sizeOf(Msg)) {
        code = @enumFromInt(m.code);
        if (st.debug) log.info("{s} {d} {d:.3}", .{ @tagName(code), m.n, m.score });
        switch (code) {
            .loading => setMsg(if (st.mode == .verify) "顔を確認しています…" else "顔の認識を準備しています…"),
            .downloading => {
                setMsg("顔の認識のモデルを取ってきています(初回だけ、約 40MB)…");
                if (st.mode == .enroll) app.osd.info("顔の認識のモデルを取ってきています(初回だけ、約 40MB)");
            },
            .scanning => {
                st.phase = .scanning;
                setMsg(if (st.mode == .verify) "顔を確認しています…" else "カメラを見てください");
            },
            .progress => {
                var b: [96]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "顔を登録しています({d}/{d})", .{ m.n, core.MAX_ENROLL }) catch "";
                setMsg(s);
                app.osd.info(s);
            },
            .matched => {
                st.phase = .matched;
                setMsg("顔を確認しました");
                done = true;
            },
            .enrolled => {
                var b: [96]u8 = undefined;
                app.osd.info(std.fmt.bufPrint(&b, "顔を登録しました({d} 枚)。ロック画面を触ると顔で確かめます", .{m.n}) catch "顔を登録しました");
                done = true;
            },
            else => {
                st.phase = .failed;
                setMsg(failText(code));
                if (st.mode == .enroll) app.osd.info(message());
                done = true;
            },
        }
        if (done) break;
    }
    if (done) {
        if (st.thread) |t| t.join();
        st.thread = null;
        finish();
        if (st.mode == .verify) {
            if (st.phase == .matched) app.lock.faceUnlocked() else if (code == .no_match) app.lock.faceRejected();
        }
        if (st.mode == .enroll and st.phase != .failed) {
            st.phase = .idle;
            st.msg_len = 0;
        }
    }
    redraw(app);
}

fn failText(code: Code) []const u8 {
    return switch (code) {
        .no_face => "顔が見つかりませんでした(パスワードを入力するか、もう一度クリック)",
        .no_match => "顔が一致しませんでした(パスワードを入力してください)",
        .no_camera => "カメラを開けませんでした",
        .no_ir_camera => "赤外線カメラが見つかりません(普通のカメラで使うなら face { require_ir off })",
        .no_model => "顔の認識のモデルがありません(ネットワークを確かめてください)",
        .no_enroll => "顔が登録されていません",
        .ir_required => "赤外線カメラで登録した顔だけを使います(登録し直してください)",
        .enroll_few => "顔をうまく撮れませんでした。カメラの正面からもう一度",
        .enroll_mixed => "別の人の顔が混ざったようです。1 人だけで、もう一度登録してください",
        .too_dark => "顔が暗すぎます(赤外線の照明が点かないか、顔が遠いようです)",
        else => "顔認証を始められませんでした",
    };
}

// ---------------------------------------------------------------------------
// スレッド: カメラ → 顔 → 特徴
// ---------------------------------------------------------------------------

fn send(m: Msg) void {
    _ = c.write(st.wfd, &m, @sizeOf(Msg));
}

fn sendCode(code: Code) void {
    send(.{ .code = @intFromEnum(code) });
}

fn sendScore(_: void, s: f32) void {
    if (st.debug) send(.{ .code = @intFromEnum(Code.scanning), .score = s });
}

fn loadEnrolled(a: std.mem.Allocator, out: *core.Enrolled) bool {
    var pb: [512]u8 = undefined;
    const p = dataPath(&pb, "face.bin") orelse return false;
    const data = core.readRegular(a, p, core.FILE_MAX, null) orelse return false;
    return core.parseEnrolled(data, out);
}

fn saveEnrolled(e: *const core.Enrolled) bool {
    var pb: [512]u8 = undefined;
    const p = dataPath(&pb, "face.bin") orelse return false;
    if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
    var buf: [core.FILE_MAX]u8 = undefined;
    const data = core.encodeEnrolled(e, &buf);
    // 本人だけが読み書きできるように(一時ファイルに書いてから置き換える)
    var tb: [520]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.part", .{p}) catch return false;
    const f = std.fs.cwd().createFile(tmp, .{ .mode = 0o600 }) catch return false;
    f.writeAll(data) catch {
        f.close();
        return false;
    };
    f.close();
    std.fs.cwd().rename(tmp, p) catch return false;
    return true;
}

fn worker(mode: Mode) void {
    // 推論のメモリは全部この領域から取り、終わったら丸ごと返す(使うたびに 40MB ほど使って返す)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var known: core.Enrolled = undefined;
    if (mode == .verify and !loadEnrolled(a, &known)) return sendCode(.no_enroll);

    sendCode(.loading);
    const det_b = loadModel(a, core.DET_MODEL) orelse return sendCode(if (st.quit.load(.acquire)) .failed else .no_model);
    const emb_b = loadModel(a, core.EMB_MODEL) orelse return sendCode(if (st.quit.load(.acquire)) .failed else .no_model);
    const eng = core.Engine.create(a, det_b, emb_b) catch |e| {
        log.err("顔の認識のモデルを準備できません: {}", .{e});
        return sendCode(.failed);
    };
    defer eng.deinit();

    var cam = core.openCamera(st.device[0..st.device_len], st.require_ir) orelse
        return sendCode(if (st.require_ir) .no_ir_camera else .no_camera);
    defer cam.close();
    const ir = cam.fmt == .grey;
    log.info("顔認証: カメラ {d}x{d}({s})", .{ cam.w, cam.h, if (ir) "赤外線" else "カラー" });
    sendCode(.scanning);

    if (mode == .verify) {
        const r = core.verify(a, eng, &cam, &known, .{ .threshold = st.threshold, .require_ir = st.require_ir }, &st.quit, {}, sendScore);
        if (st.debug) log.info("顔認証: {s}(一番近かったのは {d:.3})", .{ @tagName(r.outcome), r.best });
        return switch (r.outcome) {
            .matched => send(.{ .code = @intFromEnum(Code.matched), .score = r.best }),
            .cancelled => {},
            .no_face => sendCode(.no_face),
            .no_match => send(.{ .code = @intFromEnum(Code.no_match), .score = r.best }),
            .too_dark => sendCode(.too_dark),
            .ir_required => sendCode(.ir_required),
            .failed => sendCode(.failed),
        };
    }

    // ---- 登録 ----
    const rgb = a.alloc(u8, cam.w * cam.h * 3) catch return sendCode(.failed);
    const img = face.Image{ .rgb = rgb, .w = cam.w, .h = cam.h };
    const t0 = std.time.milliTimestamp();
    var last: i64 = 0;
    var dark_face = false;
    var last_add: i64 = 0;
    var got = core.Enrolled{ .ir = ir, .n = 0, .embs = undefined };
    while (!st.quit.load(.acquire)) {
        const now = std.time.milliTimestamp();
        if (now - t0 > ENROLL_MS) break;
        var pfd = [_]std.posix.pollfd{.{ .fd = cam.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 150) catch break;
        if (now - last < 150) {
            _ = cam.grab(null, false);
            continue;
        }
        if (!cam.grab(rgb, false)) continue;
        last = now;
        switch (eng.look(img, ir)) {
            .none, .small => {},
            .dark => dark_face = true,
            .face => |*e| {
                var near: f32 = -1;
                for (got.embs[0..got.n]) |*k| near = @max(near, face.cosine(k, e));
                // まったく同じ顔(動いていない)は足さない。少しでも向き・表情が違えば足す。
                // 0.4 秒おきにして、7 秒の間に顔の向きを変えた分を集める
                if (near < 0.98 and now - last_add >= 400) {
                    last_add = now;
                    got.embs[got.n] = e.*;
                    got.n += 1;
                    send(.{ .code = @intFromEnum(Code.progress), .n = @intCast(got.n) });
                    if (got.n == core.MAX_ENROLL) break;
                }
            },
        }
    }
    if (st.quit.load(.acquire)) return;
    if (got.n < core.MIN_ENROLL) return sendCode(if (got.n == 0 and dark_face) .too_dark else .enroll_few);
    if (!core.consistent(&got)) return sendCode(.enroll_mixed);
    if (!saveEnrolled(&got)) return sendCode(.failed);
    send(.{ .code = @intFromEnum(Code.enrolled), .n = @intCast(got.n) });
}

// ---- モデルのファイル ----

fn dataPath(buf: []u8, name: []const u8) ?[]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |d| if (d.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell/{s}", .{ d, name }) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/share/ame-shell/{s}", .{ home, name }) catch null;
}

/// モデルを読む。無い・壊れていれば取ってくる(curl)。中身は SHA-256 で確かめる
fn loadModel(a: std.mem.Allocator, m: core.Model) ?[]u8 {
    var nb: [128]u8 = undefined;
    const rel = std.fmt.bufPrint(&nb, "models/{s}", .{m.file}) catch return null;
    var pb: [512]u8 = undefined;
    const path = dataPath(&pb, rel) orelse return null;
    if (core.readModel(a, path, m)) |b| return b;
    sendCode(.downloading);
    if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
    var tb: [520]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tb, "{s}.part", .{path}) catch return null;
    var pid: c_int = 0;
    const fd = sys.spawnReader(&.{ "curl", "-sSfL", "--max-time", "300", "-o", tmp.ptr, m.url.ptr }, &pid) orelse return null;
    var sink: [256]u8 = undefined;
    while (true) {
        if (st.quit.load(.acquire)) {
            _ = c.kill(pid, c.SIGTERM);
            _ = c.close(fd);
            return null;
        }
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 200) catch break;
        if (pfd[0].revents == 0) continue;
        const n = c.read(fd, &sink, sink.len);
        if (n <= 0) break;
    }
    _ = c.close(fd);
    const b = core.readModel(a, tmp, m) orelse {
        log.err("{s} を取ってきましたが、中身が違います(SHA-256 が合いません)", .{m.file});
        std.fs.cwd().deleteFile(tmp) catch {};
        return null;
    };
    std.fs.cwd().rename(tmp, path) catch return null;
    return b;
}
