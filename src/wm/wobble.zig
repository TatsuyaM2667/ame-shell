// 浮いた窓をドラッグしたときの「紙・液体のようにぺらっとたわむ」動き。
//
// River の WM は窓の位置と切り抜きしか決められず、窓そのものを変形できない。そこで:
//   1. ドラッグを始めたら、その窓の中身を 1 枚の絵として写す
//      (ext-foreign-toplevel-list の窓と river_window_v1 は同じ identifier を持つ →
//       ext_foreign_toplevel_image_capture_source で、その窓だけを ext-image-copy-capture で撮る)
//   2. 全面のオーバーレイに、その絵を 16×12 の網目にして描く。つかんだ所はカーソルにぴったり付いて行き、
//      遠い所ほど柔らかいばね(臨界減衰)ですーっと遅れて付いてくる。隣の点との長さを保つので、伸びずに紙のように曲がる
//   3. 本物の窓は、オーバーレイが描けている間だけ 1 画素に切り抜いて隠す(wm.zig の render)。
//      離して揺れが収まったら、オーバーレイを片付けて本物を見せる(その間に窓は新しい位置へ移っている)
// 撮影できない(古い River など)ときは何もしない(普通に動く)。
const std = @import("std");
const c = @import("../c.zig");
const gfx = @import("../gfx.zig");
const anim = @import("../anim.zig");
const appmod = @import("../app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("../surface.zig");
const Surface = surface.Surface;

const log = std.log.scoped(.wobble);
const ca = std.heap.c_allocator;

const GX = 16;
const GY = 12;
const N = GX * GY;

const FMT_ARGB8888: u32 = 0;
const FMT_XRGB8888: u32 = 1;
const FMT_ABGR8888: u32 = 0x34324241;
const FMT_XBGR8888: u32 = 0x34324258;

const Handle = struct {
    h: ?*c.struct_ext_foreign_toplevel_handle_v1 = null,
    id: [64]u8 = undefined,
    id_len: usize = 0,
};

const Node = struct { p: [2]f32 = .{ 0, 0 }, v: [2]f32 = .{ 0, 0 }, k: f32 = 0 };

const Phase = enum { idle, capturing, active };

const State = struct {
    app: ?*App = null,
    list: ?*c.struct_ext_foreign_toplevel_list_v1 = null,
    src_mgr: ?*c.struct_ext_foreign_toplevel_image_capture_source_manager_v1 = null,
    handles: [96]Handle = [_]Handle{.{}} ** 96,

    phase: Phase = .idle,
    win: ?*const anyopaque = null,
    // 撮影
    source: ?*c.struct_ext_image_capture_source_v1 = null,
    session: ?*c.struct_ext_image_copy_capture_session_v1 = null,
    frame: ?*c.struct_ext_image_copy_capture_frame_v1 = null,
    buffer: ?*c.struct_wl_buffer = null,
    map: ?[]align(std.mem.page_size) u8 = null,
    buf_w: u32 = 0,
    buf_h: u32 = 0,
    format: ?u32 = null,
    px: ?[]u8 = null,
    tex: c.GLuint = 0,
    // オーバーレイ
    surf: ?*Surface = null,
    out: ?*Output = null,
    ox: f32 = 0,
    oy: f32 = 0,
    drawn: bool = false,
    /// 半透明の窓(Thunar・ghostty・foot)。River の窓の撮影は透明度を持たない形式しか無いので、暗い背景を透明度に戻す
    glassy: bool = false,
    // 形
    rest_w: f32 = 0,
    rest_h: f32 = 0,
    grab: [2]f32 = .{ 0, 0 }, // つかんだ所(窓の中の位置)
    target: [2]f32 = .{ 0, 0 }, // 窓の左上(グローバル)
    nodes: [N]Node = [_]Node{.{}} ** N,
    released: bool = false,
    finished: bool = false,
    // GL
    prog: c.GLuint = 0,
    vao: c.GLuint = 0,
    vbo: c.GLuint = 0,
};
var st: State = .{};

// ---------------------------------------------------------------------------
// 窓の一覧(identifier → handle)
// ---------------------------------------------------------------------------

pub fn bindList(app: *App, list: *c.struct_ext_foreign_toplevel_list_v1) void {
    st.app = app;
    st.list = list;
    _ = c.ext_foreign_toplevel_list_v1_add_listener(list, &list_listener, null);
}

pub fn bindSourceManager(app: *App, mgr: *c.struct_ext_foreign_toplevel_image_capture_source_manager_v1) void {
    st.app = app;
    st.src_mgr = mgr;
}

fn lToplevel(_: ?*anyopaque, _: ?*c.struct_ext_foreign_toplevel_list_v1, h: ?*c.struct_ext_foreign_toplevel_handle_v1) callconv(.C) void {
    const hh = h orelse return;
    for (&st.handles) |*slot| if (slot.h == null) {
        slot.* = .{ .h = hh };
        _ = c.ext_foreign_toplevel_handle_v1_add_listener(hh, &handle_listener, slot);
        return;
    };
    c.ext_foreign_toplevel_handle_v1_destroy(hh); // 一覧がいっぱい(窓が 96 個以上)
}
fn lFinished(_: ?*anyopaque, _: ?*c.struct_ext_foreign_toplevel_list_v1) callconv(.C) void {}
const list_listener = c.struct_ext_foreign_toplevel_list_v1_listener{ .toplevel = lToplevel, .finished = lFinished };

fn hClosed(data: ?*anyopaque, h: ?*c.struct_ext_foreign_toplevel_handle_v1) callconv(.C) void {
    const slot: *Handle = @ptrCast(@alignCast(data.?));
    c.ext_foreign_toplevel_handle_v1_destroy(h);
    slot.* = .{};
}
fn hDone(_: ?*anyopaque, _: ?*c.struct_ext_foreign_toplevel_handle_v1) callconv(.C) void {}
fn hTitle(_: ?*anyopaque, _: ?*c.struct_ext_foreign_toplevel_handle_v1, _: [*c]const u8) callconv(.C) void {}
fn hAppId(_: ?*anyopaque, _: ?*c.struct_ext_foreign_toplevel_handle_v1, _: [*c]const u8) callconv(.C) void {}
fn hIdent(data: ?*anyopaque, _: ?*c.struct_ext_foreign_toplevel_handle_v1, id: [*c]const u8) callconv(.C) void {
    const slot: *Handle = @ptrCast(@alignCast(data.?));
    const s = if (id != null) std.mem.sliceTo(id, 0) else "";
    slot.id_len = @min(s.len, slot.id.len);
    @memcpy(slot.id[0..slot.id_len], s[0..slot.id_len]);
}
const handle_listener = c.struct_ext_foreign_toplevel_handle_v1_listener{ .closed = hClosed, .done = hDone, .title = hTitle, .app_id = hAppId, .identifier = hIdent };

fn findHandle(ident: []const u8) ?*c.struct_ext_foreign_toplevel_handle_v1 {
    if (ident.len == 0) return null;
    for (st.handles) |slot| if (slot.h != null and std.mem.eql(u8, slot.id[0..slot.id_len], ident)) return slot.h;
    return null;
}

// ---------------------------------------------------------------------------
// wm.zig から
// ---------------------------------------------------------------------------

/// ドラッグを始めた。rect = 窓の中身の矩形(グローバル)、ptr = カーソル(グローバル)
pub fn begin(win: *const anyopaque, ident: []const u8, rect: [4]f32, ptr: [2]f32, out: *Output, out_xy: [2]f32, glassy: bool) void {
    const app = st.app orelse return;
    if (st.phase != .idle) return;
    // AME_WOBBLE=0 で使わない
    if (std.posix.getenv("AME_WOBBLE")) |v| if (std.mem.eql(u8, v, "0")) return;
    if (app.shm == null or app.icc_mgr == null) return;
    const mgr = st.src_mgr orelse return;
    const h = findHandle(ident) orelse return;
    if (rect[2] < 40 or rect[3] < 40) return;
    st.win = win;
    st.phase = .capturing;
    st.released = false;
    st.finished = false;
    st.drawn = false;
    st.glassy = glassy;
    st.out = out;
    st.ox = out_xy[0];
    st.oy = out_xy[1];
    st.rest_w = rect[2];
    st.rest_h = rect[3];
    st.target = .{ rect[0], rect[1] };
    st.grab = .{ std.math.clamp(ptr[0] - rect[0], 0, rect[2]), std.math.clamp(ptr[1] - rect[1], 0, rect[3]) };
    // 網目: 置いた所から始め、つかんだ所から遠いほど柔らかいばね
    const diag = @sqrt(rect[2] * rect[2] + rect[3] * rect[3]);
    for (0..GY) |gy| for (0..GX) |gx| {
        const r = rest(gx, gy);
        const d = @sqrt((r[0] - st.grab[0]) * (r[0] - st.grab[0]) + (r[1] - st.grab[1]) * (r[1] - st.grab[1]));
        const t = std.math.clamp(d / (diag * 0.9), 0, 1);
        const e = t * t * (3 - 2 * t);
        st.nodes[gy * GX + gx] = .{ .p = .{ rect[0] + r[0], rect[1] + r[1] }, .v = .{ 0, 0 }, .k = 900 * (1 - e) + 38 * e };
    };
    st.format = null;
    st.buf_w = 0;
    st.buf_h = 0;
    st.source = c.ext_foreign_toplevel_image_capture_source_manager_v1_create_source(mgr, h);
    st.session = c.ext_image_copy_capture_manager_v1_create_session(app.icc_mgr, st.source, 0);
    if (st.session == null) return abort();
    _ = c.ext_image_copy_capture_session_v1_add_listener(st.session, &session_listener, null);
}

/// ドラッグ中: 窓の左上の目標(グローバル)
pub fn moveTo(win: *const anyopaque, x: f32, y: f32) void {
    if (st.win != win or st.phase == .idle) return;
    st.target = .{ x, y };
    if (st.surf) |s| s.schedule();
}

/// 離した: 揺れが収まったら本物の窓を見せる
pub fn release(win: *const anyopaque) void {
    if (st.win != win) return;
    st.released = true;
    if (st.phase == .capturing) return abort(); // まだ撮れていない: やめる
    if (st.surf) |s| s.schedule();
}

/// この窓を隠すべきか(オーバーレイが代わりに描いている間)
pub fn hides(win: *const anyopaque) bool {
    return st.win == win and st.phase == .active and st.drawn and !st.finished;
}

/// 窓が消えた
pub fn forget(win: *const anyopaque) void {
    if (st.win == win) abort();
}

fn rest(gx: usize, gy: usize) [2]f32 {
    return .{ st.rest_w * @as(f32, @floatFromInt(gx)) / (GX - 1), st.rest_h * @as(f32, @floatFromInt(gy)) / (GY - 1) };
}

fn abort() void {
    releaseCapture();
    if (st.px) |p| ca.free(p);
    st.px = null;
    st.finished = true;
    if (st.surf != null) {
        if (st.app) |a| a.reap_pending = true;
    } else {
        st.phase = .idle;
        st.win = null;
    }
}

fn releaseCapture() void {
    if (st.frame) |f| c.ext_image_copy_capture_frame_v1_destroy(f);
    if (st.session) |x| c.ext_image_copy_capture_session_v1_destroy(x);
    if (st.source) |x| c.ext_image_capture_source_v1_destroy(x);
    if (st.buffer) |b| c.wl_buffer_destroy(b);
    if (st.map) |m| std.posix.munmap(m);
    st.frame = null;
    st.session = null;
    st.source = null;
    st.buffer = null;
    st.map = null;
}

// ---------------------------------------------------------------------------
// 窓の撮影(ext-image-copy-capture。shot.zig と同じ流れ)
// ---------------------------------------------------------------------------

fn sBufferSize(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.C) void {
    st.buf_w = w;
    st.buf_h = h;
}
fn sShmFormat(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, fmt: u32) callconv(.C) void {
    // 透明度を持つ形式を優先(半透明の窓も透けたまま): ARGB > ABGR > XRGB > XBGR
    const rank = struct {
        fn f(x: u32) u8 {
            return switch (x) {
                FMT_ARGB8888 => 4,
                FMT_ABGR8888 => 3,
                FMT_XRGB8888 => 2,
                FMT_XBGR8888 => 1,
                else => 0,
            };
        }
    }.f;
    if (rank(fmt) > 0 and (st.format == null or rank(fmt) > rank(st.format.?))) st.format = fmt;
}
fn sDmabufDevice(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: ?*c.struct_wl_array) callconv(.C) void {}
fn sDmabufFormat(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: u32, _: ?*c.struct_wl_array) callconv(.C) void {}
fn sDone(_: ?*anyopaque, sess: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.C) void {
    const app = st.app orelse return;
    if (st.frame != null or st.phase != .capturing) return;
    const fmt = st.format orelse return abort();
    if (st.buf_w == 0 or st.buf_h == 0) return abort();
    const stride = st.buf_w * 4;
    const size: usize = @as(usize, stride) * st.buf_h;
    const fd: c_int = c.memfd_create("ame-wobble", c.MFD_CLOEXEC);
    if (fd < 0) return abort();
    defer std.posix.close(fd);
    std.posix.ftruncate(fd, size) catch return abort();
    st.map = std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0) catch return abort();
    const pool = c.wl_shm_create_pool(app.shm, fd, @intCast(size));
    st.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(st.buf_w), @intCast(st.buf_h), @intCast(stride), fmt);
    c.wl_shm_pool_destroy(pool);
    st.frame = c.ext_image_copy_capture_session_v1_create_frame(sess);
    _ = c.ext_image_copy_capture_frame_v1_add_listener(st.frame, &frame_listener, null);
    c.ext_image_copy_capture_frame_v1_attach_buffer(st.frame, st.buffer);
    c.ext_image_copy_capture_frame_v1_damage_buffer(st.frame, 0, 0, @intCast(st.buf_w), @intCast(st.buf_h));
    c.ext_image_copy_capture_frame_v1_capture(st.frame);
}
fn sStopped(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.C) void {
    if (st.phase == .capturing) abort();
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
fn fReady(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1) callconv(.C) void {
    const app = st.app orelse return;
    const map = st.map orelse return abort();
    const n: usize = @as(usize, st.buf_w) * st.buf_h;
    const px = ca.alloc(u8, n * 4) catch return abort();
    const bgr = st.format.? == FMT_XRGB8888 or st.format.? == FMT_ARGB8888;
    const opaque_ = st.format.? == FMT_XRGB8888 or st.format.? == FMT_XBGR8888;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = map[i * 4 ..][0..4];
        const q = px[i * 4 ..][0..4];
        // 乗算済みアルファのまま(半透明の端末も透けたまま)
        var a: u8 = if (opaque_) 255 else p[3];
        if (opaque_ and st.glassy) {
            // 黒の上に重ねた半透明の背景(66%)の色は暗い → その所は透明度 0.66 に、明るい文字・アイコンは不透明に
            const mx: f32 = @as(f32, @floatFromInt(@max(p[0], @max(p[1], p[2])))) / 255.0;
            const t = std.math.clamp((mx - 0.05) / 0.2, 0, 1);
            a = @intFromFloat(255.0 * (0.66 + 0.34 * t * t * (3 - 2 * t)));
        }
        q.* = if (bgr) .{ p[2], p[1], p[0], a } else .{ p[0], p[1], p[2], a };
    }
    st.px = px;
    releaseCapture();
    if (st.released) return abort(); // 撮れる前に離した
    // 全面のオーバーレイ(入力は透過)
    const out = st.out orelse return abort();
    st.surf = Surface.createLayer(app, .{ .ctx = &st, .draw = draw }, .{
        .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        .anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        .exclusive = -1,
        .namespace = "ame-wobble",
        .output = out.wl,
    }) catch return abort();
    st.surf.?.output = out;
    st.surf.?.setInputRect(0, 0, 0, 0);
    st.surf.?.schedule();
    st.phase = .active;
}
fn fFailed(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: u32) callconv(.C) void {
    abort();
}
const frame_listener = c.struct_ext_image_copy_capture_frame_v1_listener{
    .transform = fTransform,
    .damage = fDamage,
    .presentation_time = fTime,
    .ready = fReady,
    .failed = fFailed,
};

