// 顔認証: ロック画面で、登録した顔がカメラに写ったらロックを外す。登録もここ(ame-ctl face enroll / ランチャー)。
//
//   ロックした時・ロック画面を触った時 … 別スレッドでカメラを開き、0.15 秒おきに顔を探して特徴を比べる(最長 8 秒)。
//                                         2 コマ続けて登録した顔と十分近ければ(cos ≥ face.threshold)ロックを外す。
//                                         パスワードはいつでも使える(顔認証はその横で動くだけ)
//   登録 … 6 秒ほどカメラを見てもらい、向きの違う顔の特徴を最大 12 個 $XDG_DATA_HOME/ame-shell/face.bin(0600)に
//
// 写真でだまされにくいように:
//   * 赤外線カメラ(GREY の形式を出すカメラ)を優先する。赤外線で登録した顔は、赤外線カメラでしか照合しない
//     (スマホの画面は赤外線では真っ暗に写る)
//   * 赤外線の映像では、顔が十分明るい(赤外線の照明が当たっている)ことも確かめる
// それでも顔認証はパスワードより弱い(印刷した写真・そっくりな人)。使わないときは face { enabled off }。
//
// モデル(初めて登録するときに取ってきて $XDG_DATA_HOME/ame-shell/models に置く。SHA-256 を確かめる):
//   顔の検出 … MediaPipe の BlazeFace short range(Apache-2.0)
//   顔の特徴 … OpenCV Zoo の SFace(Apache-2.0、ONNX。face/onnx.zig で自作のエンジンの形に直す)
const std = @import("std");
const c = @import("../c.zig");
const App = @import("../app.zig").App;
const loop = @import("../platform/loop.zig");
const sys = @import("../platform/sys.zig");
const v4l2 = @import("../platform/v4l2.zig");
const nn = @import("../hand/nn.zig");
const onnx = @import("onnx.zig");
const face = @import("face.zig");

const log = std.log.scoped(.face);

const Model = struct { file: []const u8, url: [:0]const u8, sha256: []const u8, max: usize };
const DET_MODEL = Model{
    .file = "blaze_face_short_range.tflite",
    .url = "https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite",
    .sha256 = "b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f",
    .max = 4 << 20,
};
const EMB_MODEL = Model{
    .file = "face_recognition_sface_2021dec.onnx",
    .url = "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx",
    .sha256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
    .max = 64 << 20,
};

const MAX_ENROLL = 12;
const MIN_ENROLL = 5;
const VERIFY_MS = 8000;
const ENROLL_MS = 7000;
/// 赤外線の映像で、顔の明るさがこれより暗ければ照明が当たっていない(写真・画面のおそれ)
const IR_MIN_BRIGHT = 18;

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
    no_model,
    no_enroll,
    ir_mismatch,
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
    threshold: f32 = 0.5,
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

/// 顔が登録されているか
pub fn enrolled() bool {
    var pb: [512]u8 = undefined;
    const p = dataPath(&pb, "face.bin") orelse return false;
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

/// ロックした・ロック画面を触った(lock.zig から): 登録してあれば照合を始める。直前に終わったばかりなら何もしない
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
    if (!st.running) return;
    st.quit.store(true, .release);
    if (st.thread) |t| t.join();
    st.thread = null;
    finish();
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
    st.device_len = @min(dev.len, st.device.len - 1);
    @memcpy(st.device[0..st.device_len], dev[0..st.device_len]);
    st.device[st.device_len] = 0;
    st.threshold = app.cfg.face_threshold;
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
    while (c.read(fd, &m, @sizeOf(Msg)) == @sizeOf(Msg)) {
        const code: Code = @enumFromInt(m.code);
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
                const s = std.fmt.bufPrint(&b, "顔を登録しています({d}/{d})", .{ m.n, MAX_ENROLL }) catch "";
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
                app.osd.info(std.fmt.bufPrint(&b, "顔を登録しました({d} 枚)。ロック画面で顔を向けるとロックが外れます", .{m.n}) catch "顔を登録しました");
                done = true;
            },
            else => {
                st.phase = .failed;
                setMsg(switch (code) {
                    .no_face => "顔が見つかりませんでした(パスワードを入力するか、もう一度クリック)",
                    .no_match => "顔が一致しませんでした(パスワードを入力してください)",
                    .no_camera => "カメラを開けませんでした",
                    .no_model => "顔の認識のモデルがありません(ネットワークを確かめてください)",
                    .no_enroll => "顔が登録されていません",
                    .ir_mismatch => "赤外線カメラで登録した顔は、赤外線カメラでしか確かめません",
                    .enroll_few => "顔をうまく撮れませんでした。明るい所で、カメラの正面からもう一度",
                    .enroll_mixed => "別の人の顔が混ざったようです。1 人だけで、もう一度登録してください",
                    .too_dark => "顔が暗すぎます(赤外線の照明が点かないか、部屋が暗いようです)",
                    else => "顔認証を始められませんでした",
                });
                if (st.mode == .enroll) app.osd.info(message());
                done = true;
            },
        }
    }
    if (done) {
        if (st.thread) |t| t.join();
        st.thread = null;
        finish();
        if (st.phase == .matched and st.mode == .verify) app.lock.faceUnlocked();
        if (st.mode == .enroll and st.phase != .failed) {
            st.phase = .idle;
            st.msg_len = 0;
        }
    }
    redraw(app);
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

