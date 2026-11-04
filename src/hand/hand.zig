// ハンド操作: カメラに映った手の動きで、カーソルと窓を操作する(オン/オフできる。既定はオフ)。
//
//   指さす(人差し指だけ伸ばす)… カーソルが指先に付いて動く(窓のフォーカスもカーソルに付いて移る)
//   つまむ(親指と人差し指)     … 短く: クリック(2 回でダブルクリック)/ つまんですぐ動かす: ドラッグ(左ボタンを
//                                  押したまま。文字の選択・ファイルを運ぶ)/ つまんで 0.45 秒止めてから動かす: 窓をつかんで
//                                  動かす。つかんだまま手をカメラに近づける・遠ざけると、窓が大きく・小さくなる(ズーム)
//   親指と中指でつまむ           … 右クリック   / 親指と薬指でつまむ … 真ん中のクリック
//   ピース(人差し指と中指)を上下・左右に動かす … スクロール
//   ポーズの割り当て(poses.zig・設定画面 posegui.zig)… 片手・両手のポーズを 0.7 秒止めると、割り当てた操作・アプリ
//   手を左右に払う               … 隣のワークスペースへ(左へ払う = 次、右へ = 前)
//   指の本数を示して止める       … その番号のワークスペース(親指だけ = 1、ピース = 2、3 本 = 3、親指を曲げて 4 本 = 4)
//   開いた手を止める(0.8 秒)   … 手のメニュー: ランチャー・ダッシュボード・全画面・浮かせる・大きく・小さく・
//                                  スクショ・閉じる、下にワークスペース 1〜9。指して、つまむか止めて選ぶ
//   握りこぶしを保つ(0.9 秒)   … フォーカス中の窓を閉じる(メニューが開いていればメニューを閉じる)
// 操作のたびに水の波紋が広がり、カーソルの後ろには船が通った跡のような V 字の波が残る。
//
// 作り:
//   別スレッド … カメラ(platform/v4l2.zig)→ 暗ければ明るく → 関節 21 点(track.zig + nn.zig)→
//                形と位置(gesture.zig)を pipe でメインへ
//   メイン     … 形の続き具合・時間で操作を決め、仮想ポインタ(wlr-virtual-pointer)と WM(wm.zig)に伝える。
//                オーバーレイ(layer-shell の一番上・入力は透過)にカーソル・波・メニューを描く
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
// 手の認識そのもの(推論エンジン・追跡・ジェスチャー・カメラ)は別のリポジトリ ame-hand
const handlib = @import("ame-hand");
const v4l2 = handlib.v4l2;
const track = handlib.track;
const nn = handlib.nn;
const zip = handlib.zip;
const gesture = handlib.gesture;
const poses = @import("poses.zig");
const custom = @import("custom.zig");

const log = std.log.scoped(.hand);

const MODEL_URL = "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task";

pub const Gesture = gesture.Gesture;

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
    /// カーソル(画面の 0〜1)・手のひらの中心(カメラの 0〜1、生の値)・つまみの近さ・手の大きさ
    cx: f32 = 0,
    cy: f32 = 0,
    px: f32 = 0,
    py: f32 = 0,
    pinch: f32 = 9,
    size: f32 = 0.2,
    /// 親指と中指・薬指の近さ(右クリック・真ん中のクリック)
    pinch_mid: f32 = 9,
    pinch_ring: f32 = 9,
    /// 伸びている指(poses.zig のビット)。has2 = もう一方の手が映っている、ext2 = その手の指
    ext: u8 = 0,
    has2: u8 = 0,
    ext2: u8 = 0,
    _r2: u8 = 0,
    /// 手の形(custom.zig の正規化した 21 点)。自分のポーズを見分ける・登録するのに使う
    shape: custom.Shape = [_]f32{0} ** custom.DIM,
    shape2: custom.Shape = [_]f32{0} ** custom.DIM,
};

/// ポーズを止めて割り当ての操作が動くまで(ms)
const POSE_MS = 700;
/// つまんでから止めたまま、この時間がたったら窓をつかむ(その前に動かせばアプリの中のドラッグ)
const GRAB_MS = 450;

/// 波紋: 広がりきる半径(px)と時間(ms)
const Ripple = struct { x: f32, y: f32, t0: u64, col: Color, size: f32, dur: f32 };
const WakePt = struct { x: f32, y: f32, t: u64 };
/// 航跡が消えるまで(ms)
const WAKE_MS: f32 = 1300;

const HOLD_FIST_MS = 900;
const HOLD_MENU_MS = 800;
const HOLD_NUM_MS = 650;
const DWELL_MS = 650;

