// スクリーンショット(grim / slurp / wl-copy の代わりを自前で)。キー(WM の Print)・サイドバーのボタン・ame-ctl screenshot から。
//
//   撮影   … ext-image-copy-capture(wlroots 0.19 以降の River 0.4 / 0.5)で出力の画面を wl_shm に写す
//   範囲   … 撮った画面を止めたまま全面のオーバーレイに出し、ドラッグで範囲を選ぶ(slurp の代わり)。
//             暗幕のフェード・選択枠のスプリング・確定時のフラッシュ
//   保存   … PNG は自前のエンコーダ(行ごとにフィルタを選び、std の zlib で圧縮)。ワーカースレッドで
//   コピー … ext-data-control で ame-shell 自身がクリップボードの持ち主になる(wl-copy の代わり)
//
// コンポジタが ext-image-copy-capture を持たないとき(River 0.3 など)だけ、従来どおり grim / slurp / wl-copy を使う。
// 保存先は ~/Pictures/Screenshots(無ければ作る)。保存したものはクリップボードにも入れる。
const std = @import("std");
const c = @import("../c.zig");
const sys = @import("../platform/sys.zig");
const loop = @import("../platform/loop.zig");
const deps = @import("../core/deps.zig");
const anim = @import("../gfx/anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("../gfx/gfx.zig");
const theme = @import("../gfx/theme.zig");
const appmod = @import("../core/app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("../core/surface.zig");
const Surface = surface.Surface;

const log = std.log.scoped(.shot);
const ca = std.heap.c_allocator;

pub const Kind = enum {
    /// 範囲を選んで保存 + コピー
    region,
    /// 画面全体を保存 + コピー
    full,
    /// 画面全体をコピーだけ
    clip,

    pub fn parse(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }
};

// wl_shm の形式(リトルエンディアン)
const FMT_ARGB8888: u32 = 0;
const FMT_XRGB8888: u32 = 1;
const FMT_ABGR8888: u32 = 0x34324241;
const FMT_XBGR8888: u32 = 0x34324258;

const State = enum { idle, waiting, capturing, selecting, encoding };

const Shot = struct {
    app: *App,
    state: State = .idle,
    kind: Kind = .full,
    out: ?*Output = null,
    delay: loop.Timer,

    // 撮影
    source: ?*c.struct_ext_image_capture_source_v1 = null,
    session: ?*c.struct_ext_image_copy_capture_session_v1 = null,
    frame: ?*c.struct_ext_image_copy_capture_frame_v1 = null,
    buffer: ?*c.struct_wl_buffer = null,
    map: ?[]align(std.mem.page_size) u8 = null,
    buf_w: u32 = 0,
    buf_h: u32 = 0,
    format: ?u32 = null,

    /// 撮った画面(RGBA、上の行から)
    px: ?[]u8 = null,
    px_w: u32 = 0,
    px_h: u32 = 0,

    // 範囲選択のオーバーレイ
    surf: ?*Surface = null,
    tex: c.GLuint = 0,
    show: Spring = Spring.init(0, 0.22, 1.0),
    flash: Spring = Spring.init(0, 0.12, 1.0),
    sel: [4]Spring = .{ Spring.init(0, 0.07, 1.0), Spring.init(0, 0.07, 1.0), Spring.init(0, 0.07, 1.0), Spring.init(0, 0.07, 1.0) },
    dragging: bool = false,
    has_sel: bool = false,
    a: [2]f32 = .{ 0, 0 },
    b: [2]f32 = .{ 0, 0 },
    ptr: [2]f32 = .{ -1, -1 },
    closing: bool = false,

    // エンコード(ワーカー)
    pipe: [2]c_int = .{ -1, -1 },
    job: ?*Job = null,

    // クリップボード
    dc_dev: ?*c.struct_ext_data_control_device_v1 = null,
};

const Job = struct {
    rgba: []u8,
    w: u32,
    h: u32,
    save: bool,
    path: [512]u8 = undefined,
    path_len: usize = 0,
    png: ?[]u8 = null,
    err: ?anyerror = null,
};

var g: ?*Shot = null;

fn get(app: *App) ?*Shot {
    if (g) |s| return s;
    const s = app.alloc.create(Shot) catch return null;
    s.* = .{ .app = app, .delay = loop.Timer.init() catch {
        app.alloc.destroy(s);
        return null;
    } };
    app.loop.add(s.delay.fd, c.EPOLLIN, s, onDelay) catch {};
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) == 0) {
        s.pipe = fds;
        app.loop.add(fds[0], c.EPOLLIN, s, onJobDone) catch {};
    }
    g = s;
    return s;
}

