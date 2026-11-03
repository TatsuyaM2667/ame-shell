// ハンド操作: カメラに映った手の動きで、カーソルと窓を操作する(オン/オフできる。既定はオフ)。
//
//   指さす(人差し指だけ伸ばす) … カーソルが指先に付いて動く(窓のフォーカスもカーソルに付いて移る)
//   つまむ(親指と人差し指)      … 短く: クリック / つまんだまま動かす: カーソルの下の窓をつかんで動かす
//   手のひらを左右に払う          … 隣のワークスペースへ(左へ払う = 次、右へ = 前)
//   握りこぶしを保つ(0.9 秒)    … フォーカス中の窓を閉じる
//   手のひらを開いて止める(1.3 秒)… 全画面の切り替え
//   指の本数を示して止める(0.7 秒)… その番号のワークスペース(親指だけ = 1、ピース = 2、3 本 = 3、親指を曲げて 4 本 = 4)
// 操作のたびに、カーソルの位置から水の波紋が広がる。指が通った跡には、波打つ光の筋と小さな波紋を残す。
//
// 作り:
//   別スレッド … カメラ(platform/v4l2.zig)→ 手の関節 21 点(track.zig + nn.zig)→ 手の形と位置を pipe でメインへ
//   メイン     … 形の続き具合・時間で操作を決め、仮想ポインタ(wlr-virtual-pointer)と WM(wm.zig)に伝える。
//                オーバーレイ(layer-shell の一番上・入力は透過)にカーソルと波紋を描く
// モデル(MediaPipe の hand_landmarker.task、Apache-2.0)は、初めてオンにしたときに取ってきて
// $XDG_DATA_HOME/ame-shell/models に置く。オフにするとスレッド・カメラ・モデルのメモリを全部返す。
const std = @import("std");
const c = @import("../c.zig");
const appmod = @import("../app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("../surface.zig");
const Surface = surface.Surface;
const gfx = @import("../gfx.zig");
const anim = @import("../anim.zig");
const Color = anim.Color;
const Spring = anim.Spring;
const theme = @import("../theme.zig");
const loop = @import("../platform/loop.zig");
const sys = @import("../platform/sys.zig");
const v4l2 = @import("../platform/v4l2.zig");
const track = @import("track.zig");
const nn = @import("nn.zig");
const zip = @import("zip.zig");

const log = std.log.scoped(.hand);

const MODEL_URL = "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task";

pub const Gesture = enum(u8) { none, point, pinch, open, fist, other, number };

const Status = enum(u8) { running, downloading, loading, no_camera, no_model, failed };

/// スレッド → メイン(pipe に丸ごと書く。PIPE_BUF より小さいので途中で切れない)
const Msg = extern struct {
    kind: u8, // 0 = コマ、1 = 状態
    gesture: u8 = 0,
    status: u8 = 0,
    has: u8 = 0,
    /// 指の本数の形(.number のとき 1〜4)
    fingers: u8 = 0,
    _r: [3]u8 = .{ 0, 0, 0 },
    /// カーソル(画面の 0〜1)・手のひらの中心(0〜1)・つまみの近さ(手の大きさで割った親指と人差し指の距離)
    cx: f32 = 0,
    cy: f32 = 0,
    px: f32 = 0,
    py: f32 = 0,
    pinch: f32 = 9,
};

/// 波紋: 広がりきる半径(px)と時間(ms)
const Ripple = struct { x: f32, y: f32, t0: u64, col: Color, size: f32, dur: f32 };
const TrailPt = struct { x: f32, y: f32, t: u64, d: f32 };
/// 軌跡が消えるまで(ms)
const TRAIL_MS: f32 = 850;

const HOLD_FIST_MS = 900;
const HOLD_OPEN_MS = 1300;
const HOLD_NUM_MS = 700;

const State = struct {
    app: ?*App = null,
    on: bool = false,
    // スレッド
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rfd: c_int = -1,
    wfd: c_int = -1,
    device: [64]u8 = undefined,
    device_len: usize = 0,
    // 出力とオーバーレイ・仮想ポインタ
    out: ?*Output = null,
    surf: ?*Surface = null,
    vptr: ?*c.struct_zwlr_virtual_pointer_v1 = null,
    // 手
    visible: bool = false,
    /// 手が見え始めた時刻(見えてすぐは、閉じる・全画面の長押しを受け付けない)
    seen_since: u64 = 0,
    last_seen: u64 = 0,
    cur: [2]f32 = .{ 0, 0 }, // 出力の論理座標
    filt: [2]OneEuro = .{ .{}, .{} },
    shown: Spring = Spring.init(0, 0.22, 0.8),
    press: Spring = Spring.init(0, 0.14, 0.7),
    gesture: Gesture = .none,
    cand: Gesture = .none,
    cand_n: u8 = 0,
    cand_fingers: u8 = 0,
    fingers: u8 = 0,
    // 指の本数でワークスペース
    num: u8 = 0,
    num_t0: u64 = 0,
    num_p0: [2]f32 = .{ 0, 0 },
    num_done: bool = false,
    // 指の軌跡
    trail: [48]TrailPt = undefined,
    n_trail: usize = 0,
    trail_dist: f32 = 0,
    wake_at: f32 = 0,
    // つまむ
    pinching: bool = false,
    pinch_t0: u64 = 0,
    pinch_p0: [2]f32 = .{ 0, 0 },
    dragging: bool = false,
    // 払う
    hist: [12]struct { t: u64, x: f32 } = undefined,
    n_hist: usize = 0,
    swipe_quiet: u64 = 0,
    // 保つ
    hold: Gesture = .none,
    hold_t0: u64 = 0,
    hold_p0: [2]f32 = .{ 0, 0 },
    hold_done: bool = false,
    /// 払った後は、手の形が変わるまで開いた手の長押し(全画面)を受け付けない
    open_blocked: bool = false,
    // 波紋
    ripples: [40]Ripple = undefined,
    n_ripples: usize = 0,
    // 状態の表示
    msg: [128]u8 = undefined,
    msg_len: usize = 0,
    msg_until: u64 = 0,
    /// 試験(debug-hand)で値を与えている間は、カメラからの結果を無視する
    debug_until: u64 = 0,
    debug_log: bool = false,
    last_logged: Gesture = .none,
};
var st: State = .{};

pub fn enabled() bool {
    return st.on;
}

pub fn toggle(app: *App) void {
    if (st.on) disable() else enable(app);
}

pub fn enable(app: *App) void {
    if (st.on) return;
    st.app = app;
    if (app.vptr_mgr == null) {
        app.osd.info("このコンポジタは仮想ポインタに対応していないので、ハンド操作を使えません");
        return;
    }
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return;
    st.rfd = fds[0];
    st.wfd = fds[1];
    app.loop.add(st.rfd, c.EPOLLIN, app, onMsg) catch {
        closeFds();
        return;
    };
    st.quit.store(false, .release);
    const dev = app.cfg.hand_camera.get();
    st.device_len = @min(dev.len, st.device.len - 1);
    @memcpy(st.device[0..st.device_len], dev[0..st.device_len]);
    st.device[st.device_len] = 0;
    st.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, worker, .{}) catch {
        app.loop.remove(st.rfd);
        closeFds();
        return;
    };
    st.on = true;
    st.debug_log = std.posix.getenv("AME_DEBUG") != null;
    makeOverlay(app);
    setMsg("ハンド操作: オン(手をカメラに向けてください)");
    app.osd.info("ハンド操作をオンにしました(カメラを使います)");
}