// ---------------------------------------------------------------------------
// ばねと描画
// ---------------------------------------------------------------------------

/// 1 コマ進める。収まったら true
/// 紙らしさ: (1) ばねは臨界減衰(揺れずに、すーっと追いつく)。つかんだ所から遠いほど柔らかく、長く遅れる
///          (2) 隣り合う点の間の長さを保つ(伸びずに、曲がる)。(3) つかんだ点はカーソルにぴったり
fn step(dt_in: f32) bool {
    const dt = @min(dt_in, 1.0 / 20.0);
    var t: f32 = 0;
    const sub: f32 = 1.0 / 240.0;
    const gi = grabIndex();
    while (t < dt) : (t += sub) {
        const h = @min(sub, dt - t);
        var prev: [N][2]f32 = undefined;
        for (0..GY) |gy| for (0..GX) |gx| {
            const i = gy * GX + gx;
            const nd = &st.nodes[i];
            prev[i] = nd.p;
            const r = rest(gx, gy);
            const tx = st.target[0] + r[0];
            const ty = st.target[1] + r[1];
            const damp = 2 * 1.0 * @sqrt(nd.k);
            nd.v[0] += (nd.k * (tx - nd.p[0]) - damp * nd.v[0]) * h;
            nd.v[1] += (nd.k * (ty - nd.p[1]) - damp * nd.v[1]) * h;
            nd.p[0] += nd.v[0] * h;
            nd.p[1] += nd.v[1] * h;
        };
        // つかんだ点はカーソルに固定
        {
            const r = rest(gi % GX, gi / GX);
            st.nodes[gi].p = .{ st.target[0] + r[0], st.target[1] + r[1] };
            st.nodes[gi].v = .{ 0, 0 };
        }
        // 伸びない紙: 隣の点との長さを元に戻す(つかんだ点は動かさない)
        var iter: u32 = 0;
        while (iter < 3) : (iter += 1) {
            for (0..GY) |gy| for (0..GX) |gx| {
                const i = gy * GX + gx;
                if (gx + 1 < GX) keepLength(i, i + 1, st.rest_w / (GX - 1), gi);
                if (gy + 1 < GY) keepLength(i, i + GX, st.rest_h / (GY - 1), gi);
            };
        }
        // 長さを直した分を速さに反映(位置だけ動かすと、次の手順で跳ね返る)
        for (0..N) |i| {
            if (i == gi) continue;
            const nd = &st.nodes[i];
            const moved_x = nd.p[0] - prev[i][0];
            const moved_y = nd.p[1] - prev[i][1];
            nd.v[0] = nd.v[0] * 0.5 + (moved_x / h) * 0.5;
            nd.v[1] = nd.v[1] * 0.5 + (moved_y / h) * 0.5;
        }
    }
    var settled = true;
    for (0..GY) |gy| for (0..GX) |gx| {
        const nd = st.nodes[gy * GX + gx];
        const r = rest(gx, gy);
        if (@abs(nd.p[0] - st.target[0] - r[0]) > 0.4 or @abs(nd.p[1] - st.target[1] - r[1]) > 0.4 or @abs(nd.v[0]) + @abs(nd.v[1]) > 6) settled = false;
    };
    return settled;
}