/// コンポジタが自前の撮影に必要なものを持っているか
fn native(app: *App) bool {
    return app.shm != null and app.icc_mgr != null and app.ics_mgr != null;
}

/// delay_ms: パネルを閉じるアニメーションが写らないよう少し待つ(0 なら待たない)
pub fn take(app: *App, kind: Kind, delay_ms: u32) void {
    if (!native(app)) return takeExternal(app, kind, delay_ms);
    const s = get(app) orelse return;
    if (s.state != .idle) return; // 撮影中・選択中の二重起動はしない
    s.kind = kind;
    s.out = app.activeOutput() orelse return;
    if (delay_ms > 0) {
        s.state = .waiting;
        s.delay.arm(delay_ms, 0);
    } else startCapture(s);
}

fn onDelay(ctx: *anyopaque, _: c_int, _: u32) void {
    const s: *Shot = @ptrCast(@alignCast(ctx));
    s.delay.ack();
    if (s.state == .waiting) startCapture(s);
}

// ---------------------------------------------------------------------------
// 撮影(ext-image-copy-capture)
// ---------------------------------------------------------------------------

fn startCapture(s: *Shot) void {
    const app = s.app;
    const out = s.out orelse return fail(s, "出力がありません");
    s.state = .capturing;
    s.format = null;
    s.buf_w = 0;
    s.buf_h = 0;
    s.source = c.ext_output_image_capture_source_manager_v1_create_source(app.ics_mgr, out.wl);
    // options = 0: カーソルは写さない(grim と同じ)
    s.session = c.ext_image_copy_capture_manager_v1_create_session(app.icc_mgr, s.source, 0);
    if (s.session == null) return fail(s, "撮影を始められません");
    _ = c.ext_image_copy_capture_session_v1_add_listener(s.session, &session_listener, s);
}

fn sBufferSize(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.C) void {
    const s: *Shot = @ptrCast(@alignCast(data.?));
    s.buf_w = w;
    s.buf_h = h;
}
fn sShmFormat(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, fmt: u32) callconv(.C) void {
    const s: *Shot = @ptrCast(@alignCast(data.?));
    switch (fmt) {
        // XRGB / ARGB を優先(どのコンポジタも持つ)。BGR 系は無いときだけ
        FMT_XRGB8888, FMT_ARGB8888 => if (s.format == null or (s.format.? != FMT_XRGB8888 and s.format.? != FMT_ARGB8888)) {
            s.format = fmt;
        },
        FMT_XBGR8888, FMT_ABGR8888 => if (s.format == null) {
            s.format = fmt;
        },
        else => {},
    }
}
fn sDmabufDevice(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: ?*c.struct_wl_array) callconv(.C) void {}
fn sDmabufFormat(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: u32, _: ?*c.struct_wl_array) callconv(.C) void {}
fn sDone(data: ?*anyopaque, sess: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.C) void {
    const s: *Shot = @ptrCast(@alignCast(data.?));
    if (s.frame != null or s.state != .capturing) return; // 撮影中に条件が変わっても、今の 1 枚で済ませる
    const fmt = s.format orelse return fail(s, "対応する画素の形式がありません");
    if (s.buf_w == 0 or s.buf_h == 0) return fail(s, "画面の大きさが分かりません");
    const stride = s.buf_w * 4;
    const size: usize = @as(usize, stride) * s.buf_h;
    const fd: c_int = c.memfd_create("ame-shot", c.MFD_CLOEXEC);
    if (fd < 0) return fail(s, "メモリを確保できません");
    defer std.posix.close(fd);
    std.posix.ftruncate(fd, size) catch return fail(s, "メモリを確保できません");
    s.map = std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0) catch return fail(s, "メモリを確保できません");
    const pool = c.wl_shm_create_pool(s.app.shm, fd, @intCast(size));
    s.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(s.buf_w), @intCast(s.buf_h), @intCast(stride), fmt);
    c.wl_shm_pool_destroy(pool);
    s.frame = c.ext_image_copy_capture_session_v1_create_frame(sess);
    _ = c.ext_image_copy_capture_frame_v1_add_listener(s.frame, &frame_listener, s);
    c.ext_image_copy_capture_frame_v1_attach_buffer(s.frame, s.buffer);
    c.ext_image_copy_capture_frame_v1_damage_buffer(s.frame, 0, 0, @intCast(s.buf_w), @intCast(s.buf_h));
    c.ext_image_copy_capture_frame_v1_capture(s.frame);
}
fn sStopped(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.C) void {
    const s: *Shot = @ptrCast(@alignCast(data.?));
    if (s.state == .capturing) fail(s, "撮影が止められました");
}
const session_listener = c.struct_ext_image_copy_capture_session_v1_listener{
    .buffer_size = sBufferSize,
    .shm_format = sShmFormat,
    .dmabuf_device = sDmabufDevice,
    .dmabuf_format = sDmabufFormat,
    .done = sDone,
    .stopped = sStopped,
};