pub fn disable() void {
    if (!st.on) return;
    const app = st.app.?;
    st.on = false;
    st.quit.store(true, .release);
    if (st.thread) |t| t.join();
    st.thread = null;
    app.loop.remove(st.rfd);
    closeFds();
    endDrag();
    if (st.vptr) |p| c.zwlr_virtual_pointer_v1_destroy(p);
    st.vptr = null;
    if (st.surf) |s| s.destroy();
    st.surf = null;
    st.out = null;
    st.visible = false;
    st.n_ripples = 0;
    app.osd.info("ハンド操作をオフにしました");
}

fn closeFds() void {
    if (st.rfd >= 0) _ = c.close(st.rfd);
    if (st.wfd >= 0) _ = c.close(st.wfd);
    st.rfd = -1;
    st.wfd = -1;
}

/// 出力が抜かれた(app.zig)
pub fn outputRemoved(o: *Output) void {
    if (st.out != o) return;
    if (st.surf) |s| s.destroy();
    st.surf = null;
    if (st.vptr) |p| c.zwlr_virtual_pointer_v1_destroy(p);
    st.vptr = null;
    st.out = null;
    if (st.on) if (st.app) |app| makeOverlay(app);
}

fn makeOverlay(app: *App) void {
    const o = app.activeOutput() orelse return;
    st.out = o;
    const s = Surface.createLayer(app, .{ .ctx = &st, .draw = draw }, .{
        .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        .anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        .exclusive = -1,
        .namespace = "ame-hand",
        .output = o.wl,
    }) catch return;
    s.output = o;
    s.setInputRect(0, 0, 0, 0); // クリックは下へ
    st.surf = s;
    s.schedule();
    if (app.seat) |seat| {
        st.vptr = if (app.vptr_mgr_version >= 2)
            c.zwlr_virtual_pointer_manager_v1_create_virtual_pointer_with_output(app.vptr_mgr, seat, o.wl)
        else
            c.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(app.vptr_mgr, seat);
    }
}

fn setMsg(s: []const u8) void {
    const n = @min(s.len, st.msg.len);
    @memcpy(st.msg[0..n], s[0..n]);
    st.msg_len = n;
    st.msg_until = loop.nowMs() + 3500;
    if (st.surf) |sf| sf.schedule();
}

// ---------------------------------------------------------------------------
// メイン: 手の形と位置から操作を決める
// ---------------------------------------------------------------------------

fn onMsg(ctx: *anyopaque, fd: c_int, _: u32) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    var m: Msg = undefined;
    while (true) {
        const n = c.read(fd, &m, @sizeOf(Msg));
        if (n != @sizeOf(Msg)) break;
        if (m.kind == 1) {
            status(app, @enumFromInt(m.status));
            continue;
        }
        if (loop.nowMs() < st.debug_until) continue;
        if (st.debug_log) {
            const g: Gesture = if (m.has == 0) .none else @enumFromInt(m.gesture);
            if (g != st.last_logged) log.info("カメラ: {s}(つまみ {d:.2}、位置 {d:.2}, {d:.2})", .{ @tagName(g), m.pinch, m.cx, m.cy });
            st.last_logged = g;
        }
        frame(app, m);
    }
}