/// つかんだ所にいちばん近い網目の点
fn grabIndex() usize {
    const gx: usize = @intFromFloat(@round(std.math.clamp(st.grab[0] / @max(st.rest_w, 1), 0, 1) * (GX - 1)));
    const gy: usize = @intFromFloat(@round(std.math.clamp(st.grab[1] / @max(st.rest_h, 1), 0, 1) * (GY - 1)));
    return gy * GX + gx;
}

/// 2 点の間の長さを len に近づける(長すぎるときだけ縮める。縮むのは許す = 紙はたわめる)
fn keepLength(i: usize, j: usize, len: f32, pinned: usize) void {
    const a = &st.nodes[i];
    const b = &st.nodes[j];
    const dx = b.p[0] - a.p[0];
    const dy = b.p[1] - a.p[1];
    const d = @sqrt(dx * dx + dy * dy);
    if (d <= len or d < 0.001) return;
    const diff = (d - len) / d;
    const wa: f32 = if (i == pinned) 0 else 1;
    const wb: f32 = if (j == pinned) 0 else 1;
    const ws = wa + wb;
    if (ws == 0) return;
    a.p[0] += dx * diff * (wa / ws);
    a.p[1] += dy * diff * (wa / ws);
    b.p[0] -= dx * diff * (wb / ws);
    b.p[1] -= dy * diff * (wb / ws);
}