fn fTransform(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: u32) callconv(.C) void {}
fn fDamage(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: i32, _: i32, _: i32, _: i32) callconv(.C) void {}
fn fTime(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: u32, _: u32, _: u32) callconv(.C) void {}
fn fReady(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1) callconv(.C) void {
    const s: *Shot = @ptrCast(@alignCast(data.?));
    const map = s.map orelse return fail(s, "撮影に失敗しました");
    const n: usize = @as(usize, s.buf_w) * s.buf_h;
    const px = ca.alloc(u8, n * 4) catch return fail(s, "メモリを確保できません");
    const bgr = s.format.? == FMT_XRGB8888 or s.format.? == FMT_ARGB8888;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = map[i * 4 ..][0..4];
        const q = px[i * 4 ..][0..4];
        if (bgr) {
            q.* = .{ p[2], p[1], p[0], 255 };
        } else {
            q.* = .{ p[0], p[1], p[2], 255 };
        }
    }
    s.px = px;
    s.px_w = s.buf_w;
    s.px_h = s.buf_h;
    releaseCapture(s);
    switch (s.kind) {
        .region => openOverlay(s),
        .full, .clip => startEncode(s, 0, 0, s.px_w, s.px_h),
    }
}
fn fFailed(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, reason: u32) callconv(.C) void {
    const s: *Shot = @ptrCast(@alignCast(data.?));
    log.warn("capture failed: reason={d}", .{reason});
    fail(s, "撮影に失敗しました");
}
const frame_listener = c.struct_ext_image_copy_capture_frame_v1_listener{
    .transform = fTransform,
    .damage = fDamage,
    .presentation_time = fTime,
    .ready = fReady,
    .failed = fFailed,
};

fn releaseCapture(s: *Shot) void {
    if (s.frame) |f| c.ext_image_copy_capture_frame_v1_destroy(f);
    if (s.session) |x| c.ext_image_copy_capture_session_v1_destroy(x);
    if (s.source) |x| c.ext_image_capture_source_v1_destroy(x);
    if (s.buffer) |b| c.wl_buffer_destroy(b);
    if (s.map) |m| std.posix.munmap(m);
    s.frame = null;
    s.session = null;
    s.source = null;
    s.buffer = null;
    s.map = null;
}

fn freePixels(s: *Shot) void {
    if (s.px) |p| ca.free(p);
    s.px = null;
}

fn fail(s: *Shot, msg: []const u8) void {
    log.warn("{s}", .{msg});
    releaseCapture(s);
    freePixels(s);
    s.state = .idle;
    s.app.notifs.post("ame-shell", "スクリーンショットを撮れません", msg, 0);
}

// ---------------------------------------------------------------------------
// 範囲選択(slurp の代わり)。撮った画面を止めて見せ、その上で選ぶ
// ---------------------------------------------------------------------------

fn openOverlay(s: *Shot) void {
    const app = s.app;
    const out = s.out orelse return fail(s, "出力がありません");
    s.state = .selecting;
    s.has_sel = false;
    s.dragging = false;
    s.closing = false;
    s.ptr = .{ -1, -1 };
    s.show.snap(0);
    s.show.set(1);
    s.flash.snap(0);
    s.surf = Surface.createLayer(app, .{ .ctx = s, .draw = draw, .pointer = onPointer, .key = onKey }, .{
        .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        .anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        .exclusive = -1,
        .keyboard = c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
        .namespace = "ame-shot",
        .output = out.wl,
    }) catch return fail(s, "選択の画面を出せません");
    s.surf.?.output = out;
    s.surf.?.schedule();
}