fn status(app: *App, s: Status) void {
    switch (s) {
        .running => setMsg("ハンド操作: 手をカメラに向けてください"),
        .downloading => setMsg("手の認識のモデルを取ってきています(初回だけ、約 8MB)…"),
        .loading => setMsg("手の認識を準備しています…"),
        .no_camera => {
            setMsg("カメラを開けません(使える /dev/video* が無いか、ほかのアプリが使っています)");
            theme.flashError(app);
        },
        .no_model => {
            setMsg("手の認識のモデルを取ってこられませんでした(ネットワークを確かめてください)");
            theme.flashError(app);
        },
        .failed => {
            setMsg("手の認識を始められませんでした(ログを見てください)");
            theme.flashError(app);
        },
    }
}

fn outSize() [2]f32 {
    const o = st.out orelse return .{ 1920, 1080 };
    if (st.surf) |s| if (s.width > 0) return .{ @floatFromInt(s.width), @floatFromInt(s.height) };
    return .{ @floatFromInt(@max(o.width, 1)), @floatFromInt(@max(o.height, 1)) };
}

fn frame(app: *App, m: Msg) void {
    const now = loop.nowMs();
    const sf = st.surf orelse return;
    if (m.has == 0) {
        // 手が消えた: 少し待ってから(1 コマの見失いでつかんだ窓を落とさないように)
        if (st.visible and now -| st.last_seen > 450) {
            st.visible = false;
            st.shown.set(0);
            if (st.pinching) {
                st.pinching = false;
                endDrag();
            }
            st.hold = .none;
            st.n_hist = 0;
            sf.schedule();
        }
        return;
    }
    const sz = outSize();
    const tsec = @as(f32, @floatFromInt(now)) / 1000;
    const raw = [2]f32{ m.cx * sz[0], m.cy * sz[1] };
    if (!st.visible) {
        st.seen_since = now;
        st.filt[0].reset();
        st.filt[1].reset();
    }
    st.cur = .{ st.filt[0].step(raw[0], tsec), st.filt[1].step(raw[1], tsec) };
    st.visible = true;
    st.last_seen = now;
    st.shown.set(1);

    // 形: 2 コマ続いたら確定(1 コマだけの見間違いで操作しない)
    const g: Gesture = @enumFromInt(m.gesture);
    if (g == st.cand and m.fingers == st.cand_fingers) st.cand_n +|= 1 else {
        st.cand = g;
        st.cand_fingers = m.fingers;
        st.cand_n = 1;
    }
    if (st.cand_n >= 2) {
        st.gesture = st.cand;
        st.fingers = st.cand_fingers;
    }

    // カーソル
    movePointer(st.cur);
    trailAdd(app, st.cur, now);

    // ---- つまむ: 短くでクリック、動かすと窓をつかむ ----
    const pinch_now = if (st.pinching) m.pinch < 0.45 and st.gesture != .open else st.gesture == .pinch;
    if (pinch_now and !st.pinching) {
        st.pinching = true;
        st.pinch_t0 = now;
        st.pinch_p0 = st.cur;
        st.dragging = false;
        st.press.set(1);
        addRipple(st.cur, theme.accent(app), 70, 1000);
    } else if (pinch_now and st.pinching) {
        const dx = st.cur[0] - st.pinch_p0[0];
        const dy = st.cur[1] - st.pinch_p0[1];
        if (!st.dragging and (dx * dx + dy * dy > 36 * 36 or now -| st.pinch_t0 > 450)) {
            if (app.wm) |w| {
                w.push(.hand_grab);
                st.dragging = true;
            }
        }
        if (st.dragging) if (app.wm) |w| w.push(.{ .hand_drag = .{ @intFromFloat(dx), @intFromFloat(dy) } });
    } else if (!pinch_now and st.pinching) {
        st.pinching = false;
        st.press.set(0);
        if (st.dragging) {
            endDrag();
            addRipple(st.cur, theme.accent(app).lighten(0.2), 120, 1100);
        } else {
            click();
            addRipple(st.cur, theme.accent(app).lighten(0.3), 120, 1100);
        }
    }

    // ---- 払う: 開いた手が速く横に動いた ----
    if (st.gesture == .open and !st.pinching) {
        if (st.n_hist == st.hist.len) {
            std.mem.copyForwards(@TypeOf(st.hist[0]), st.hist[0 .. st.hist.len - 1], st.hist[1..]);
            st.n_hist -= 1;
        }
        st.hist[st.n_hist] = .{ .t = now, .x = st.cur[0] };
        st.n_hist += 1;
        var k: usize = 0;
        while (k < st.n_hist and now -| st.hist[k].t > 320) k += 1;
        if (k < st.n_hist and now >= st.swipe_quiet) {
            const dx = st.cur[0] - st.hist[k].x;
            if (@abs(dx) > sz[0] * 0.22) {
                const dir: i32 = if (dx < 0) 1 else -1;
                if (app.wm) |w| {
                    if (w.handWorkspace(dir)) addRipple(st.cur, theme.accent(app), 120, 1100);
                }
                st.swipe_quiet = now + 900;
                // 払った手をそのまま止めても全画面にならないように、形が変わるまで長押しを止める
                st.open_blocked = true;
                st.n_hist = 0;
            }
        }
    } else st.n_hist = 0;

    // ---- 保つ: 握りこぶし = 閉じる、開いて止める = 全画面 ----
    if (st.gesture != .open) st.open_blocked = false;
    const settled = now -| st.seen_since >= 600;
    const holdable = settled and (st.gesture == .fist or (st.gesture == .open and !st.open_blocked)) and !st.pinching;
    if (!holdable) {
        st.hold = .none;
    } else {
        const moved = blk: {
            const dx = st.cur[0] - st.hold_p0[0];
            const dy = st.cur[1] - st.hold_p0[1];
            break :blk dx * dx + dy * dy > 48 * 48;
        };
        if (st.hold != st.gesture or moved) {
            st.hold = st.gesture;
            st.hold_t0 = now;
            st.hold_p0 = st.cur;
            st.hold_done = false;
        } else if (!st.hold_done) {
            const need: u64 = if (st.hold == .fist) HOLD_FIST_MS else HOLD_OPEN_MS;
            if (now -| st.hold_t0 >= need) {
                st.hold_done = true;
                if (app.wm) |w| {
                    if (st.hold == .fist) {
                        w.push(.close);
                        addRipple(st.cur, theme.danger(app), 120, 1100);
                    } else {
                        w.push(.fullscreen);
                        addRipple(st.cur, theme.accent(app), 120, 1100);
                    }
                }
            }
        }
    }
    // ---- 指の本数を示して止める: そのワークスペースへ(いいね = 1、ピース = 2、3 本 = 3、親指を曲げて 4 本 = 4)----
    if (st.gesture != .number or st.pinching or !settled) {
        st.num = 0;
        st.num_done = false;
    } else {
        const dx = st.cur[0] - st.num_p0[0];
        const dy = st.cur[1] - st.num_p0[1];
        if (st.num != st.fingers or dx * dx + dy * dy > 60 * 60) {
            // 本数が変わった・手が動いた: やり直す(同じ本数のまま決めた後は、形を変えるまで繰り返さない)
            if (st.num != st.fingers) st.num_done = false;
            st.num = st.fingers;
            st.num_t0 = now;
            st.num_p0 = st.cur;
        } else if (!st.num_done and now -| st.num_t0 >= HOLD_NUM_MS) {
            st.num_done = true;
            if (app.wm) |w| if (st.num >= 1 and st.num <= 9) {
                w.push(.{ .tags = @as(u32, 1) << @intCast(st.num - 1) });
                addRipple(st.cur, theme.accent(app), 150, 1300);
            };
        }
    }
    sf.schedule();
}