const mesh_vs =
    \\#version 300 es
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec2 a_uv;
    \\layout(location = 2) in float a_shade;
    \\out vec2 v_uv; out float v_shade;
    \\void main(){ v_uv = a_uv; v_shade = a_shade; gl_Position = vec4(a_pos, 0.0, 1.0); }
;
const mesh_fs =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv; in float v_shade; uniform sampler2D u_tex; out vec4 o;
    \\void main(){ vec4 t = texture(u_tex, v_uv); o = vec4(t.rgb * v_shade, t.a); }
;

fn draw(_: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
    const app = st.app orelse return false;
    if (st.finished) {
        app.reap_pending = true;
        return false;
    }
    const settled = step(dt);
    const W: f32 = @floatFromInt(s.width);
    const H: f32 = @floatFromInt(s.height);
    // 影(目標の位置に、ふわっと)
    cv.shadow(st.target[0] - st.ox, st.target[1] - st.oy + 10, st.rest_w, st.rest_h, 12, 34, anim.Color.hex(0x000000).alpha(0.35));
    cv.flush();
    if (st.prog == 0) {
        st.prog = gfx.program(mesh_vs, mesh_fs) catch 0;
        c.glGenVertexArrays(1, &st.vao);
        c.glGenBuffers(1, &st.vbo);
        c.glBindVertexArray(st.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, st.vbo);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(0));
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(8));
        c.glEnableVertexAttribArray(2);
        c.glVertexAttribPointer(2, 1, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(16));
        c.glBindVertexArray(0);
    }
    if (st.tex == 0) if (st.px) |p| {
        st.tex = gfx.uploadImage(p.ptr, @intCast(st.buf_w), @intCast(st.buf_h));
        ca.free(p);
        st.px = null;
    };
    if (st.prog == 0 or st.tex == 0) return true;
    // 三角形の頂点(位置は NDC、uv、陰)。たわんだ所ほど少し暗く(紙の折れ目のように)
    var verts: [(GX - 1) * (GY - 1) * 6 * 5]f32 = undefined;
    var k: usize = 0;
    const put = struct {
        fn f(v: []f32, i: *usize, gx: usize, gy: usize, w: f32, h: f32) void {
            const nd = st.nodes[gy * GX + gx];
            const r = rest(gx, gy);
            const dx = nd.p[0] - st.target[0] - r[0];
            const dy = nd.p[1] - st.target[1] - r[1];
            const dev = @sqrt(dx * dx + dy * dy);
            v[i.* + 0] = (nd.p[0] - st.ox) / w * 2 - 1;
            v[i.* + 1] = 1 - (nd.p[1] - st.oy) / h * 2;
            v[i.* + 2] = @as(f32, @floatFromInt(gx)) / (GX - 1);
            v[i.* + 3] = @as(f32, @floatFromInt(gy)) / (GY - 1);
            v[i.* + 4] = 1 - 0.22 * std.math.clamp(dev / 70, 0, 1);
            i.* += 5;
        }
    }.f;
    for (0..GY - 1) |gy| for (0..GX - 1) |gx| {
        put(&verts, &k, gx, gy, W, H);
        put(&verts, &k, gx + 1, gy, W, H);
        put(&verts, &k, gx, gy + 1, W, H);
        put(&verts, &k, gx + 1, gy, W, H);
        put(&verts, &k, gx + 1, gy + 1, W, H);
        put(&verts, &k, gx, gy + 1, W, H);
    };
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glUseProgram(st.prog);
    c.glUniform1i(c.glGetUniformLocation(st.prog, "u_tex"), 0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, st.tex);
    c.glBindVertexArray(st.vao);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, st.vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(k * 4), &verts, c.GL_STREAM_DRAW);
    c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(k / 5));
    c.glBindVertexArray(0);
    if (!st.drawn) {
        // 1 枚描けた: 本物の窓を隠してもらう
        st.drawn = true;
        if (app.wm) |wm| wm.poke();
    }
    if (st.released and settled) {
        // 収まった: 本物の窓を見せ、次のループでオーバーレイを片付ける
        st.finished = true;
        if (app.wm) |wm| wm.poke();
        app.reap_pending = true;
        return true; // 本物が出るまでの 1 コマはこの絵を出したまま
    }
    return true;
}

/// メインループから: 終わったオーバーレイを片付ける
pub fn reap(app: *App) void {
    if (!st.finished) return;
    if (st.surf) |s| {
        app.gpu.makeCurrent(s.egl_surf);
        if (st.tex != 0) c.glDeleteTextures(1, &st.tex);
        st.tex = 0;
        s.destroy();
        st.surf = null;
    }
    if (st.px) |p| ca.free(p);
    st.px = null;
    st.phase = .idle;
    st.win = null;
    st.finished = false;
}

/// 出力が抜かれた(app.zig): その出力でたわませているならやめる
pub fn outputRemoved(o: *Output) void {
    if (st.out != o) return;
    st.out = null;
    abort();
}
