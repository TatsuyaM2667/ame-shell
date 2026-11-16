// 1 つの窓の中身を 1 枚の絵として撮る(wobble.zig のたわむ動き・openfx.zig の開くときの波紋が使う)。
//
// ext-foreign-toplevel-list の窓と river_window_v1 は同じ identifier を持つ →
// ext_foreign_toplevel_image_capture_source で、その窓だけを ext-image-copy-capture で撮る。
// 撮れたら RGBA(乗算済みアルファ)の画素を渡す。撮れない(古い River など)ときは null を渡す。
const std = @import("std");
const c = @import("../c.zig");
const App = @import("../core/app.zig").App;

const ca = std.heap.c_allocator;

const FMT_ARGB8888: u32 = 0;
const FMT_XRGB8888: u32 = 1;
const FMT_ABGR8888: u32 = 0x34324241;
const FMT_XBGR8888: u32 = 0x34324258;

const Handle = struct {
    h: ?*c.struct_ext_foreign_toplevel_handle_v1 = null,
    id: [64]u8 = undefined,
    id_len: usize = 0,
};

var g_app: ?*App = null;
var g_src_mgr: ?*c.struct_ext_foreign_toplevel_image_capture_source_manager_v1 = null;
var g_handles: [96]Handle = [_]Handle{.{}} ** 96;

// ---------------------------------------------------------------------------
// 窓の一覧(identifier → handle)
// ---------------------------------------------------------------------------

pub fn bindList(app: *App, list: *c.struct_ext_foreign_toplevel_list_v1) void {
    g_app = app;
    _ = c.ext_foreign_toplevel_list_v1_add_listener(list, &list_listener, null);
}

pub fn bindSourceManager(app: *App, mgr: *c.struct_ext_foreign_toplevel_image_capture_source_manager_v1) void {
    g_app = app;
    g_src_mgr = mgr;
}