// ---- 指の軌跡: 光る水の筋と、通った跡に小さな波紋 ----

fn trailAdd(app: *App, p: [2]f32, now: u64) void {
    if (!app.cfg.hand_trail) return;
    if (st.n_trail > 0) {
        const last = st.trail[st.n_trail - 1];
        const dx = p[0] - last.x;
        const dy = p[1] - last.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d < 3) return;
        st.trail_dist += d;
        // 一定の距離ごとに、通った所へ小さな波紋を落とす(速く動かすほど多く)
        if (st.trail_dist - st.wake_at > 46) {
            st.wake_at = st.trail_dist;
            addRipple(p, theme.accent(app).lighten(0.25), 34, 800);
        }
    }
    if (st.n_trail == st.trail.len) {
        std.mem.copyForwards(TrailPt, st.trail[0 .. st.trail.len - 1], st.trail[1..]);
        st.n_trail -= 1;
    }
    st.trail[st.n_trail] = .{ .x = p[0], .y = p[1], .t = now, .d = st.trail_dist };
    st.n_trail += 1;
}

fn endDrag() void {
    if (!st.dragging) return;
    st.dragging = false;
    if (st.app) |app| if (app.wm) |w| w.push(.hand_release);
}

fn movePointer(p: [2]f32) void {
    const vp = st.vptr orelse return;
    const sz = outSize();
    const t: u32 = @truncate(loop.nowMs());
    const x: u32 = @intFromFloat(std.math.clamp(p[0], 0, sz[0] - 1));
    const y: u32 = @intFromFloat(std.math.clamp(p[1], 0, sz[1] - 1));
    c.zwlr_virtual_pointer_v1_motion_absolute(vp, t, x, y, @intFromFloat(sz[0]), @intFromFloat(sz[1]));
    c.zwlr_virtual_pointer_v1_frame(vp);
}

fn click() void {
    const vp = st.vptr orelse return;
    const t: u32 = @truncate(loop.nowMs());
    const BTN_LEFT = 0x110;
    c.zwlr_virtual_pointer_v1_button(vp, t, BTN_LEFT, 1);
    c.zwlr_virtual_pointer_v1_frame(vp);
    c.zwlr_virtual_pointer_v1_button(vp, t + 8, BTN_LEFT, 0);
    c.zwlr_virtual_pointer_v1_frame(vp);
}