fn rectOf(s: *const Shot) [4]f32 {
    const x0 = @min(s.a[0], s.b[0]);
    const y0 = @min(s.a[1], s.b[1]);
    return .{ x0, y0, @abs(s.b[0] - s.a[0]), @abs(s.b[1] - s.a[1]) };
}

fn setSelTarget(s: *Shot, snap: bool) void {
    const r = rectOf(s);
    for (&s.sel, r) |*sp, v| if (snap) sp.snap(v) else sp.set(v);
}

fn onPointer(ctx: *anyopaque, sf: *Surface, ev: surface.PointerEvent) void {
    const s: *Shot = @ptrCast(@alignCast(ctx));
    if (s.closing) return;
    s.ptr = .{ ev.x, ev.y };
    switch (ev.kind) {
        .enter => s.app.setCursor(s.app.ptr_serial, c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR),
        .press => if (ev.button == 0x111) { // 右クリックでやめる
            cancel(s);
            return;
        } else if (ev.button == 0x110) {
            s.dragging = true;
            s.has_sel = true;
            s.a = .{ ev.x, ev.y };
            s.b = s.a;
            setSelTarget(s, true);
        },
        .motion => if (s.dragging) {
            s.b = .{ ev.x, ev.y };
            setSelTarget(s, false);
        },
        .release => if (s.dragging and ev.button == 0x110) {
            s.dragging = false;
            s.b = .{ ev.x, ev.y };
            const r = rectOf(s);
            if (r[2] < 4 or r[3] < 4) {
                s.has_sel = false; // ただのクリックは選び直し
            } else {
                setSelTarget(s, false);
                confirm(s, r);
                return;
            }
        },
        .leave => s.ptr = .{ -1, -1 },
        else => {},
    }
    sf.schedule();
}

fn onKey(ctx: *anyopaque, sf: *Surface, ev: surface.KeyEvent) void {
    const s: *Shot = @ptrCast(@alignCast(ctx));
    if (s.closing) return;
    switch (ev.sym) {
        c.XKB_KEY_Escape => cancel(s),
        // Enter: 画面全体
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
            const w: f32 = @floatFromInt(sf.width);
            const h: f32 = @floatFromInt(sf.height);
            s.a = .{ 0, 0 };
            s.b = .{ w, h };
            s.has_sel = true;
            setSelTarget(s, false);
            confirm(s, .{ 0, 0, w, h });
        },
        else => {},
    }
}

fn cancel(s: *Shot) void {
    s.closing = true;
    s.dragging = false;
    s.show.set(0);
    if (s.surf) |sf| sf.schedule();
}

fn confirm(s: *Shot, r: [4]f32) void {
    const sf = s.surf orelse return;
    s.closing = true;
    s.flash.snap(1);
    s.flash.set(0);
    s.show.set(0);
    // 論理座標 → 撮った画像の画素
    const fx = @as(f32, @floatFromInt(s.px_w)) / @as(f32, @floatFromInt(@max(sf.width, 1)));
    const fy = @as(f32, @floatFromInt(s.px_h)) / @as(f32, @floatFromInt(@max(sf.height, 1)));
    const x0: u32 = @intFromFloat(std.math.clamp(@round(r[0] * fx), 0, @as(f32, @floatFromInt(s.px_w - 1))));
    const y0: u32 = @intFromFloat(std.math.clamp(@round(r[1] * fy), 0, @as(f32, @floatFromInt(s.px_h - 1))));
    const x1: u32 = @intFromFloat(std.math.clamp(@round((r[0] + r[2]) * fx), 0, @as(f32, @floatFromInt(s.px_w))));
    const y1: u32 = @intFromFloat(std.math.clamp(@round((r[1] + r[3]) * fy), 0, @as(f32, @floatFromInt(s.px_h))));
    sf.schedule();
    if (x1 <= x0 or y1 <= y0) return cancel(s);
    startEncode(s, x0, y0, x1 - x0, y1 - y0);
}