/// 登録のファイル: "AMEFACE1"・赤外線か(u8)・数(u8)・予備 2・特徴 × 数(f32 × 128)
const MAGIC = "AMEFACE1";

const Enrolled = struct {
    ir: bool,
    n: usize,
    embs: [MAX_ENROLL][face.EMB]f32,
};

fn loadEnrolled(out: *Enrolled) bool {
    var pb: [512]u8 = undefined;
    const p = dataPath(&pb, "face.bin") orelse return false;
    var buf: [12 + MAX_ENROLL * face.EMB * 4]u8 = undefined;
    const data = std.fs.cwd().readFile(p, &buf) catch return false;
    if (data.len < 12 or !std.mem.eql(u8, data[0..8], MAGIC)) return false;
    out.ir = data[8] != 0;
    out.n = @min(data[9], MAX_ENROLL);
    if (out.n == 0 or data.len < 12 + out.n * face.EMB * 4) return false;
    for (0..out.n) |i| for (0..face.EMB) |k| {
        out.embs[i][k] = @bitCast(std.mem.readInt(u32, data[12 + (i * face.EMB + k) * 4 ..][0..4], .little));
    };
    return true;
}

fn saveEnrolled(e: *const Enrolled) bool {
    var pb: [512]u8 = undefined;
    const p = dataPath(&pb, "face.bin") orelse return false;
    if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
    var buf: [12 + MAX_ENROLL * face.EMB * 4]u8 = undefined;
    @memcpy(buf[0..8], MAGIC);
    buf[8] = @intFromBool(e.ir);
    buf[9] = @intCast(e.n);
    buf[10] = 0;
    buf[11] = 0;
    for (0..e.n) |i| for (0..face.EMB) |k| {
        std.mem.writeInt(u32, buf[12 + (i * face.EMB + k) * 4 ..][0..4], @bitCast(e.embs[i][k]), .little);
    };
    // 本人だけが読み書きできるように(一時ファイルに書いてから置き換える)
    var tb: [520]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.part", .{p}) catch return false;
    const f = std.fs.cwd().createFile(tmp, .{ .mode = 0o600 }) catch return false;
    f.writeAll(buf[0 .. 12 + e.n * face.EMB * 4]) catch {
        f.close();
        return false;
    };
    f.close();
    std.fs.cwd().rename(tmp, p) catch return false;
    return true;
}