fn addRipple(p: [2]f32, col: Color, size: f32, dur: f32) void {
    if (st.n_ripples == st.ripples.len) {
        std.mem.copyForwards(Ripple, st.ripples[0 .. st.ripples.len - 1], st.ripples[1..]);
        st.n_ripples -= 1;
    }
    st.ripples[st.n_ripples] = .{ .x = p[0], .y = p[1], .t0 = loop.nowMs(), .col = col, .size = size, .dur = dur };
    st.n_ripples += 1;
}

// ---------------------------------------------------------------------------
// オーバーレイ: カーソル・長押しの輪・水の波紋
// ---------------------------------------------------------------------------

/// 指の軌跡: 通った線を、波打ちながら細く薄く消えていく水の筋として描く。
/// 線と直角の向きに、進んだ距離と時間で動く sin の揺れを足すので、筋そのものが波立って見える
fn drawTrail(cv: *gfx.Canvas, acc: Color, now: u64) bool {
    // 古い点を捨てる
    var drop: usize = 0;
    while (drop < st.n_trail and @as(f32, @floatFromInt(now -| st.trail[drop].t)) > TRAIL_MS) drop += 1;
    if (drop > 0) {
        std.mem.copyForwards(TrailPt, st.trail[0 .. st.n_trail - drop], st.trail[drop..st.n_trail]);
        st.n_trail -= drop;
    }
    if (st.n_trail < 2) return st.n_trail > 0;
    const tt = @as(f32, @floatFromInt(now % 100000)) / 1000;
    var prev: [2]f32 = undefined;
    for (st.trail[0..st.n_trail], 0..) |pt, i| {
        // 進む向きと直角の向き
        const nb = st.trail[@min(i + 1, st.n_trail - 1)];
        const pa = st.trail[if (i > 0) i - 1 else 0];
        var tx = nb.x - pa.x;
        var ty = nb.y - pa.y;
        const tl = @max(@sqrt(tx * tx + ty * ty), 0.001);
        tx /= tl;
        ty /= tl;
        const age = @as(f32, @floatFromInt(now -| pt.t)) / TRAIL_MS; // 0 = 今、1 = 消える
        const life = 1 - age;
        // 古いほど大きく揺れて(波が広がる)、薄くなる
        const amp = 2.5 + 15 * age;
        const wave = @sin(pt.d * 0.075 - tt * 9) * amp;
        const p = [2]f32{ pt.x - ty * wave, pt.y + tx * wave };
        if (i > 0) {
            const a = life * life;
            cv.line(prev[0], prev[1], p[0], p[1], 3 + 12 * life, acc.alpha(0.18 * a)); // 光のにじみ
            cv.line(prev[0], prev[1], p[0], p[1], 1.2 + 2.6 * life, acc.lighten(0.35).alpha(0.75 * a));
            cv.line(prev[0], prev[1], p[0], p[1], 0.8 + 0.8 * life, Color.hex(0xffffff).alpha(0.55 * a)); // 水面のきらめき
        }
        prev = p;
    }
    return true;
}