fn draw(ctx: *anyopaque, sf: *Surface, cv: *gfx.Canvas, dt: f32) bool {
    const s: *Shot = @ptrCast(@alignCast(ctx));
    const app = s.app;
    var springs = [_]*Spring{ &s.show, &s.flash, &s.sel[0], &s.sel[1], &s.sel[2], &s.sel[3] };
    const moving = anim.stepAll(&springs, dt);
    const W: f32 = @floatFromInt(sf.width);
    const H: f32 = @floatFromInt(sf.height);
    if (s.tex == 0) if (s.px) |p| {
        s.tex = gfx.uploadImage(p.ptr, @intCast(s.px_w), @intCast(s.px_h));
    };
    if (s.closing and !moving and s.show.x < 0.01) {
        app.reap_pending = true;
        return false;
    }
    const t = std.math.clamp(s.show.x, 0, 1);
    // 止めた画面(閉じるときはそのまま薄くなって実際の画面に戻る)
    cv.save();
    cv.opacity(if (s.closing) t else 1);
    if (s.tex != 0) cv.image(s.tex, 0, 0, W, H, 0);
    const dim = Color.hex(0x05060c).alpha(0.5 * t);
    if (s.has_sel) {
        const x = s.sel[0].x;
        const y = s.sel[1].x;
        const w = @max(s.sel[2].x, 0);
        const h = @max(s.sel[3].x, 0);
        // 選んだ所以外を暗く
        cv.rect(0, 0, W, y, 0, dim);
        cv.rect(0, y + h, W, H - y - h, 0, dim);
        cv.rect(0, y, x, h, 0, dim);
        cv.rect(x + w, y, W - x - w, h, 0, dim);
        const acc = theme.accent(app);
        // 中は撮れる画をそのまま見せる(塗らない)。外側にだけ淡い光の縁
        cv.rectBorder(x - 3, y - 3, w + 6, h + 6, 5, Color.hex(0x000000).alpha(0), acc.alpha(0.28 * t), 3);
        cv.rectBorder(x, y, w, h, 2, Color.hex(0x000000).alpha(0), acc.alpha(t), 2);
        // 四隅のつまみ
        const k: f32 = 7;
        for ([_][2]f32{ .{ x, y }, .{ x + w, y }, .{ x, y + h }, .{ x + w, y + h } }) |p| {
            cv.rect(p[0] - k / 2, p[1] - k / 2, k, k, k / 2, Color.hex(0xffffff).alpha(t));
        }
        // 大きさ(画素)
        const fx = @as(f32, @floatFromInt(s.px_w)) / @max(W, 1);
        var buf: [32]u8 = undefined;
        const lbl = std.fmt.bufPrint(&buf, "{d} × {d}", .{ @as(u32, @intFromFloat(@round(w * fx))), @as(u32, @intFromFloat(@round(h * fx))) }) catch "";
        const lw = cv.measure(lbl, 13, true) + 22;
        var ly = y + h + 10;
        if (ly + 28 > H) ly = y - 38;
        if (ly < 0) ly = y + 10;
        const lx = std.math.clamp(x + w / 2 - lw / 2, 6, W - lw - 6);
        cv.glass(lx, ly, lw, 28, 14, theme.glassStrong(app));
        _ = cv.text(lx + lw / 2, ly + 19, 13, theme.text(app), lbl, .{ .bold = true, .alignment = .center });
        // 確定の瞬間のフラッシュ
        if (s.flash.x > 0.01) cv.rect(x, y, w, h, 2, Color.hex(0xffffff).alpha(0.55 * s.flash.x));
    } else {
        cv.rect(0, 0, W, H, 0, dim);
        // 十字の補助線
        if (s.ptr[0] >= 0 and !s.closing) {
            const lc = Color.hex(0xffffff).alpha(0.35 * t);
            cv.line(s.ptr[0], 0, s.ptr[0], H, 1, lc);
            cv.line(0, s.ptr[1], W, s.ptr[1], 1, lc);
        }
        // 案内(上から降りてくる)
        if (!s.closing) {
            const msg = "ドラッグで範囲を選ぶ   Enter 画面全体   Esc やめる";
            const mw = cv.measure(msg, 14, false) + 40;
            const my = 28 - (1 - t) * 24;
            cv.save();
            cv.opacity(t);
            cv.shadow(W / 2 - mw / 2, my + 4, mw, 40, 20, 16, theme.shadow());
            cv.glass(W / 2 - mw / 2, my, mw, 40, 20, theme.glassStrong(app));
            _ = cv.text(W / 2, my + 26, 14, theme.text(app), msg, .{ .alignment = .center });
            cv.restore();
        }
    }
    cv.restore();
    return moving or s.dragging or theme.accentAnimating();
}