// ---- 手のメニュー ----
const Item = enum { launcher, dashboard, fullscreen, float, bigger, smaller, screenshot, close, poses };
const items = [_]struct { it: Item, icon: []const u8, label: []const u8 }{
    .{ .it = .launcher, .icon = "\u{F003B}", .label = "ランチャー" },
    .{ .it = .dashboard, .icon = "\u{F056E}", .label = "ダッシュボード" },
    .{ .it = .fullscreen, .icon = "\u{F0293}", .label = "全画面" },
    .{ .it = .float, .icon = "\u{F05B2}", .label = "浮かせる" },
    .{ .it = .bigger, .icon = "\u{F0349}", .label = "大きく" },
    .{ .it = .smaller, .icon = "\u{F034A}", .label = "小さく" },
    .{ .it = .screenshot, .icon = "\u{F0100}", .label = "スクショ" },
    .{ .it = .close, .icon = "\u{F0156}", .label = "閉じる" },
    .{ .it = .poses, .icon = "\u{F1821}", .label = "ポーズの設定" },
};
const MENU_R: f32 = 142;
const ITEM_R: f32 = 30;
const WS_GAP: f32 = 40;

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
    seen_since: u64 = 0,
    last_seen: u64 = 0,
    cur: [2]f32 = .{ 0, 0 }, // 出力の論理座標
    filt: [2]gesture.Euro = .{ .{}, .{} },
    size: f32 = 0.2, // 手の大きさ(ならした値)
    shown: Spring = Spring.init(0, 0.22, 0.8),
    press: Spring = Spring.init(0, 0.14, 0.7),
    gesture: Gesture = .none,
    fingers: u8 = 0,
    cand: Gesture = .none,
    cand_fingers: u8 = 0,
    cand_n: u8 = 0,
    // つまむ
    pinching: bool = false,
    pinch_t0: u64 = 0,
    pinch_p0: [2]f32 = .{ 0, 0 },
    dragging: bool = false,
    /// 旧 River でのつかむ動き: 仮想ポインタの左ボタンを押したまま
    vbutton: bool = false,
    drag_size0: f32 = 0.2,
    // 払う(手のひらの生の位置、カメラの 0〜1)
    hist: [16]struct { t: u64, x: f32 } = undefined,
    n_hist: usize = 0,
    swipe_quiet: u64 = 0,
    // 保つ(握りこぶし = 閉じる、開いた手 = メニュー)
    hold: Gesture = .none,
    hold_t0: u64 = 0,
    hold_p0: [2]f32 = .{ 0, 0 },
    hold_done: bool = false,
    /// 払った後は、手の形が変わるまで開いた手でメニューを開かない
    open_blocked: bool = false,
    // 指の本数
    num: u8 = 0,
    num_t0: u64 = 0,
    num_p0: [2]f32 = .{ 0, 0 },
    num_done: bool = false,
    // メニュー
    menu: bool = false,
    menu_c: [2]f32 = .{ 0, 0 },
    menu_s: Spring = Spring.init(0, 0.22, 0.72),
    menu_hover: i32 = -1, // 0〜7 = 項目、100〜108 = ワークスペース 1〜9
    hover_t0: u64 = 0,
    // 航跡・波紋
    wake: [64]WakePt = undefined,
    n_wake: usize = 0,
    ripples: [24]Ripple = undefined,
    n_ripples: usize = 0,
    // 大きな表示(ワークスペースを移ったときの「→ 3」など)
    banner: [64]u8 = undefined,
    banner_len: usize = 0,
    banner_t0: u64 = 0,
    // 状態の表示
    msg: [128]u8 = undefined,
    msg_len: usize = 0,
    msg_until: u64 = 0,
    /// 試験(debug-hand)で値を与えている間は、カメラからの結果を無視する
    debug_until: u64 = 0,
    debug_log: bool = false,
    last_logged: Gesture = .none,
    // ---- クリック・ドラッグ・スクロール(マウスの代わりに全部できるように)----
    /// 親指と中指・薬指でつまんでいる(0 = なし / 右 0x111 / 真ん中 0x112)
    alt_btn: u32 = 0,
    alt_t0: u64 = 0,
    /// つまんで動かしたのが、アプリの中のドラッグ(左ボタンを押したまま)か。false なら窓をつかんでいる
    app_drag: bool = false,
    /// ピースを動かしてスクロールしている
    scrolling: bool = false,
    scroll_p0: [2]f32 = .{ 0, 0 },
    scroll_last: [2]f32 = .{ 0, 0 },
    // ---- ポーズの割り当て ----
    ext: u8 = 0,
    ext2: u8 = poses.NONE,
    cand_ext: u8 = 0,
    cand_ext2: u8 = poses.NONE,
    cand_ext_n: u8 = 0,
    pose_a: u8 = poses.NONE,
    pose_b: u8 = poses.NONE,
    pose_t0: u64 = 0,
    pose_p0: [2]f32 = .{ 0, 0 },
    pose_done: bool = false,
    pose_bind: ?*const poses.Binding = null,
    /// 最新の手の形と、その番号(届くたびに増える。ポーズの登録で使う)
    shape: custom.Shape = [_]f32{0} ** custom.DIM,
    shape_seq: u32 = 0,
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
    st.menu = false;
    st.n_ripples = 0;
    st.n_wake = 0;
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