fn worker(mode: Mode) void {
    // 推論のメモリは全部この領域から取り、終わったら丸ごと返す(ロックのたびに 40MB ほど使って返す)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var known: Enrolled = undefined;
    if (mode == .verify and !loadEnrolled(&known)) return sendCode(.no_enroll);

    sendCode(.loading);
    const det_b = loadModel(a, DET_MODEL) orelse return sendCode(if (st.quit.load(.acquire)) .failed else .no_model);
    const emb_b = loadModel(a, EMB_MODEL) orelse return sendCode(if (st.quit.load(.acquire)) .failed else .no_model);
    var det = nn.Net.init(a, det_b, 1) catch |e| {
        log.err("顔の検出のモデルを読めません: {}", .{e});
        return sendCode(.failed);
    };
    const g = onnx.parse(a, emb_b) catch |e| {
        log.err("顔の特徴のモデルを読めません: {}", .{e});
        return sendCode(.failed);
    };
    const m = onnx.toModel(a, &g) catch |e| {
        log.err("顔の特徴のモデルを直せません: {}", .{e});
        return sendCode(.failed);
    };
    var emb = nn.Net.initModel(a, m, 2) catch |e| {
        log.err("顔の特徴のモデルを準備できません: {}", .{e});
        return sendCode(.failed);
    };
    defer emb.deinit();
    defer det.deinit();
    var rec = face.Recognizer.init(&det, &emb);

    var cam = openCamera() orelse return sendCode(.no_camera);
    defer cam.close();
    const ir = cam.fmt == .grey;
    if (mode == .verify and known.ir and !ir) return sendCode(.ir_mismatch);
    const rgb = a.alloc(u8, cam.w * cam.h * 3) catch return sendCode(.failed);
    const img = face.Image{ .rgb = rgb, .w = cam.w, .h = cam.h };
    log.info("顔認証: カメラ {d}x{d}({s})", .{ cam.w, cam.h, if (ir) "赤外線" else "カラー" });
    sendCode(.scanning);

    const t0 = std.time.milliTimestamp();
    const limit: i64 = if (mode == .verify) VERIFY_MS else ENROLL_MS;
    var last: i64 = 0;
    var hits: u32 = 0;
    var seen_face = false;
    var dark_face = false;
    var last_add: i64 = 0;
    var best: f32 = -1;
    var got = Enrolled{ .ir = ir, .n = 0, .embs = undefined };
    while (!st.quit.load(.acquire)) {
        const now = std.time.milliTimestamp();
        if (now - t0 > limit) break;
        var pfd = [_]std.posix.pollfd{.{ .fd = cam.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 150) catch break;
        if (now - last < 150) {
            _ = cam.grab(null, false);
            continue;
        }
        if (!cam.grab(rgb, false)) continue;
        last = now;
        const f = (rec.detect(img) catch null) orelse {
            hits = 0;
            continue;
        };
        // 小さすぎる顔(遠い)は使わない
        if (f.w < @as(f32, @floatFromInt(cam.w)) * 0.12) {
            hits = 0;
            continue;
        }
        if (ir and faceBrightness(img, f) < IR_MIN_BRIGHT) {
            dark_face = true;
            hits = 0;
            continue;
        }
        seen_face = true;
        var e: [face.EMB]f32 = undefined;
        rec.embed(img, f, &e) catch continue;
        switch (mode) {
            .verify => {
                var s: f32 = -1;
                for (known.embs[0..known.n]) |*k| s = @max(s, face.cosine(k, &e));
                best = @max(best, s);
                if (st.debug) send(.{ .code = @intFromEnum(Code.scanning), .score = s });
                if (s >= st.threshold) {
                    hits += 1;
                    if (hits >= 2) return send(.{ .code = @intFromEnum(Code.matched), .score = s });
                } else hits = 0;
            },
            .enroll => {
                var near: f32 = -1;
                for (got.embs[0..got.n]) |*k| near = @max(near, face.cosine(k, &e));
                // まったく同じ顔(動いていない)は足さない。少しでも向き・表情が違えば足す。
                // 0.4 秒おきにして、7 秒の間に顔の向きを変えた分を集める
                if (got.n < MAX_ENROLL and near < 0.98 and now - last_add >= 400) {
                    last_add = now;
                    got.embs[got.n] = e;
                    got.n += 1;
                    send(.{ .code = @intFromEnum(Code.progress), .n = @intCast(got.n) });
                    if (got.n == MAX_ENROLL) break;
                }
            },
        }
    }
    if (st.quit.load(.acquire)) return;
    switch (mode) {
        .verify => send(.{ .code = @intFromEnum(if (seen_face) Code.no_match else if (dark_face) Code.too_dark else Code.no_face), .score = best }),
        .enroll => {
            if (got.n < MIN_ENROLL) return sendCode(if (got.n == 0 and dark_face) .too_dark else .enroll_few);
            // 全部が同じ人か: 平均の顔(長さ 1 にそろえる)に、どれも十分近い。
            // 2 つずつ比べると、正面と大きく傾けた顔の組で同じ人でも下がるので、平均と比べる
            var mean = [_]f32{0} ** face.EMB;
            for (got.embs[0..got.n]) |*e| for (&mean, e) |*mv, x| {
                mv.* += x;
            };
            var len: f32 = 0;
            for (mean) |x| len += x * x;
            for (&mean) |*mv| mv.* /= @max(@sqrt(len), 1e-6);
            for (got.embs[0..got.n]) |*e| if (face.cosine(e, &mean) < 0.5) return sendCode(.enroll_mixed);
            if (!saveEnrolled(&got)) return sendCode(.failed);
            send(.{ .code = @intFromEnum(Code.enrolled), .n = @intCast(got.n) });
        },
    }
}

/// 顔の箱の中の明るさの平均(0〜255)
fn faceBrightness(img: face.Image, f: face.Face) f32 {
    const x0: usize = @intFromFloat(std.math.clamp(f.x + f.w * 0.2, 0, @as(f32, @floatFromInt(img.w - 1))));
    const x1: usize = @intFromFloat(std.math.clamp(f.x + f.w * 0.8, 0, @as(f32, @floatFromInt(img.w - 1))));
    const y0: usize = @intFromFloat(std.math.clamp(f.y + f.h * 0.2, 0, @as(f32, @floatFromInt(img.h - 1))));
    const y1: usize = @intFromFloat(std.math.clamp(f.y + f.h * 0.8, 0, @as(f32, @floatFromInt(img.h - 1))));
    var s: u64 = 0;
    var n: u64 = 0;
    var y = y0;
    while (y < y1) : (y += 2) {
        var x = x0;
        while (x < x1) : (x += 2) {
            s += img.rgb[(y * img.w + x) * 3];
            n += 1;
        }
    }
    return if (n == 0) 0 else @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
}

fn openCamera() ?v4l2.Camera {
    if (st.device_len > 0) {
        const p: [*:0]const u8 = @ptrCast(&st.device);
        return v4l2.Camera.openFmt(p, 640, 360, 30, .grey) catch v4l2.Camera.open(p, 640, 480, 30) catch |e| {
            log.warn("{s} を開けません: {}", .{ st.device[0..st.device_len], e });
            return null;
        };
    }
    // 赤外線カメラ(GREY を出すもの)を先に探し、無ければ普通のカメラ
    var buf: [32]u8 = undefined;
    for (0..10) |i| {
        const p = std.fmt.bufPrintZ(&buf, "/dev/video{d}", .{i}) catch continue;
        if (v4l2.Camera.openFmt(p.ptr, 640, 360, 30, .grey)) |cam| return cam else |_| {}
    }
    for (0..10) |i| {
        const p = std.fmt.bufPrintZ(&buf, "/dev/video{d}", .{i}) catch continue;
        if (v4l2.Camera.open(p.ptr, 640, 480, 30)) |cam| return cam else |_| {}
    }
    return null;
}

// ---- モデルのファイル ----

fn dataPath(buf: []u8, name: []const u8) ?[]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |d| if (d.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell/{s}", .{ d, name }) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/share/ame-shell/{s}", .{ home, name }) catch null;
}