fn lToplevel(_: ?*anyopaque, _: ?*c.struct_ext_foreign_toplevel_list_v1, h: ?*c.struct_ext_foreign_toplevel_handle_v1) callconv(.C) void {
    const hh = h orelse return;
    for (&g_handles) |*slot| if (slot.h == null) {
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
    for (g_handles) |slot| if (slot.h != null and std.mem.eql(u8, slot.id[0..slot.id_len], ident)) return slot.h;
    return null;
}

// ---------------------------------------------------------------------------
// 撮影(ext-image-copy-capture。shot.zig と同じ流れ)
// ---------------------------------------------------------------------------

/// 撮れた絵。px は c_allocator で確保したもの(受け取った側が解放する)
pub const Pixels = struct { px: []u8, w: u32, h: u32 };

pub const Capture = struct {
    ctx: *anyopaque,
    /// 撮れた(px)・撮れなかった(null)。cancel したときは呼ばない
    done: *const fn (ctx: *anyopaque, px: ?Pixels) void,
    /// 半透明の窓(端末など)。River の窓の撮影は透明度を持たない形式しか無いので、暗い背景を透明度に戻す
    glassy: bool = false,
    active: bool = false,
    source: ?*c.struct_ext_image_capture_source_v1 = null,
    session: ?*c.struct_ext_image_copy_capture_session_v1 = null,
    frame: ?*c.struct_ext_image_copy_capture_frame_v1 = null,
    buffer: ?*c.struct_wl_buffer = null,
    map: ?[]align(std.mem.page_size) u8 = null,
    buf_w: u32 = 0,
    buf_h: u32 = 0,
    format: ?u32 = null,

    /// 撮り始める。始められなければ false(done は呼ばない)
    pub fn start(self: *Capture, ident: []const u8, glassy: bool) bool {
        const app = g_app orelse return false;
        if (self.active or app.shm == null or app.icc_mgr == null) return false;
        const mgr = g_src_mgr orelse return false;
        const h = findHandle(ident) orelse return false;
        self.glassy = glassy;
        self.format = null;
        self.buf_w = 0;
        self.buf_h = 0;
        self.source = c.ext_foreign_toplevel_image_capture_source_manager_v1_create_source(mgr, h);
        self.session = c.ext_image_copy_capture_manager_v1_create_session(app.icc_mgr, self.source, 0);
        if (self.session == null) {
            self.release();
            return false;
        }
        _ = c.ext_image_copy_capture_session_v1_add_listener(self.session, &session_listener, self);
        self.active = true;
        return true;
    }

    /// やめる(done は呼ばない)
    pub fn cancel(self: *Capture) void {
        self.release();
        self.active = false;
    }

    fn finish(self: *Capture, px: ?Pixels) void {
        self.release();
        self.active = false;
        self.done(self.ctx, px);
    }

    fn release(self: *Capture) void {
        if (self.frame) |f| c.ext_image_copy_capture_frame_v1_destroy(f);
        if (self.session) |x| c.ext_image_copy_capture_session_v1_destroy(x);
        if (self.source) |x| c.ext_image_capture_source_v1_destroy(x);
        if (self.buffer) |b| c.wl_buffer_destroy(b);
        if (self.map) |m| std.posix.munmap(m);
        self.frame = null;
        self.session = null;
        self.source = null;
        self.buffer = null;
        self.map = null;
    }
};

fn sBufferSize(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.C) void {
    const cap: *Capture = @ptrCast(@alignCast(data.?));
    cap.buf_w = w;
    cap.buf_h = h;
}
fn sShmFormat(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, fmt: u32) callconv(.C) void {
    const cap: *Capture = @ptrCast(@alignCast(data.?));
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
    if (rank(fmt) > 0 and (cap.format == null or rank(fmt) > rank(cap.format.?))) cap.format = fmt;
}
fn sDmabufDevice(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: ?*c.struct_wl_array) callconv(.C) void {}
fn sDmabufFormat(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: u32, _: ?*c.struct_wl_array) callconv(.C) void {}
fn sDone(data: ?*anyopaque, sess: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.C) void {
    const cap: *Capture = @ptrCast(@alignCast(data.?));
    const app = g_app orelse return;
    if (cap.frame != null or !cap.active) return;
    const fmt = cap.format orelse return cap.finish(null);
    if (cap.buf_w == 0 or cap.buf_h == 0) return cap.finish(null);
    const stride = cap.buf_w * 4;
    const size: usize = @as(usize, stride) * cap.buf_h;
    const fd: c_int = c.memfd_create("ame-wincap", c.MFD_CLOEXEC);
    if (fd < 0) return cap.finish(null);
    defer std.posix.close(fd);
    std.posix.ftruncate(fd, size) catch return cap.finish(null);
    cap.map = std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0) catch return cap.finish(null);
    const pool = c.wl_shm_create_pool(app.shm, fd, @intCast(size));
    cap.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(cap.buf_w), @intCast(cap.buf_h), @intCast(stride), fmt);
    c.wl_shm_pool_destroy(pool);
    cap.frame = c.ext_image_copy_capture_session_v1_create_frame(sess);
    _ = c.ext_image_copy_capture_frame_v1_add_listener(cap.frame, &frame_listener, cap);
    c.ext_image_copy_capture_frame_v1_attach_buffer(cap.frame, cap.buffer);
    c.ext_image_copy_capture_frame_v1_damage_buffer(cap.frame, 0, 0, @intCast(cap.buf_w), @intCast(cap.buf_h));
    c.ext_image_copy_capture_frame_v1_capture(cap.frame);
}
fn sStopped(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.C) void {
    const cap: *Capture = @ptrCast(@alignCast(data.?));
    if (cap.active) cap.finish(null);
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
    const cap: *Capture = @ptrCast(@alignCast(data.?));
    const map = cap.map orelse return cap.finish(null);
    const n: usize = @as(usize, cap.buf_w) * cap.buf_h;
    const px = ca.alloc(u8, n * 4) catch return cap.finish(null);
    const fmt = cap.format.?;
    const bgr = fmt == FMT_XRGB8888 or fmt == FMT_ARGB8888;
    const opaque_ = fmt == FMT_XRGB8888 or fmt == FMT_XBGR8888;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = map[i * 4 ..][0..4];
        const q = px[i * 4 ..][0..4];
        // 乗算済みアルファのまま(半透明の端末も透けたまま)
        var a: u8 = if (opaque_) 255 else p[3];
        if (opaque_ and cap.glassy) {
            // 黒の上に重ねた半透明の背景(66%)の色は暗い → その所は透明度 0.66 に、明るい文字・アイコンは不透明に
            const mx: f32 = @as(f32, @floatFromInt(@max(p[0], @max(p[1], p[2])))) / 255.0;
            const t = std.math.clamp((mx - 0.05) / 0.2, 0, 1);
            a = @intFromFloat(255.0 * (0.66 + 0.34 * t * t * (3 - 2 * t)));
        }
        q.* = if (bgr) .{ p[2], p[1], p[0], a } else .{ p[0], p[1], p[2], a };
    }
    cap.finish(.{ .px = px, .w = cap.buf_w, .h = cap.buf_h });
}
fn fFailed(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: u32) callconv(.C) void {
    const cap: *Capture = @ptrCast(@alignCast(data.?));
    cap.finish(null);
}
const frame_listener = c.struct_ext_image_copy_capture_frame_v1_listener{
    .transform = fTransform,
    .damage = fDamage,
    .presentation_time = fTime,
    .ready = fReady,
    .failed = fFailed,
};