fn draw(_: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
    const app = st.app orelse return false;
    var animating = false;
    var sp = [_]*Spring{ &st.shown, &st.press };
    if (anim.stepAll(&sp, dt)) animating = true;
    const now = loop.nowMs();
    const acc = theme.accent(app);

    if (drawTrail(cv, acc, now)) animating = true;

    // 水の波紋: 3 つの輪が少しずつ遅れて広がり、外ほど細く薄くなる。内側にうっすら水面の明るさ
    var k: usize = 0;
    while (k < st.n_ripples) {
        const r = st.ripples[k];
        const age = @as(f32, @floatFromInt(now -| r.t0)) / r.dur;
        if (age >= 1.25) {
            std.mem.copyForwards(Ripple, st.ripples[k .. st.n_ripples - 1], st.ripples[k + 1 .. st.n_ripples]);
            st.n_ripples -= 1;
            continue;
        }
        animating = true;
        const max_r = r.size;
        // 小さな波紋(軌跡の跡)は細く控えめに
        const thin: f32 = if (max_r < 50) 0.55 else 1;
        inline for (.{ 0.0, 0.13, 0.26 }) |delay| {
            const t = std.math.clamp((age - delay) / (1 - delay * 0.6), 0, 1);
            if (t > 0 and t < 1) {
                const e = 1 - (1 - t) * (1 - t) * (1 - t); // 速く広がって、ゆっくり止まる
                const rad = 6 + e * max_r;
                const a = (1 - t) * (1 - t) * 0.75;
                cv.arc(r.x, r.y, rad, (1.2 + 3.2 * (1 - t)) * thin, 1, r.col.alpha(a * thin), .{ .a = 0 });
                // 輪の内側のきらめき(細い白)
                cv.arc(r.x, r.y, rad - 2.5, 0.8, 1, Color.hex(0xffffff).alpha(a * 0.35), .{ .a = 0 });
            }
        }
        const tf = std.math.clamp(age, 0, 1);
        const fill_r = 6 + (1 - (1 - tf) * (1 - tf)) * max_r * 0.8;
        cv.rect(r.x - fill_r, r.y - fill_r, fill_r * 2, fill_r * 2, fill_r, r.col.alpha(0.07 * (1 - tf)));
        k += 1;
    }

    // カーソル(手が見えている間): 外の輪と中の点。つまむと点が膨らんで輪に寄る
    const a = st.shown.x;
    if (a > 0.01) {
        const x = st.cur[0];
        const y = st.cur[1];
        const pr = st.press.x;
        const ring_r = 17 - 5 * pr;
        cv.shadow(x - ring_r, y - ring_r, ring_r * 2, ring_r * 2, ring_r, 10, Color.hex(0x000000).alpha(0.25 * a));
        cv.arc(x, y, ring_r, 2.4, 1, acc.lighten(0.25).alpha(0.95 * a), .{ .a = 0 });
        const dot = 3.5 + 7 * pr;
        cv.rect(x - dot, y - dot, dot * 2, dot * 2, dot, Color.hex(0xffffff).alpha(0.9 * a));
        // 長押しの進み具合
        if (st.hold != .none and !st.hold_done) {
            const need: f32 = if (st.hold == .fist) HOLD_FIST_MS else HOLD_OPEN_MS;
            const p = std.math.clamp(@as(f32, @floatFromInt(now -| st.hold_t0)) / need, 0, 1);
            // 少し待ってから見せる(通りすがりの形で輪がちらつかないように)
            if (p > 0.15) {
                const col = if (st.hold == .fist) theme.danger(app) else acc;
                cv.arc(x, y, 27, 3.5, (p - 0.15) / 0.85, col.alpha(a), Color.hex(0xffffff).alpha(0.12 * a));
                _ = cv.text(x, y + 48, 11.5, Color.hex(0xffffff).alpha(0.85 * a), if (st.hold == .fist) "閉じる" else "全画面", .{ .alignment = .center, .bold = true });
            }
            animating = true;
        }
        // 指の本数: 輪が満ちたらそのワークスペースへ。輪の中に大きく番号
        if (st.num != 0 and !st.num_done) {
            const p = std.math.clamp(@as(f32, @floatFromInt(now -| st.num_t0)) / HOLD_NUM_MS, 0, 1);
            if (p > 0.12) {
                const r: f32 = 30;
                cv.glass(x + 26, y - 62, 52, 52, 26, theme.glass(app));
                cv.arc(x + 52, y - 36, r - 6, 3.2, (p - 0.12) / 0.88, acc.lighten(0.2).alpha(a), Color.hex(0xffffff).alpha(0.12 * a));
                var nb: [4]u8 = undefined;
                const ns = std.fmt.bufPrint(&nb, "{d}", .{st.num}) catch "";
                _ = cv.text(x + 52, y - 27, 24, Color.hex(0xffffff).alpha(0.95 * a), ns, .{ .alignment = .center, .bold = true });
            }
            animating = true;
        }
        // つかんでいる間は小さく「移動」
        if (st.dragging) _ = cv.text(x, y + 36, 11, Color.hex(0xffffff).alpha(0.8 * a), "移動", .{ .alignment = .center });
    }

    // 状態の表示(画面の下の中央、数秒で消える)
    if (st.msg_len > 0 and now < st.msg_until) {
        const fade = std.math.clamp(@as(f32, @floatFromInt(st.msg_until - now)) / 400, 0, 1);
        const w: f32 = @floatFromInt(s.width);
        const h: f32 = @floatFromInt(s.height);
        const tw = @min(w - 40, 620);
        cv.glass(w / 2 - tw / 2, h - 96, tw, 40, 20, theme.glass(app));
        _ = cv.text(w / 2, h - 70, 13, theme.text(app).alpha(fade), st.msg[0..st.msg_len], .{ .alignment = .center, .max_w = tw - 24 });
        animating = true;
    }
    return animating;
}

/// 手ぶれを抑える(One Euro filter: ゆっくり動くときは強くならし、速く動くときは遅れを小さく)
const OneEuro = struct {
    x: f32 = 0,
    dx: f32 = 0,
    t: f32 = 0,
    init: bool = false,

    fn reset(self: *OneEuro) void {
        self.init = false;
    }

    fn step(self: *OneEuro, v: f32, t: f32) f32 {
        if (!self.init) {
            self.* = .{ .x = v, .dx = 0, .t = t, .init = true };
            return v;
        }
        const dt = @max(t - self.t, 1.0 / 120.0);
        self.t = t;
        const d = (v - self.x) / dt;
        self.dx += alpha(1.0, dt) * (d - self.dx);
        const cutoff = 1.2 + 0.012 * @abs(self.dx);
        self.x += alpha(cutoff, dt) * (v - self.x);
        return self.x;
    }

    fn alpha(cutoff: f32, dt: f32) f32 {
        const tau = 1 / (2 * std.math.pi * cutoff);
        return 1 / (1 + tau / dt);
    }
};

// ---------------------------------------------------------------------------
// スレッド: カメラ → 手の関節 → 形と位置
// ---------------------------------------------------------------------------

fn send(m: Msg) void {
    _ = c.write(st.wfd, &m, @sizeOf(Msg));
}

fn sendStatus(s: Status) void {
    send(.{ .kind = 1, .status = @intFromEnum(s) });
}