/// メインループから(描画中にサーフェスを消さないため)
pub fn reap(app: *App) void {
    _ = app;
    const s = g orelse return;
    if (s.surf == null or !s.closing or s.show.x >= 0.01) return;
    if (s.tex != 0) {
        s.app.gpu.makeCurrent(s.surf.?.egl_surf);
        c.glDeleteTextures(1, &s.tex);
        s.tex = 0;
    }
    s.surf.?.destroy();
    s.surf = null;
    if (s.state == .selecting) {
        // やめた(エンコード中なら、ワーカーが終わってから idle に戻る)
        freePixels(s);
        s.state = .idle;
    }
}

// ---------------------------------------------------------------------------
// PNG(ワーカースレッド)
// ---------------------------------------------------------------------------

fn startEncode(s: *Shot, x0: u32, y0: u32, w: u32, h: u32) void {
    const src = s.px orelse return fail(s, "画像がありません");
    const job = ca.create(Job) catch return fail(s, "メモリを確保できません");
    job.* = .{ .rgba = ca.alloc(u8, @as(usize, w) * h * 4) catch {
        ca.destroy(job);
        return fail(s, "メモリを確保できません");
    }, .w = w, .h = h, .save = s.kind != .clip };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const from = (@as(usize, y0 + y) * s.px_w + x0) * 4;
        @memcpy(job.rgba[@as(usize, y) * w * 4 ..][0 .. @as(usize, w) * 4], src[from..][0 .. @as(usize, w) * 4]);
    }
    // オーバーレイが無ければ(全体・コピーだけ)、元の画素はもう要らない
    if (s.surf == null) freePixels(s);
    if (job.save) {
        const p = shotPath(&job.path) catch |e| {
            ca.free(job.rgba);
            ca.destroy(job);
            return fail(s, if (e == error.NoHome) "HOME がありません" else "保存先 ~/Pictures/Screenshots を作れません");
        };
        job.path_len = p.len;
    }
    s.state = .encoding;
    s.job = job;
    const th = std.Thread.spawn(.{}, worker, .{ job, s.pipe[1] }) catch {
        ca.free(job.rgba);
        ca.destroy(job);
        s.job = null;
        return fail(s, "スレッドを作れません");
    };
    th.detach();
}

fn shotPath(buf: *[512]u8) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    var dir_buf: [480]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/Pictures/Screenshots", .{home});
    try std.fs.cwd().makePath(dir);
    var t: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&t, &tm);
    var n: u32 = 0;
    while (n < 100) : (n += 1) {
        const p = if (n == 0)
            try std.fmt.bufPrint(buf, "{s}/shot_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.png", .{ dir, @as(u32, @intCast(tm.tm_year + 1900)), @as(u32, @intCast(tm.tm_mon + 1)), @as(u32, @intCast(tm.tm_mday)), @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)) })
        else
            try std.fmt.bufPrint(buf, "{s}/shot_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}_{d}.png", .{ dir, @as(u32, @intCast(tm.tm_year + 1900)), @as(u32, @intCast(tm.tm_mon + 1)), @as(u32, @intCast(tm.tm_mday)), @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)), n });
        std.fs.cwd().access(p, .{}) catch return p; // 同じ秒に 2 枚撮っても上書きしない
    }
    return error.Exists;
}

fn worker(job: *Job, wfd: c_int) void {
    var out = std.ArrayList(u8).init(ca);
    if (@import("../gfx/png.zig").encode(out.writer(), job.rgba, job.w, job.h)) {
        job.png = out.toOwnedSlice() catch null;
        if (job.png == null) job.err = error.OutOfMemory;
    } else |e| {
        out.deinit();
        job.err = e;
    }
    if (job.png) |png| if (job.save) {
        const f = std.fs.cwd().createFile(job.path[0..job.path_len], .{ .mode = 0o644 }) catch |e| blk: {
            job.err = e;
            break :blk null;
        };
        if (f) |file| {
            file.writeAll(png) catch |e| {
                job.err = e;
            };
            file.close();
        }
    };
    const one: [1]u8 = .{1};
    _ = std.posix.write(wfd, &one) catch {};
}