fn sha256Is(b: []const u8, hex: []const u8) bool {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(b, &d, .{});
    const got = std.fmt.bytesToHex(d, .lower);
    return std.mem.eql(u8, &got, hex);
}

/// モデルを読む。無い・壊れていれば取ってくる(curl)。中身は SHA-256 で確かめる
fn loadModel(a: std.mem.Allocator, m: Model) ?[]u8 {
    var nb: [128]u8 = undefined;
    const rel = std.fmt.bufPrint(&nb, "models/{s}", .{m.file}) catch return null;
    var pb: [512]u8 = undefined;
    const path = dataPath(&pb, rel) orelse return null;
    if (std.fs.cwd().readFileAlloc(a, path, m.max)) |b| {
        if (sha256Is(b, m.sha256)) return b;
        log.warn("{s} の中身が違うので取り直します", .{m.file});
    } else |_| {}
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
    const b = std.fs.cwd().readFileAlloc(a, tmp, m.max) catch return null;
    if (!sha256Is(b, m.sha256)) {
        log.err("{s} を取ってきましたが、中身が違います(SHA-256 が合いません)", .{m.file});
        std.fs.cwd().deleteFile(tmp) catch {};
        return null;
    }
    std.fs.cwd().rename(tmp, path) catch return null;
    return b;
}