fn worker() void {
    const a = std.heap.c_allocator;
    const bytes = loadModel(a) orelse return;
    var det_b: []const u8 = undefined;
    var lmk_b: []const u8 = undefined;
    if (!zip.unzipStored(bytes, "hand_detector.tflite", &det_b) or !zip.unzipStored(bytes, "hand_landmarks_detector.tflite", &lmk_b)) {
        a.free(bytes);
        log.err("モデルの中身が読めません", .{});
        sendStatus(.failed);
        return;
    }
    sendStatus(.loading);
    var det = nn.Net.init(a, det_b, 2) catch |e| {
        a.free(bytes);
        log.err("手のひらの検出モデルを読めません: {}", .{e});
        sendStatus(.failed);
        return;
    };
    defer det.deinit();
    var lmk = nn.Net.init(a, lmk_b, 2) catch |e| {
        a.free(bytes);
        log.err("関節のモデルを読めません: {}", .{e});
        sendStatus(.failed);
        return;
    };
    defer lmk.deinit();
    a.free(bytes); // 重みは f32 に変換済み。ファイルの中身はもう要らない
    var tr = track.Tracker.init(&det, &lmk);
    tr.det_signed = false;

    var cam = openCamera() orelse {
        sendStatus(.no_camera);
        return;
    };
    defer cam.close();
    const rgb = a.alloc(u8, cam.w * cam.h * 3) catch return;
    defer a.free(rgb);
    sendStatus(.running);
    log.info("ハンド操作: カメラ {d}x{d}", .{ cam.w, cam.h });

    var last_run: i64 = 0;
    while (!st.quit.load(.acquire)) {
        var pfd = [_]std.posix.pollfd{.{ .fd = cam.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 150) catch break;
        // 手を追っている間は 1 秒に 24 回まで、見つかっていない間は検出を 1 秒に 3 回まで(軽くするため)
        const now = std.time.milliTimestamp();
        const gap: i64 = if (tr.roi == null) 330 else 40;
        if (now - last_run < gap) {
            _ = cam.grab(null, true); // 処理しないコマは変換せずに捨てる
            continue;
        }
        if (!cam.grab(rgb, true)) continue;
        last_run = now;
        const img = track.Image{ .rgb = rgb, .w = cam.w, .h = cam.h };
        const hand = tr.step(img) catch null;
        if (hand) |h| send(features(h, cam.w, cam.h)) else send(.{ .kind = 0, .has = 0 });
    }
}

fn openCamera() ?v4l2.Camera {
    // 設定のカメラ、無ければ /dev/video0〜9 で YUYV を出せる最初のもの
    if (st.device_len > 0) {
        const p: [*:0]const u8 = @ptrCast(&st.device);
        return v4l2.Camera.open(p, 640, 480, 30) catch |e| {
            log.warn("{s} を開けません: {}", .{ st.device[0..st.device_len], e });
            return null;
        };
    }
    var buf: [32]u8 = undefined;
    for (0..10) |i| {
        const p = std.fmt.bufPrintZ(&buf, "/dev/video{d}", .{i}) catch continue;
        if (v4l2.Camera.open(p.ptr, 640, 480, 30)) |cam| return cam else |_| {}
    }
    return null;
}

fn dist(p: [21][3]f32, a: usize, b: usize) f32 {
    const dx = p[a][0] - p[b][0];
    const dy = p[a][1] - p[b][1];
    return @sqrt(dx * dx + dy * dy);
}

/// 関節から、手の形とカーソルの位置を出す
fn features(h: track.Hand, w: usize, hh: usize) Msg {
    const p = h.pts;
    const s = @max(dist(p, 0, 9), 1);
    // 指が伸びているか: 「指先〜手首」が「第 2 関節〜手首」より長い(伸びている 1.3 前後、曲げている 0.6〜0.7)
    const tips = [_]usize{ 8, 12, 16, 20 };
    const pips = [_]usize{ 6, 10, 14, 18 };
    var ratio: [4]f32 = undefined;
    var ext: [4]bool = undefined;
    for (0..4) |i| {
        ratio[i] = dist(p, tips[i], 0) / @max(dist(p, pips[i], 0), 1);
        ext[i] = ratio[i] > 1.0;
    }
    const pinch = dist(p, 4, 8) / s;
    // 親指が伸びているか(いいねの形・開いた手): 親指の先が中指の付け根から離れている(曲げていると 0.2 前後、伸ばすと 1 前後)
    const thumb = dist(p, 4, 9) / s > 0.7 and dist(p, 4, 5) / s > 0.5;
    // 手が遠く小さく映っているときは、カーソルを動かすだけ(誤検出で操作しないように)
    const small = s < @as(f32, @floatFromInt(w)) * 0.06;
    var number: u8 = 0;
    const g: Gesture = blk: {
        if (small) break :blk .point;
        // つまむ: 親指と人差し指の先が近く、人差し指は曲げきっていない(握りこぶしと分ける)
        if (pinch < 0.3 and ratio[0] > 0.85) break :blk .pinch;
        const n4 = @as(u8, @intFromBool(ext[0])) + @intFromBool(ext[1]) + @intFromBool(ext[2]) + @intFromBool(ext[3]);
        if (n4 == 0) {
            // 親指だけ立てる(いいね)= 1、全部曲げる = 握りこぶし
            if (thumb) {
                number = 1;
                break :blk .number;
            }
            break :blk .fist;
        }
        if (n4 == 4) {
            // 4 本 + 親指 = 開いた手、親指を曲げて 4 本 = 4
            if (thumb) break :blk .open;
            number = 4;
            break :blk .number;
        }
        // 人差し指だけ = 指さす(親指はどちらでもよい)
        if (ext[0] and !ext[1] and !ext[2] and !ext[3]) break :blk .point;
        // 人差し指から順に 2 本・3 本(ピース・3 本指)= 2・3
        if (ext[0] and ext[1] and !ext[2] and !ext[3]) {
            number = 2;
            break :blk .number;
        }
        if (ext[0] and ext[1] and ext[2] and !ext[3]) {
            number = 3;
            break :blk .number;
        }
        break :blk .other;
    };
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(hh);
    // カーソル: ふだんは人差し指の先。つまむ動きに近づくほど、親指との中点へ(つまんだ瞬間に跳ねないように)
    const t = std.math.clamp((pinch - 0.3) / 0.35, 0, 1);
    const mx = (p[4][0] + p[8][0]) / 2;
    const my = (p[4][1] + p[8][1]) / 2;
    const ix = mx + (p[8][0] - mx) * t;
    const iy = my + (p[8][1] - my) * t;
    // カメラの真ん中の範囲を画面全体に(画面の端まで手を伸ばさなくてよいように)
    const mxr = 0.18;
    const myr = 0.15;
    const cx = std.math.clamp((ix / fw - mxr) / (1 - 2 * mxr), 0, 1);
    const cy = std.math.clamp((iy / fh - myr) / (1 - 2 * myr), 0, 1);
    return .{
        .kind = 0,
        .has = 1,
        .gesture = @intFromEnum(g),
        .cx = cx,
        .cy = cy,
        .px = p[9][0] / fw,
        .py = p[9][1] / fh,
        .pinch = pinch,
        .fingers = number,
    };
}

// ---- モデルのファイル ----

fn modelPath(buf: []u8) ?[:0]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |d| if (d.len > 0) return std.fmt.bufPrintZ(buf, "{s}/ame-shell/models/hand_landmarker.task", .{d}) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.local/share/ame-shell/models/hand_landmarker.task", .{home}) catch null;
}