fn setBanner(s: []const u8) void {
    const n = @min(s.len, st.banner.len);
    @memcpy(st.banner[0..n], s[0..n]);
    st.banner_len = n;
    st.banner_t0 = loop.nowMs();
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
            if (g != st.last_logged) log.info("カメラ: {s} {d}(つまみ {d:.2}、大きさ {d:.2}、位置 {d:.2}, {d:.2})", .{ @tagName(g), m.fingers, m.pinch, m.size, m.cx, m.cy });
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

fn dist2(a: [2]f32, b: [2]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return dx * dx + dy * dy;
}

fn lost(app: *App) void {
    _ = app;
    st.visible = false;
    st.shown.set(0);
    if (st.pinching) {
        st.pinching = false;
        st.press.set(0);
        endDrag();
    }
    st.hold = .none;
    st.num = 0;
    st.n_hist = 0;
    st.menu = false;
    st.menu_s.set(0);
    st.alt_btn = 0;
    if (st.scrolling) scrollStop();
    st.scrolling = false;
    st.pose_bind = null;
    st.pose_a = poses.NONE;
    st.ext2 = poses.NONE;
}

fn frame(app: *App, m: Msg) void {
    const now = loop.nowMs();
    const sf = st.surf orelse return;
    if (m.has == 0) {
        // 手が消えた: 少し待ってから(1 コマの見失いでつかんだ窓を落とさないように)
        if (st.visible and now -| st.last_seen > 450) {
            lost(app);
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
        st.size = m.size;
    }
    st.cur = .{ st.filt[0].step(raw[0], tsec), st.filt[1].step(raw[1], tsec) };
    st.size += (m.size - st.size) * 0.35;
    st.visible = true;
    st.last_seen = now;
    st.shown.set(1);

    // 形: 2 コマ(指の本数は 3 コマ)続いたら確定(見間違いで操作しない)
    const g: Gesture = @enumFromInt(m.gesture);
    if (g == st.cand and m.fingers == st.cand_fingers) st.cand_n +|= 1 else {
        st.cand = g;
        st.cand_fingers = m.fingers;
        st.cand_n = 1;
    }
    const need_n: u8 = if (st.cand == .number) 3 else 2;
    if (st.cand_n >= need_n) {
        st.gesture = st.cand;
        st.fingers = st.cand_fingers;
    }
    const settled = now -| st.seen_since >= 500;

    movePointer(st.cur);
    wakeAdd(app, st.cur, now);

    if (st.menu) {
        menuFrame(app, m, now);
        sf.schedule();
        return;
    }

    // ---- 伸びている指(ポーズ)・もう一方の手: 3 コマ続いたら確定 ----
    // 自分のポーズ(登録した形)に近ければその値、でなければ伸びている指
    const id1: u8 = if (custom.match(&m.shape)) |i| custom.BASE + @as(u8, @intCast(i)) else m.ext;
    const e2: u8 = if (m.has2 == 0) poses.NONE else if (custom.match(&m.shape2)) |i| custom.BASE + @as(u8, @intCast(i)) else m.ext2;
    // 登録の画面が撮れるように、最新の形を残す
    st.shape = m.shape;
    st.shape_seq +%= 1;
    if (id1 == st.cand_ext and e2 == st.cand_ext2) st.cand_ext_n +|= 1 else {
        st.cand_ext = id1;
        st.cand_ext2 = e2;
        st.cand_ext_n = 1;
    }
    if (st.cand_ext_n >= 3) {
        st.ext = st.cand_ext;
        st.ext2 = st.cand_ext2;
    }

    // ---- 親指と中指 = 右クリック、親指と薬指 = 真ん中のクリック(人差し指はつままない)----
    if (!st.pinching) {
        const want: u32 = if (st.alt_btn == 0x111)
            (if (m.pinch_mid < 0.45 and m.pinch > 0.4) 0x111 else 0)
        else if (st.alt_btn == 0x112)
            (if (m.pinch_ring < 0.45 and m.pinch > 0.4) 0x112 else 0)
        else if (m.pinch_mid < 0.3 and m.pinch > 0.45)
            0x111
        else if (m.pinch_ring < 0.3 and m.pinch > 0.45 and m.pinch_mid > 0.45)
            0x112
        else
            0;
        if (want != 0 and st.alt_btn == 0) {
            st.alt_btn = want;
            st.alt_t0 = now;
            st.press.set(1);
            addRipple(st.cur, theme.accent(app).lighten(0.4), 50, 800);
        } else if (want == 0 and st.alt_btn != 0) {
            const b = st.alt_btn;
            st.alt_btn = 0;
            st.press.set(0);
            if (now -| st.alt_t0 < 900) {
                clickButton(b);
                addRipple(st.cur, Color.hex(0xffb86b), 100, 1000);
                setBanner(if (b == 0x111) "右クリック" else "真ん中のクリック");
            }
        }
    }

    // ---- つまむ: 短くでクリック。すぐ動かすとドラッグ、止めてから動かすと窓をつかむ ----
    const pinch_now = st.alt_btn == 0 and (if (st.pinching) m.pinch < 0.48 and st.gesture != .open else st.gesture == .pinch);
    if (pinch_now and !st.pinching) {
        st.pinching = true;
        st.pinch_t0 = now;
        st.pinch_p0 = st.cur;
        st.dragging = false;
        st.app_drag = false;
        st.press.set(1);
        addRipple(st.cur, theme.accent(app), 60, 900);
    } else if (pinch_now and st.pinching) {
        const dx = st.cur[0] - st.pinch_p0[0];
        const dy = st.cur[1] - st.pinch_p0[1];
        const moved = dx * dx + dy * dy > 30 * 30;
        if (!st.dragging) {
            if (moved and now -| st.pinch_t0 < GRAB_MS) {
                // すぐ動かした: アプリの中のドラッグ(つまんだ所で左ボタンを押し、押したまま動かす)
                if (appDragStart()) {
                    st.dragging = true;
                    st.app_drag = true;
                    setBanner("ドラッグ");
                }
            } else if (!moved and now -| st.pinch_t0 >= GRAB_MS) {
                // 止めていた: 窓をつかむ
                if (grabStart(app)) {
                    st.dragging = true;
                    st.app_drag = false;
                    st.drag_size0 = st.size;
                    addRipple(st.cur, theme.accent(app).lighten(0.1), 80, 900);
                }
            }
        }
        // 旧 River では、押したままのカーソルの動き(movePointer)がそのままドラッグになる
        if (st.dragging and !st.app_drag) if (app.wm) |w| {
            // 手の大きさの変わり方 = ズーム(少しの揺れは無視する)
            var scale = st.size / @max(st.drag_size0, 0.01);
            if (@abs(scale - 1) < 0.07) scale = 1 else scale = std.math.clamp(1 + (scale - 1) * 1.4, 0.45, 2.4);
            w.push(.{ .hand_drag = .{ .dx = @intFromFloat(dx), .dy = @intFromFloat(dy), .scale = scale } });
        };
    } else if (!pinch_now and st.pinching) {
        st.pinching = false;
        st.press.set(0);
        if (st.dragging) {
            endDrag();
            addRipple(st.cur, theme.accent(app).lighten(0.2), 110, 1100);
        } else {
            click();
            addRipple(st.cur, theme.accent(app).lighten(0.3), 110, 1100);
        }
    }

    // ---- ピース(人差し指と中指)を動かす: スクロール。止めていればワークスペース 2(下の「本数」)----
    const peace = st.gesture == .number and st.fingers == 2 and !st.pinching;
    if (!peace) {
        if (st.scrolling) scrollStop();
        st.scrolling = false;
        st.scroll_p0 = st.cur;
    } else if (!st.scrolling) {
        if (dist2(st.cur, st.scroll_p0) > 22 * 22) {
            st.scrolling = true;
            st.scroll_last = st.cur;
            st.num = 0;
            st.num_done = true; // スクロールしたら、ワークスペース 2 には移らない
        }
    } else {
        const dx = st.cur[0] - st.scroll_last[0];
        const dy = st.cur[1] - st.scroll_last[1];
        st.scroll_last = st.cur;
        // 手を下げると下へ(ホイールを手前に回すのと同じ向き)
        scroll(dx * 1.6, dy * 1.6);
    }

    // ---- ポーズの割り当て(設定画面で決めたもの): 0.7 秒止めると動く ----
    const bind: ?*const poses.Binding = if (st.pinching or st.alt_btn != 0 or !settled or st.scrolling or
        (st.ext == poses.POINT and st.ext2 == poses.NONE)) null else poses.find(st.ext, st.ext2);
    if (bind) |b| {
        if (st.pose_a != st.ext or st.pose_b != st.ext2 or dist2(st.cur, st.pose_p0) > 50 * 50) {
            st.pose_a = st.ext;
            st.pose_b = st.ext2;
            st.pose_t0 = now;
            st.pose_p0 = st.cur;
            st.pose_done = false;
        } else if (!st.pose_done and now -| st.pose_t0 >= POSE_MS) {
            st.pose_done = true;
            poses.run(app, b);
            var db: [160]u8 = undefined;
            setBanner(poses.describe(app, b, &db));
            addRipple(st.cur, theme.accent(app).lighten(0.15), 150, 1200);
        }
        st.pose_bind = b;
    } else {
        st.pose_bind = null;
        st.pose_a = poses.NONE;
        st.pose_b = poses.NONE;
    }
    // 割り当てたポーズ・両手のときは、元からある動き(メニュー・閉じる・本数)を使わない
    const overriding = bind != null or st.ext2 != poses.NONE or custom.isId(st.ext);

    // ---- 払う: 手のひらが速く横に動いた(指さし・つまみ・握りこぶし以外の形で)----
    const swipeable = !overriding and !st.pinching and (st.gesture == .open or st.gesture == .other or (st.gesture == .number and st.fingers >= 3));
    if (swipeable) {
        if (st.n_hist == st.hist.len) {
            std.mem.copyForwards(@TypeOf(st.hist[0]), st.hist[0 .. st.hist.len - 1], st.hist[1..]);
            st.n_hist -= 1;
        }
        st.hist[st.n_hist] = .{ .t = now, .x = m.px };
        st.n_hist += 1;
        var k: usize = 0;
        while (k < st.n_hist and now -| st.hist[k].t > 380) k += 1;
        if (k < st.n_hist and now >= st.swipe_quiet) {
            const dx = m.px - st.hist[k].x;
            if (@abs(dx) > 0.16) {
                const dir: i32 = if (dx < 0) 1 else -1;
                if (stepWorkspace(app, dir)) |n| {
                    var b: [32]u8 = undefined;
                    setBanner(std.fmt.bufPrint(&b, "{s} {d}", .{ if (dir > 0) "→" else "←", n }) catch "");
                    addRipple(st.cur, theme.accent(app), 140, 1200);
                } else setBanner(if (dir > 0) "これより先はありません" else "これより前はありません");
                st.swipe_quiet = now + 750;
                st.n_hist = 0;
                st.open_blocked = true;
                st.hold = .none;
            }
        }
    } else st.n_hist = 0;

    // ---- 保つ: 握りこぶし = 閉じる、開いた手 = メニュー ----
    if (st.gesture != .open) st.open_blocked = false;
    const holdable = !overriding and settled and (st.gesture == .fist or (st.gesture == .open and !st.open_blocked)) and !st.pinching;
    if (!holdable) {
        st.hold = .none;
    } else {
        if (st.hold != st.gesture or dist2(st.cur, st.hold_p0) > 44 * 44) {
            st.hold = st.gesture;
            st.hold_t0 = now;
            st.hold_p0 = st.cur;
            st.hold_done = false;
        } else if (!st.hold_done) {
            const need: u64 = if (st.hold == .fist) HOLD_FIST_MS else HOLD_MENU_MS;
            if (now -| st.hold_t0 >= need) {
                st.hold_done = true;
                if (st.hold == .fist) {
                    winOp(app, .close);
                    addRipple(st.cur, theme.danger(app), 120, 1100);
                    setBanner("閉じました");
                } else openMenu(app);
            }
        }
    }

    // ---- 指の本数を示して止める: そのワークスペースへ ----
    if (overriding or st.gesture != .number or st.pinching or !settled) {
        st.num = 0;
        if (!st.scrolling) st.num_done = false;
    } else if (st.scrolling) {
        st.num = 0;
    } else {
        if (st.num != st.fingers or dist2(st.cur, st.num_p0) > 60 * 60) {
            if (st.num != st.fingers) st.num_done = false;
            st.num = st.fingers;
            st.num_t0 = now;
            st.num_p0 = st.cur;
        } else if (!st.num_done and now -| st.num_t0 >= HOLD_NUM_MS) {
            st.num_done = true;
            gotoWorkspace(app, st.num);
        }
    }
    sf.schedule();
}

fn gotoWorkspace(app: *App, n: u8) void {
    if (n < 1 or n > 9) return;
    app.focusTags(@as(u32, 1) << @intCast(n - 1));
    var b: [32]u8 = undefined;
    setBanner(std.fmt.bufPrint(&b, "ワークスペース {d}", .{n}) catch "");
    addRipple(st.cur, theme.accent(app), 150, 1300);
}

// ---- 手のメニュー ----

fn openMenu(app: *App) void {
    const sz = outSize();
    // 画面からはみ出さないように中心を寄せる(下にワークスペースの列があるので下は多めに)
    st.menu_c = .{
        std.math.clamp(st.cur[0], MENU_R + ITEM_R + 20, sz[0] - MENU_R - ITEM_R - 20),
        std.math.clamp(st.cur[1], MENU_R + ITEM_R + 20, sz[1] - MENU_R - ITEM_R - 110),
    };
    st.menu = true;
    st.menu_s.set(1);
    st.menu_hover = -1;
    st.hold = .none;
    addRipple(st.menu_c, theme.accent(app), MENU_R + 40, 900);
}

fn closeMenu() void {
    st.menu = false;
    st.menu_s.set(0);
    st.menu_hover = -1;
}

fn itemPos(i: usize) [2]f32 {
    // 上から時計回り
    const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * (2 * std.math.pi / @as(f32, @floatFromInt(items.len)));
    return .{ st.menu_c[0] + @cos(a) * MENU_R, st.menu_c[1] + @sin(a) * MENU_R };
}

fn wsPos(i: usize) [2]f32 {
    return .{ st.menu_c[0] + (@as(f32, @floatFromInt(i)) - 4) * WS_GAP, st.menu_c[1] + MENU_R + ITEM_R + 52 };
}

fn hitMenu(p: [2]f32) i32 {
    for (0..items.len) |i| if (dist2(p, itemPos(i)) < (ITEM_R + 8) * (ITEM_R + 8)) return @intCast(i);
    for (0..9) |i| if (dist2(p, wsPos(i)) < 18 * 18) return @intCast(100 + i);
    return -1;
}

fn menuFrame(app: *App, m: Msg, now: u64) void {
    // 閉じる: 握りこぶし・メニューから大きく離れた
    if (st.gesture == .fist or dist2(st.cur, st.menu_c) > (MENU_R + 220) * (MENU_R + 220)) {
        closeMenu();
        return;
    }
    const h = hitMenu(st.cur);
    if (h != st.menu_hover) {
        st.menu_hover = h;
        st.hover_t0 = now;
    }
    // 決める: つまむ、または同じ項目の上で止める
    const pinch_now = st.gesture == .pinch or (st.pinching and m.pinch < 0.48);
    const tap = pinch_now and !st.pinching;
    st.pinching = pinch_now;
    st.press.set(if (pinch_now) 1 else 0);
    if (h >= 0 and (tap or now -| st.hover_t0 >= DWELL_MS)) choose(app, h);
}

fn choose(app: *App, h: i32) void {
    const p = if (h >= 100) wsPos(@intCast(h - 100)) else itemPos(@intCast(h));
    addRipple(p, theme.accent(app).lighten(0.2), 90, 900);
    closeMenu();
    st.hold = .none;
    st.hold_done = true; // 開いた手のままでも、すぐまたメニューが開かないように
    st.open_blocked = true;
    if (h >= 100) return gotoWorkspace(app, @intCast(h - 100 + 1));
    const ipc = @import("../ipc.zig");
    switch (items[@intCast(h)].it) {
        .launcher => ipc.runCommand(app, "launcher open"),
        .dashboard => ipc.runCommand(app, "dashboard toggle"),
        .fullscreen => winOp(app, .fullscreen),
        .float => winOp(app, .float),
        .bigger => winScale(app, 1.2),
        .smaller => winScale(app, 1.0 / 1.2),
        .screenshot => @import("../shot.zig").take(app, .full, 450),
        .close => winOp(app, .close),
        .poses => @import("posegui.zig").open(app),
    }
    setBanner(items[@intCast(h)].label);
}

// ---- 航跡: カーソルが通った跡に、船の跡のような V 字の波 ----

fn wakeAdd(app: *App, p: [2]f32, now: u64) void {
    if (!app.cfg.hand_trail) return;
    if (st.n_wake > 0) {
        const last = st.wake[st.n_wake - 1];
        if (dist2(p, .{ last.x, last.y }) < 5 * 5) return;
    }
    if (st.n_wake == st.wake.len) {
        std.mem.copyForwards(WakePt, st.wake[0 .. st.wake.len - 1], st.wake[1..]);
        st.n_wake -= 1;
    }
    st.wake[st.n_wake] = .{ .x = p[0], .y = p[1], .t = now };
    st.n_wake += 1;
}

/// 手のメニューを開く(ポーズの割り当てから)
pub fn openMenuPublic(app: *App) void {
    if (!st.on or !st.visible) return;
    openMenu(app);
}

/// 左ボタン以外のクリック(右 0x111・真ん中 0x112)
fn clickButton(btn: u32) void {
    const vp = st.vptr orelse return;
    const t: u32 = @truncate(loop.nowMs());
    c.zwlr_virtual_pointer_v1_button(vp, t, btn, 1);
    c.zwlr_virtual_pointer_v1_frame(vp);
    c.zwlr_virtual_pointer_v1_button(vp, t + 8, btn, 0);
    c.zwlr_virtual_pointer_v1_frame(vp);
}

/// アプリの中のドラッグを始める: つまみ始めた所で左ボタンを押し、今の場所へ動かす(押したまま)
fn appDragStart() bool {
    const vp = st.vptr orelse return false;
    movePointer(st.pinch_p0);
    c.zwlr_virtual_pointer_v1_button(vp, @truncate(loop.nowMs()), 0x110, 1);
    c.zwlr_virtual_pointer_v1_frame(vp);
    st.vbutton = true;
    movePointer(st.cur);
    return true;
}

/// スクロール(論理 px。指で滑らせたのと同じ「なめらか」な量で送る)
fn scroll(dx: f32, dy: f32) void {
    const vp = st.vptr orelse return;
    if (@abs(dx) < 0.5 and @abs(dy) < 0.5) return;
    const t: u32 = @truncate(loop.nowMs());
    c.zwlr_virtual_pointer_v1_axis_source(vp, c.WL_POINTER_AXIS_SOURCE_FINGER);
    if (@abs(dy) >= 0.5) c.zwlr_virtual_pointer_v1_axis(vp, t, c.WL_POINTER_AXIS_VERTICAL_SCROLL, @intFromFloat(dy * 256));
    if (@abs(dx) >= 0.5) c.zwlr_virtual_pointer_v1_axis(vp, t, c.WL_POINTER_AXIS_HORIZONTAL_SCROLL, @intFromFloat(dx * 256));
    c.zwlr_virtual_pointer_v1_frame(vp);
}

fn scrollStop() void {
    const vp = st.vptr orelse return;
    const t: u32 = @truncate(loop.nowMs());
    c.zwlr_virtual_pointer_v1_axis_source(vp, c.WL_POINTER_AXIS_SOURCE_FINGER);
    c.zwlr_virtual_pointer_v1_axis_stop(vp, t, c.WL_POINTER_AXIS_VERTICAL_SCROLL);
    c.zwlr_virtual_pointer_v1_axis_stop(vp, t, c.WL_POINTER_AXIS_HORIZONTAL_SCROLL);
    c.zwlr_virtual_pointer_v1_frame(vp);
}

fn endDrag() void {
    if (!st.dragging) return;
    st.dragging = false;
    // アプリの中のドラッグは左ボタンを離すだけ(内蔵 WM の「つかむ」は使っていない)
    if (!st.app_drag) if (st.app) |app| if (app.wm) |w| w.push(.hand_release);
    st.app_drag = false;
    if (st.vbutton) {
        st.vbutton = false;
        if (st.vptr) |vp| {
            c.zwlr_virtual_pointer_v1_button(vp, @truncate(loop.nowMs()), 0x110, 0);
            c.zwlr_virtual_pointer_v1_frame(vp);
        }
    }
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
// オーバーレイ
// ---------------------------------------------------------------------------

/// 船の航跡: 通った線から、時間がたつほど両側へ開いていく 2 本の波(V 字)と、その間を横切る弧の波、
/// 通ったばかりの所の白い泡。古いところほど広く、薄く、細くなる
fn drawWake(cv: *gfx.Canvas, acc: Color, now: u64) bool {
    var drop: usize = 0;
    while (drop < st.n_wake and @as(f32, @floatFromInt(now -| st.wake[drop].t)) > WAKE_MS) drop += 1;
    if (drop > 0) {
        std.mem.copyForwards(WakePt, st.wake[0 .. st.n_wake - drop], st.wake[drop..st.n_wake]);
        st.n_wake -= drop;
    }
    if (st.n_wake < 2) return st.n_wake > 0;
    const white = Color.hex(0xffffff);
    var pl: [2]f32 = undefined;
    var pr: [2]f32 = undefined;
    var pc: [2]f32 = undefined;
    for (st.wake[0..st.n_wake], 0..) |pt, i| {
        const nb = st.wake[@min(i + 1, st.n_wake - 1)];
        const pa = st.wake[if (i > 0) i - 1 else 0];
        var tx = nb.x - pa.x;
        var ty = nb.y - pa.y;
        const tl = @max(@sqrt(tx * tx + ty * ty), 0.001);
        tx /= tl;
        ty /= tl;
        const age = std.math.clamp(@as(f32, @floatFromInt(now -| pt.t)) / WAKE_MS, 0, 1);
        const life = 1 - age;
        // 開く幅: 最初は速く、だんだんゆっくり(波が広がっていく)
        const hw = 3 + 64 * @sqrt(age);
        const l = [2]f32{ pt.x - ty * hw, pt.y + tx * hw };
        const r = [2]f32{ pt.x + ty * hw, pt.y - tx * hw };
        const cpt = [2]f32{ pt.x, pt.y };
        if (i > 0) {
            const a = std.math.pow(f32, life, 1.6);
            // V 字の 2 本の波(にじみ + 芯 + 白いきらめき)
            for ([_][2][2]f32{ .{ pl, l }, .{ pr, r } }) |seg| {
                cv.line(seg[0][0], seg[0][1], seg[1][0], seg[1][1], 3 + 6 * life, acc.alpha(0.14 * a));
                cv.line(seg[0][0], seg[0][1], seg[1][0], seg[1][1], 1 + 1.8 * life, acc.lighten(0.35).alpha(0.7 * a));
                cv.line(seg[0][0], seg[0][1], seg[1][0], seg[1][1], 0.7, white.alpha(0.45 * a));
            }
            // 通ったばかりの所の泡
            if (age < 0.45) {
                const fa = (0.45 - age) / 0.45;
                cv.line(pc[0], pc[1], cpt[0], cpt[1], 1 + 4 * fa, white.alpha(0.35 * fa * fa));
            }
        }
        // 間を横切る弧の波(3 点おき): 左 → 少し後ろに膨らんだ中央 → 右
        if (i % 3 == 0 and age > 0.08) {
            const a = std.math.pow(f32, life, 2) * 0.32;
            const mid = [2]f32{ pt.x - tx * hw * 0.32, pt.y - ty * hw * 0.32 };
            cv.line(l[0], l[1], mid[0], mid[1], 1.1, acc.lighten(0.3).alpha(a));
            cv.line(mid[0], mid[1], r[0], r[1], 1.1, acc.lighten(0.3).alpha(a));
        }
        pl = l;
        pr = r;
        pc = cpt;
    }
    return true;
}

fn drawMenu(app: *App, cv: *gfx.Canvas, now: u64) bool {
    const t = st.menu_s.x;
    if (t < 0.01) return false;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const cx = st.menu_c[0];
    const cy = st.menu_c[1];
    // 後ろを暗くして、窓の文字の上でも読めるように(項目の輪とワークスペースの列を覆う)
    const back_r = (MENU_R + ITEM_R + 34) * t;
    cv.shadow(cx - back_r, cy - back_r, back_r * 2, back_r * 2, back_r, 40, Color.hex(0x000000).alpha(0.35 * t));
    cv.rect(cx - back_r, cy - back_r, back_r * 2, back_r * 2, back_r, Color.hex(0x08101e).alpha(0.62 * t));
    const ws_w = 9 * WS_GAP + 16;
    cv.rect(cx - ws_w / 2, cy + MENU_R + ITEM_R + 52 - 24, ws_w, 48, 24, Color.hex(0x08101e).alpha(0.62 * t));
    // 真ん中の円(手の中心)と、開いていく輪
    cv.glass(cx - 46 * t, cy - 46 * t, 92 * t, 92 * t, 46 * t, theme.glass(app));
    _ = cv.text(cx, cy + 5, 12, txt.alpha(t), "指して選ぶ", .{ .alignment = .center });
    cv.arc(cx, cy, MENU_R * t, 1, 1, acc.alpha(0.25 * t), .{ .a = 0 });
    for (items, 0..) |it, i| {
        // 1 つずつ少し遅れて、中心から飛び出す
        const ti = std.math.clamp(t * 1.3 - @as(f32, @floatFromInt(i)) * 0.04, 0, 1);
        const p0 = itemPos(i);
        const p = [2]f32{ cx + (p0[0] - cx) * ti, cy + (p0[1] - cy) * ti };
        const hv = st.menu_hover == @as(i32, @intCast(i));
        const r = ITEM_R * (if (hv) @as(f32, 1.18) else 1) * ti;
        if (hv) cv.shadow(p[0] - r, p[1] - r, r * 2, r * 2, r, 14, acc.alpha(0.5 * ti));
        cv.glass(p[0] - r, p[1] - r, r * 2, r * 2, r, theme.glass(app));
        cv.rect(p[0] - r, p[1] - r, r * 2, r * 2, r, if (hv) acc.alpha(0.45) else Color.hex(0x0b1730).alpha(0.55 * ti));
        const icol = if (it.it == .close) theme.danger(app).lighten(0.25) else txt;
        _ = cv.text(p[0], p[1] + 7, 20 * ti, icol.alpha(ti), it.icon, .{ .alignment = .center });
        _ = cv.text(p[0], p[1] + r + 15, 11, txt.alpha(ti * (if (hv) @as(f32, 1) else 0.75)), it.label, .{ .alignment = .center, .bold = hv });
        if (hv) {
            const pr = std.math.clamp(@as(f32, @floatFromInt(now -| st.hover_t0)) / DWELL_MS, 0, 1);
            cv.arc(p[0], p[1], r + 5, 3, pr, acc.lighten(0.25), .{ .a = 0 });
        }
    }
    // ワークスペース 1〜9
    const cur_ws: u32 = blk: {
        break :blk @as(u32, 1) << @intCast(curWorkspace(app));
    };
    for (0..9) |i| {
        const p = wsPos(i);
        const hv = st.menu_hover == @as(i32, @intCast(100 + i));
        const on = cur_ws & (@as(u32, 1) << @intCast(i)) != 0;
        const r: f32 = (if (hv) @as(f32, 17) else 14) * t;
        cv.glass(p[0] - r, p[1] - r, r * 2, r * 2, r, theme.glass(app));
        if (on or hv) cv.rect(p[0] - r, p[1] - r, r * 2, r * 2, r, acc.alpha(if (hv) 0.55 else 0.3));
        var nb: [4]u8 = undefined;
        _ = cv.text(p[0], p[1] + 5, 13, txt.alpha(t), std.fmt.bufPrint(&nb, "{d}", .{i + 1}) catch "", .{ .alignment = .center, .bold = on or hv });
        if (hv) {
            const pr = std.math.clamp(@as(f32, @floatFromInt(now -| st.hover_t0)) / DWELL_MS, 0, 1);
            cv.arc(p[0], p[1], r + 4, 2.5, pr, acc.lighten(0.25), .{ .a = 0 });
        }
    }
    return true;
}

fn draw(_: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
    const app = st.app orelse return false;
    var animating = false;
    var sp = [_]*Spring{ &st.shown, &st.press, &st.menu_s };
    if (anim.stepAll(&sp, dt)) animating = true;
    const now = loop.nowMs();
    const acc = theme.accent(app);
    const w: f32 = @floatFromInt(s.width);
    const h: f32 = @floatFromInt(s.height);

    if (drawWake(cv, acc, now)) animating = true;

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
        inline for (.{ 0.0, 0.13, 0.26 }) |delay| {
            const t = std.math.clamp((age - delay) / (1 - delay * 0.6), 0, 1);
            if (t > 0 and t < 1) {
                const e = 1 - (1 - t) * (1 - t) * (1 - t); // 速く広がって、ゆっくり止まる
                const rad = 6 + e * r.size;
                const a = (1 - t) * (1 - t) * 0.75;
                cv.arc(r.x, r.y, rad, 1.2 + 3.2 * (1 - t), 1, r.col.alpha(a), .{ .a = 0 });
                cv.arc(r.x, r.y, rad - 2.5, 0.8, 1, Color.hex(0xffffff).alpha(a * 0.35), .{ .a = 0 });
            }
        }
        const tf = std.math.clamp(age, 0, 1);
        const fill_r = 6 + (1 - (1 - tf) * (1 - tf)) * r.size * 0.8;
        cv.rect(r.x - fill_r, r.y - fill_r, fill_r * 2, fill_r * 2, fill_r, r.col.alpha(0.07 * (1 - tf)));
        k += 1;
    }

    if (drawMenu(app, cv, now)) animating = true;

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
        // 長押しの進み具合(閉じる・メニュー)
        if (st.hold != .none and !st.hold_done and !st.menu) {
            const need: f32 = if (st.hold == .fist) HOLD_FIST_MS else HOLD_MENU_MS;
            const p = std.math.clamp(@as(f32, @floatFromInt(now -| st.hold_t0)) / need, 0, 1);
            if (p > 0.15) {
                const col = if (st.hold == .fist) theme.danger(app) else acc;
                cv.arc(x, y, 27, 3.5, (p - 0.15) / 0.85, col.alpha(a), Color.hex(0xffffff).alpha(0.12 * a));
                _ = cv.text(x, y + 48, 11.5, Color.hex(0xffffff).alpha(0.85 * a), if (st.hold == .fist) "閉じる" else "メニュー", .{ .alignment = .center, .bold = true });
            }
            animating = true;
        }
        // 指の本数: 輪が満ちたらそのワークスペースへ。輪の中に大きく番号
        if (st.num != 0 and !st.num_done) {
            const p = std.math.clamp(@as(f32, @floatFromInt(now -| st.num_t0)) / HOLD_NUM_MS, 0, 1);
            if (p > 0.1) {
                cv.glass(x + 26, y - 62, 52, 52, 26, theme.glass(app));
                cv.arc(x + 52, y - 36, 24, 3.2, (p - 0.1) / 0.9, acc.lighten(0.2).alpha(a), Color.hex(0xffffff).alpha(0.12 * a));
                var nb: [4]u8 = undefined;
                _ = cv.text(x + 52, y - 27, 24, Color.hex(0xffffff).alpha(0.95 * a), std.fmt.bufPrint(&nb, "{d}", .{st.num}) catch "", .{ .alignment = .center, .bold = true });
            }
            animating = true;
        }
        // ポーズの割り当て: 輪が満ちたら動く。下に何が動くか
        if (st.pose_bind) |b| if (!st.pose_done) {
            const p = std.math.clamp(@as(f32, @floatFromInt(now -| st.pose_t0)) / POSE_MS, 0, 1);
            if (p > 0.12) {
                cv.arc(x, y, 30, 3.5, (p - 0.12) / 0.88, Color.hex(0x9be37a).alpha(a), Color.hex(0xffffff).alpha(0.12 * a));
                var db: [160]u8 = undefined;
                const label = poses.describe(app, b, &db);
                const tw = cv.measure(label, 12, true) + 24;
                cv.glass(x - tw / 2, y + 40, tw, 26, 13, theme.glass(app));
                _ = cv.text(x, y + 58, 12, Color.hex(0xffffff).alpha(0.92 * a), label, .{ .alignment = .center, .bold = true });
            }
            animating = true;
        };
        // 両手: もう一方の手が見えている印
        if (st.ext2 != poses.NONE) _ = cv.text(x + 24, y - 20, 12, acc.lighten(0.3).alpha(0.9 * a), "\u{F1821}\u{F1821}", .{ .bold = true });
        if (st.dragging and st.app_drag) {
            _ = cv.text(x, y + 36, 11, Color.hex(0xffffff).alpha(0.85 * a), "ドラッグ(離すと落とす)", .{ .alignment = .center });
        } else if (st.dragging) {
            const scale = st.size / @max(st.drag_size0, 0.01);
            var lb: [32]u8 = undefined;
            const label = if (@abs(scale - 1) >= 0.07) (std.fmt.bufPrint(&lb, "移動・ズーム {d:.0}%", .{std.math.clamp(1 + (scale - 1) * 1.4, 0.45, 2.4) * 100}) catch "移動") else "移動(近づける・遠ざけるとズーム)";
            _ = cv.text(x, y + 36, 11, Color.hex(0xffffff).alpha(0.85 * a), label, .{ .alignment = .center });
        }
    }

    // 大きな表示(ワークスペースを移った・メニューで選んだ): ふわっと出て、上へ消える
    if (st.banner_len > 0) {
        const bt = @as(f32, @floatFromInt(now -| st.banner_t0)) / 1300;
        if (bt < 1) {
            const fade = if (bt < 0.15) bt / 0.15 else 1 - std.math.clamp((bt - 0.6) / 0.4, 0, 1);
            const yy = h * 0.22 - bt * 18;
            const tw = @min(w - 40, 340);
            cv.glass(w / 2 - tw / 2, yy - 30, tw, 60, 30, theme.glass(app));
            _ = cv.text(w / 2, yy + 10, 26, Color.hex(0xffffff).alpha(fade), st.banner[0..st.banner_len], .{ .alignment = .center, .bold = true, .max_w = tw - 30 });
            animating = true;
        } else st.banner_len = 0;
    }

    // 状態の表示(画面の下の中央、数秒で消える)
    if (st.msg_len > 0 and now < st.msg_until) {
        const fade = std.math.clamp(@as(f32, @floatFromInt(st.msg_until - now)) / 400, 0, 1);
        const tw = @min(w - 40, 620);
        cv.glass(w / 2 - tw / 2, h - 96, tw, 40, 20, theme.glass(app));
        _ = cv.text(w / 2, h - 70, 13, theme.text(app).alpha(fade), st.msg[0..st.msg_len], .{ .alignment = .center, .max_w = tw - 24 });
        animating = true;
    }
    return animating;
}

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
    // 推論のメモリは全部この worker 専用の領域から取り、終わるときに丸ごと OS に返す。
    // c_allocator(musl の malloc)だと、細かいテンソルの領域がオフにしたあともヒープに残っていた
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // モデルのファイル(7MB)は読み終えたらすぐ返したいので、別に mmap で取る
    const fa = std.heap.page_allocator;
    const bytes = loadModel(fa) orelse return;
    var det_b: []const u8 = undefined;
    var lmk_b: []const u8 = undefined;
    if (!zip.unzipStored(bytes, "hand_detector.tflite", &det_b) or !zip.unzipStored(bytes, "hand_landmarks_detector.tflite", &lmk_b)) {
        fa.free(bytes);
        log.err("モデルの中身が読めません", .{});
        sendStatus(.failed);
        return;
    }
    sendStatus(.loading);
    var det = nn.Net.init(a, det_b, 2) catch |e| {
        fa.free(bytes);
        log.err("手のひらの検出モデルを読めません: {}", .{e});
        sendStatus(.failed);
        return;
    };
    defer det.deinit();
    var lmk = nn.Net.init(a, lmk_b, 2) catch |e| {
        fa.free(bytes);
        log.err("関節のモデルを読めません: {}", .{e});
        sendStatus(.failed);
        return;
    };
    defer lmk.deinit();
    fa.free(bytes); // 重みは f32 に変換済み。ファイルの中身はもう要らない
    // 両手まで追う(もう一方の手は、ポーズの組み合わせに使う)
    var mt = track.MultiTracker.init(&det, &lmk);
    mt.det_signed = false;

    var cam = openCamera() orelse {
        sendStatus(.no_camera);
        return;
    };
    defer cam.close();
    const rgb = a.alloc(u8, cam.w * cam.h * 3) catch return;
    defer a.free(rgb);
    sendStatus(.running);
    log.info("ハンド操作: カメラ {d}x{d}", .{ cam.w, cam.h });

    var ans = [_]gesture.Analyzer{ .{}, .{} };
    var had = [_]bool{ false, false };
    // カーソルを動かす手(先に見つかった方。消えたらもう一方)
    var primary: usize = 0;
    var lut: [256]u8 = undefined;
    var last_run: i64 = 0;
    var logged_dark = false;
    while (!st.quit.load(.acquire)) {
        var pfd = [_]std.posix.pollfd{.{ .fd = cam.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 150) catch break;
        // 手を追っている間は 1 秒に 30 回まで、見つかっていない間は検出を 1 秒に 4 回まで(軽くするため)
        const now = std.time.milliTimestamp();
        const gap: i64 = if (mt.count() == 0) 250 else 30;
        if (now - last_run < gap) {
            _ = cam.grab(null, true); // 処理しないコマは変換せずに捨てる
            continue;
        }
        if (!cam.grab(rgb, true)) continue;
        last_run = now;
        // 暗い映像は持ち上げる(手の認識は暗いと精度が大きく落ちる)
        var sum: u64 = 0;
        var cnt: u64 = 0;
        var i: usize = 0;
        while (i < rgb.len) : (i += 3 * 37) {
            sum += rgb[i] + @as(u64, rgb[i + 1]) * 2 + rgb[i + 2];
            cnt += 4;
        }
        const mean = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(@max(cnt, 1)));
        if (gesture.brightLut(mean, &lut)) {
            for (rgb) |*px| px.* = lut[px.*];
            if (!logged_dark and mean < 40) {
                log.warn("カメラの映像がとても暗い(平均 {d:.0}/255)。カメラのシャッターや部屋の明るさを確かめてください", .{mean});
                logged_dark = true;
            }
        }
        const img = track.Image{ .rgb = rgb, .w = cam.w, .h = cam.h };
        var hands: [track.MAX_HANDS]?track.Hand = .{ null, null };
        mt.step(img, &hands) catch {};
        const t = @as(f32, @floatFromInt(now)) / 1000;
        var feats: [2]?gesture.Features = .{ null, null };
        for (0..2) |k| {
            if (hands[k]) |hd| {
                if (!had[k]) ans[k].reset();
                had[k] = true;
                feats[k] = ans[k].step(hd.pts, @floatFromInt(cam.w), @floatFromInt(cam.h), t);
            } else had[k] = false;
        }
        if (feats[primary] == null and feats[1 - primary] != null) primary = 1 - primary;
        if (feats[primary]) |f| {
            const o = feats[1 - primary];
            send(.{
                .kind = 0,
                .has = 1,
                .gesture = @intFromEnum(f.gesture),
                .fingers = f.fingers,
                .cx = f.cx,
                .cy = f.cy,
                .px = f.px,
                .py = f.py,
                .pinch = f.pinch,
                .size = f.size,
                .pinch_mid = f.pinch_mid,
                .pinch_ring = f.pinch_ring,
                .ext = f.ext,
                .has2 = @intFromBool(o != null),
                .ext2 = if (o) |of| of.ext else 0,
                .shape = custom.normalize(hands[primary].?.pts, hands[primary].?.right),
                .shape2 = if (hands[1 - primary]) |h2| custom.normalize(h2.pts, h2.right) else [_]f32{0} ** custom.DIM,
            });
        } else send(.{ .kind = 0, .has = 0 });
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

/// 試験用(ame-ctl debug-hand): カメラ無しで 1 コマ分の手を与える。
/// "<形> [本数] <x> <y> [大きさ]"(x, y は画面の 0〜1。number のときだけ本数。大きさは手の大きさ ÷ 画像の幅、既定 0.2)
pub fn debugInject(app: *App, args: []const u8) void {
    if (!st.on or st.surf == null) return;
    st.debug_until = loop.nowMs() + 2500;
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const g = std.meta.stringToEnum(Gesture, it.next() orelse "none") orelse .none;
    const fingers: u8 = if (g == .number) std.fmt.parseInt(u8, it.next() orelse "1", 10) catch 1 else 0;
    const x = std.fmt.parseFloat(f32, it.next() orelse "0.5") catch 0.5;
    const y = std.fmt.parseFloat(f32, it.next() orelse "0.5") catch 0.5;
    const size = std.fmt.parseFloat(f32, it.next() orelse "0.2") catch 0.2;
    if (g == .none) {
        st.last_seen = loop.nowMs() -| 1000;
        frame(app, .{ .kind = 0, .has = 0 });
        return;
    }
    var m = Msg{ .kind = 0, .has = 1, .gesture = @intFromEnum(g), .fingers = fingers, .cx = x, .cy = y, .px = x, .py = y, .pinch = if (g == .pinch) 0.15 else 1.0, .size = size };
    // 残り: ext=<指> ext2=<指>(もう一方の手)mid=<親指と中指> ring=<親指と薬指>(poses.zig の指の文字。0 = 握りこぶし)
    m.ext = switch (g) {
        .point => poses.POINT,
        .open => 31,
        .fist => 0,
        .number => switch (fingers) {
            1 => poses.THUMB,
            2 => poses.INDEX | poses.MIDDLE,
            3 => poses.INDEX | poses.MIDDLE | poses.RING,
            else => poses.INDEX | poses.MIDDLE | poses.RING | poses.PINKY,
        },
        else => poses.POINT,
    };
    while (it.next()) |kv| {
        const eqi = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eqi];
        const v = kv[eqi + 1 ..];
        if (std.mem.eql(u8, k, "ext")) {
            if (poses.strToMask(v)) |e| m.ext = e;
        } else if (std.mem.eql(u8, k, "ext2")) {
            if (poses.strToMask(v)) |e| {
                m.has2 = 1;
                m.ext2 = e;
            }
        } else if (std.mem.eql(u8, k, "mid")) {
            m.pinch_mid = std.fmt.parseFloat(f32, v) catch 9;
        } else if (std.mem.eql(u8, k, "ring")) {
            m.pinch_ring = std.fmt.parseFloat(f32, v) catch 9;
        }
    }
    frame(app, m);
}

// ---- 窓の操作: River 0.5(ame-shell が WM を兼ねる)は内蔵 WM へ、River 0.3/0.4 は river-control(riverctl と同じ命令)へ ----

const WinOp = enum { close, fullscreen, float };

fn winOp(app: *App, op: WinOp) void {
    if (app.wm) |w| return w.push(switch (op) {
        .close => .close,
        .fullscreen => .fullscreen,
        .float => .float,
    });
    app.riverCommand(&.{switch (op) {
        .close => "close",
        .fullscreen => "toggle-fullscreen",
        .float => "toggle-float",
    }});
}

/// 窓を大きく・小さく。旧 River の resize は浮いた窓にだけ効くので、タイルの窓はまず浮かせる
fn winScale(app: *App, f: f32) void {
    if (app.wm) |w| return w.push(.{ .hand_scale = f });
    const dx: [:0]const u8 = if (f > 1) "160" else "-160";
    const dy: [:0]const u8 = if (f > 1) "100" else "-100";
    app.riverCommand(&.{ "resize", "horizontal", dx });
    app.riverCommand(&.{ "resize", "vertical", dy });
}

/// 今のワークスペース(1 つ目のタグ、0 始まり)
fn curWorkspace(app: *App) u32 {
    const tags: u32 = blk: {
        if (app.wm) |w| if (w.focusedOutput()) |o| break :blk o.tags;
        if (st.out) |o| break :blk o.focused_tags;
        if (app.activeOutput()) |o| break :blk o.focused_tags;
        break :blk 1;
    };
    const low = tags & 0x1ff;
    return if (low == 0) 0 else @ctz(low);
}

/// 払う動きで隣のワークスペースへ。移った先(1 始まり)、端なら null(AirPods の頭の動きでも使う)
pub fn stepWorkspace(app: *App, dir: i32) ?u8 {
    if (app.wm) |w| return w.handWorkspace(dir);
    const cur: i32 = @intCast(curWorkspace(app));
    const next = std.math.clamp(cur + dir, 0, 8);
    if (next == cur) return null;
    app.focusTags(@as(u32, 1) << @intCast(next));
    return @intCast(next + 1);
}

/// つかんで動かす: 内蔵 WM は窓そのものを動かす。旧 River は左ボタンを押したままカーソルを動かす
/// (アプリの中でのドラッグ: 文字の選択・ファイルのドラッグ・タイトルバーを持って動かす など)
fn grabStart(app: *App) bool {
    if (app.wm) |w| {
        w.push(.hand_grab);
        return true;
    }
    const vp = st.vptr orelse return false;
    c.zwlr_virtual_pointer_v1_button(vp, @truncate(loop.nowMs()), 0x110, 1);
    c.zwlr_virtual_pointer_v1_frame(vp);
    st.vbutton = true;
    return true;
}

/// 今の手のポーズ(ポーズの設定画面の「今の手を使う」)。手が見えていなければ null。[手 1, 手 2 か NONE]
pub fn currentPose() ?[2]u8 {
    if (!st.on or !st.visible) return null;
    return .{ st.ext, st.ext2 };
}

/// 最新の手の形(自分のポーズの登録で撮る)。seq は届くたびに増える。手が見えていなければ null
pub fn latestShape() ?struct { seq: u32, shape: custom.Shape } {
    if (!st.on or !st.visible) return null;
    return .{ .seq = st.shape_seq, .shape = st.shape };
}