fn onJobDone(ctx: *anyopaque, fd: c_int, _: u32) void {
    const s: *Shot = @ptrCast(@alignCast(ctx));
    var b: [16]u8 = undefined;
    _ = std.posix.read(fd, &b) catch {};
    const job = s.job orelse return;
    s.job = null;
    defer {
        ca.free(job.rgba);
        ca.destroy(job);
    }
    // オーバーレイがまだ閉じ途中なら、画素は reap で捨てる
    if (s.surf == null) freePixels(s);
    s.state = if (s.surf != null) .selecting else .idle;
    if (job.err) |e| {
        if (job.png) |p| ca.free(p);
        var mb: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&mb, "保存できませんでした({s})", .{@errorName(e)}) catch "保存できませんでした";
        s.app.notifs.post("ame-shell", "スクリーンショット", msg, 0);
        return;
    }
    const png = job.png orelse return;
    const copied = setClipboard(s, png); // 持ち主が変わるまで png を持つ(失敗したらここで捨てる)
    const path = job.path[0..job.path_len];
    if (job.save) {
        const name = std.fs.path.basename(path);
        s.app.notifs.post("ame-shell", if (copied) "スクリーンショットを保存してコピーしました" else "スクリーンショットを保存しました", name, 0);
    } else {
        s.app.notifs.post("ame-shell", if (copied) "スクリーンショットをコピーしました" else "クリップボードに入れられません", "", 0);
    }
}

// ---------------------------------------------------------------------------
// クリップボード(ext-data-control。wl-copy の代わり)
// ---------------------------------------------------------------------------

const ClipSrc = struct {
    src: *c.struct_ext_data_control_source_v1,
    data: []u8,
};

/// png の持ち主を引き取る。false なら png は解放済み
fn setClipboard(s: *Shot, png: []u8) bool {
    const app = s.app;
    const mgr = app.dc_mgr orelse {
        ca.free(png);
        return false;
    };
    const seat = app.seat orelse {
        ca.free(png);
        return false;
    };
    if (s.dc_dev == null) {
        s.dc_dev = c.ext_data_control_manager_v1_get_data_device(mgr, seat);
        if (s.dc_dev) |d| _ = c.ext_data_control_device_v1_add_listener(d, &device_listener, s);
    }
    const dev = s.dc_dev orelse {
        ca.free(png);
        return false;
    };
    const cs = ca.create(ClipSrc) catch {
        ca.free(png);
        return false;
    };
    const src = c.ext_data_control_manager_v1_create_data_source(mgr) orelse {
        ca.destroy(cs);
        ca.free(png);
        return false;
    };
    cs.* = .{ .src = src, .data = png };
    _ = c.ext_data_control_source_v1_add_listener(src, &source_listener, cs);
    c.ext_data_control_source_v1_offer(src, "image/png");
    c.ext_data_control_device_v1_set_selection(dev, src);
    return true;
}

fn srcSend(data: ?*anyopaque, _: ?*c.struct_ext_data_control_source_v1, _: [*c]const u8, fd: i32) callconv(.C) void {
    const cs: *ClipSrc = @ptrCast(@alignCast(data.?));
    // 受け取る側が遅くても止まらないよう、コピーを別スレッドで書き込む
    const copy = ca.dupe(u8, cs.data) catch {
        std.posix.close(fd);
        return;
    };
    const th = std.Thread.spawn(.{}, sendWorker, .{ fd, copy }) catch {
        ca.free(copy);
        std.posix.close(fd);
        return;
    };
    th.detach();
}

fn sendWorker(fd: c_int, data: []u8) void {
    defer ca.free(data);
    defer std.posix.close(fd);
    // 非ブロックで渡されることがあるので、ブロックに戻してから書く
    const fl = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch 0;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl & ~@as(usize, @intCast(c.O_NONBLOCK))) catch {};
    var off: usize = 0;
    while (off < data.len) {
        const n = std.posix.write(fd, data[off..]) catch return; // 相手が閉じた(EPIPE)など
        if (n == 0) return;
        off += n;
    }
}