fn loadModel(a: std.mem.Allocator) ?[]u8 {
    var pb: [512]u8 = undefined;
    const path = modelPath(&pb) orelse {
        sendStatus(.no_model);
        return null;
    };
    if (std.fs.cwd().readFileAlloc(a, path, 64 << 20)) |b| {
        if (zip.isHandModel(b)) return b;
        a.free(b);
    } else |_| {}
    // 無い・壊れている: 取ってくる(curl。一時ファイルに書いてから置き換える)
    sendStatus(.downloading);
    const dir = std.fs.path.dirname(path) orelse return null;
    std.fs.cwd().makePath(dir) catch {};
    var tb: [520]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tb, "{s}.part", .{path}) catch return null;
    var pid: c_int = 0;
    const fd = sys.spawnReader(&.{ "curl", "-sSfL", "--max-time", "180", "-o", tmp.ptr, MODEL_URL }, &pid) orelse {
        sendStatus(.no_model);
        return null;
    };
    // curl が終わる(pipe が閉じる)まで待つ。オフにされたら途中でやめる
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
    std.fs.cwd().rename(tmp, path) catch {
        sendStatus(.no_model);
        return null;
    };
    const b = std.fs.cwd().readFileAlloc(a, path, 64 << 20) catch {
        sendStatus(.no_model);
        return null;
    };
    if (zip.isHandModel(b)) return b;
    a.free(b);
    std.fs.cwd().deleteFile(path) catch {};
    sendStatus(.no_model);
    return null;
}


/// 試験用(ame-ctl debug-hand): カメラ無しで 1 コマ分の手を与える。"<形> <x> <y>"(x, y は画面の 0〜1)
pub fn debugInject(app: *App, args: []const u8) void {
    if (!st.on or st.surf == null) return;
    st.debug_until = loop.nowMs() + 2500;
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const g = std.meta.stringToEnum(Gesture, it.next() orelse "none") orelse .none;
    // "number 3 x y" のように、指の本数の形は本数を続けて書く
    const fingers: u8 = if (g == .number) std.fmt.parseInt(u8, it.next() orelse "1", 10) catch 1 else 0;
    const x = std.fmt.parseFloat(f32, it.next() orelse "0.5") catch 0.5;
    const y = std.fmt.parseFloat(f32, it.next() orelse "0.5") catch 0.5;
    if (g == .none) {
        // 見失ったことにする(少し前に見えていたことにして、すぐ消す)
        st.last_seen = loop.nowMs() -| 1000;
        frame(app, .{ .kind = 0, .has = 0 });
        return;
    }
    frame(app, .{ .kind = 0, .has = 1, .gesture = @intFromEnum(g), .cx = x, .cy = y, .px = x, .py = y, .pinch = if (g == .pinch) 0.15 else 1.0, .fingers = fingers });
}