fn srcCancelled(data: ?*anyopaque, src: ?*c.struct_ext_data_control_source_v1) callconv(.C) void {
    const cs: *ClipSrc = @ptrCast(@alignCast(data.?));
    c.ext_data_control_source_v1_destroy(src);
    ca.free(cs.data);
    ca.destroy(cs);
}
const source_listener = c.struct_ext_data_control_source_v1_listener{ .send = srcSend, .cancelled = srcCancelled };

fn devOffer(_: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1, _: ?*c.struct_ext_data_control_offer_v1) callconv(.C) void {}
fn devSelection(_: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1, offer: ?*c.struct_ext_data_control_offer_v1) callconv(.C) void {
    // 他のアプリのクリップボードは読まない
    if (offer) |o| c.ext_data_control_offer_v1_destroy(o);
}
fn devFinished(data: ?*anyopaque, dev: ?*c.struct_ext_data_control_device_v1) callconv(.C) void {
    const s: *Shot = @ptrCast(@alignCast(data.?));
    c.ext_data_control_device_v1_destroy(dev);
    s.dc_dev = null;
}
const device_listener = c.struct_ext_data_control_device_v1_listener{
    .data_offer = devOffer,
    .selection = devSelection,
    .finished = devFinished,
    .primary_selection = devSelection,
};

// ---------------------------------------------------------------------------
// 従来の方法(River 0.3 など ext-image-copy-capture の無いコンポジタ)
// ---------------------------------------------------------------------------

fn takeExternal(app: *App, kind: Kind, delay_ms: u32) void {
    const need: []const []const u8 = switch (kind) {
        .region => &.{ "grim", "slurp", "wl-copy" },
        .full, .clip => &.{ "grim", "wl-copy" },
    };
    if (!deps.require(app, "スクリーンショットを撮れません", need)) return;

    var dir_buf: [512]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse return;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/Pictures/Screenshots", .{home}) catch return;
    if (kind != .clip) std.fs.cwd().makePath(dir) catch |e| {
        var b: [640]u8 = undefined;
        const msg = std.fmt.bufPrint(&b, "{s} を作れません({s})", .{ dir, @errorName(e) }) catch "保存先を作れません";
        std.log.warn("screenshot: {s}", .{msg});
        app.notifs.post("ame-shell", "スクリーンショットを撮れません", msg, 0);
        return;
    };

    // 時刻のファイル名はシェルの date で(撮った瞬間の時刻にするため)。保存先は文に埋め込まず "$1" で渡す
    var cmd_buf: [1024]u8 = undefined;
    var delay_buf: [32]u8 = undefined;
    const delay = if (delay_ms > 0) std.fmt.bufPrint(&delay_buf, "sleep {d}.{d:0>3}; ", .{ delay_ms / 1000, delay_ms % 1000 }) catch "" else "";
    const file = "\"$D/shot_$(date +%Y%m%d_%H%M%S).png\"";
    const cmd = switch (kind) {
        .region => std.fmt.bufPrintZ(&cmd_buf, "{s}D=\"$1\"; G=$(slurp) || exit 0; F={s}; grim -g \"$G\" \"$F\" && wl-copy < \"$F\"", .{ delay, file }),
        .full => std.fmt.bufPrintZ(&cmd_buf, "{s}D=\"$1\"; F={s}; grim \"$F\" && wl-copy < \"$F\"", .{ delay, file }),
        .clip => std.fmt.bufPrintZ(&cmd_buf, "{s}grim - | wl-copy", .{delay}),
    } catch return;
    var db: [520]u8 = undefined;
    const dirz = std.fmt.bufPrintZ(&db, "{s}", .{dir}) catch return;
    sys.spawnDetachedArgs(cmd.ptr, &.{dirz.ptr});
}

/// 出力が抜かれた(app.zig): その出力で撮っている/選んでいるならやめる
pub fn outputRemoved(app: *App, o: *Output) void {
    const s = g orelse return;
    if (s.out != o) return;
    s.out = null;
    if (s.surf != null) {
        cancel(s);
        s.show.snap(0); // 抜けた出力にはもうフレームが来ないので、待たずに片付ける
        app.reap_pending = true;
    }
}
