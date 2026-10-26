// layer-shell / session-lock サーフェスの共通部分。
//
// 描画は必ず wl_surface.frame コールバック駆動:
//   状態が変わる → schedule() でフレームコールバックを要求
//   → コンポジタが次の vblank で done を送る → draw() → まだ動いていれば次を要求
// 動きが止まればコールバックを要求しないので、何もしない間は一切描画しない。
const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig").App;
const gfx = @import("gfx.zig");

pub const PointerKind = enum { enter, motion, leave, press, release, scroll };

pub const PointerEvent = struct {
    kind: PointerKind,
    x: f32,
    y: f32,
    button: u32 = 0,
    scroll: f32 = 0,
};

pub const KeyEvent = struct {
    sym: u32,
    utf8: []const u8,
    ctrl: bool,
    shift: bool,
};

pub const Handler = struct {
    ctx: *anyopaque,
    /// 描画。まだアニメーション中なら true(次フレームを要求する)。
    draw: *const fn (ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool,
    pointer: ?*const fn (ctx: *anyopaque, s: *Surface, ev: PointerEvent) void = null,
    key: ?*const fn (ctx: *anyopaque, s: *Surface, ev: KeyEvent) void = null,
    configured: ?*const fn (ctx: *anyopaque, s: *Surface) void = null,
    closed: ?*const fn (ctx: *anyopaque, s: *Surface) void = null,
};

pub const LayerOpts = struct {
    layer: u32 = c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
    anchor: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    exclusive: i32 = 0,
    margin: [4]i32 = .{ 0, 0, 0, 0 }, // top right bottom left
    keyboard: u32 = c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
    namespace: [:0]const u8 = "ame-shell",
    output: ?*c.struct_wl_output = null,
};

pub const Surface = struct {
    app: *App,
    handler: Handler,
    wl: *c.struct_wl_surface,
    layer: ?*c.struct_zwlr_layer_surface_v1 = null,
    lock_surf: ?*c.struct_ext_session_lock_surface_v1 = null,
    egl_win: ?*c.struct_wl_egl_window = null,
    egl_surf: c.EGLSurface = c.EGL_NO_SURFACE,
    width: u32 = 0,
    height: u32 = 0,
    scale: i32 = 1,
    configured: bool = false,
    frame_cb: ?*c.struct_wl_callback = null,
    want_frame: bool = false,
    last_ms: u32 = 0,
    /// 出力上での位置(ガラスのサンプル位置合わせ用)
    origin: [2]f32 = .{ 0, 0 },
    output: ?*anyopaque = null, // *app.Output
    input_region_full: bool = true,

    pub fn createLayer(app: *App, h: Handler, o: LayerOpts) !*Surface {
        const s = try app.alloc.create(Surface);
        const wl = c.wl_compositor_create_surface(app.compositor) orelse return error.Surface;
        s.* = .{ .app = app, .handler = h, .wl = wl };
        c.wl_surface_set_user_data(wl, s);
        _ = c.wl_surface_add_listener(wl, &surface_listener, s);
        const ls = c.zwlr_layer_shell_v1_get_layer_surface(app.layer_shell, wl, o.output, o.layer, o.namespace.ptr) orelse return error.Layer;
        s.layer = ls;
        _ = c.zwlr_layer_surface_v1_add_listener(ls, &layer_listener, s);
        c.zwlr_layer_surface_v1_set_size(ls, o.width, o.height);
        c.zwlr_layer_surface_v1_set_anchor(ls, o.anchor);
        c.zwlr_layer_surface_v1_set_exclusive_zone(ls, o.exclusive);
        c.zwlr_layer_surface_v1_set_margin(ls, o.margin[0], o.margin[1], o.margin[2], o.margin[3]);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(ls, o.keyboard);
        c.wl_surface_commit(wl); // 初回は中身なしでコミット → configure を待つ
        return s;
    }

    pub fn createLock(app: *App, h: Handler, lock: *c.struct_ext_session_lock_v1, output: *c.struct_wl_output) !*Surface {
        const s = try app.alloc.create(Surface);
        const wl = c.wl_compositor_create_surface(app.compositor) orelse return error.Surface;
        s.* = .{ .app = app, .handler = h, .wl = wl };
        c.wl_surface_set_user_data(wl, s);
        _ = c.wl_surface_add_listener(wl, &surface_listener, s);
        const ls = c.ext_session_lock_v1_get_lock_surface(lock, wl, output) orelse return error.Lock;
        s.lock_surf = ls;
        _ = c.ext_session_lock_surface_v1_add_listener(ls, &lock_listener, s);
        return s;
    }

    pub fn destroy(self: *Surface) void {
        if (self.frame_cb) |cb| c.wl_callback_destroy(cb);
        if (self.egl_surf != c.EGL_NO_SURFACE) {
            // 破棄するサーフェスが current のままだと EGL が警告するので外しておく
            _ = c.eglMakeCurrent(self.app.gpu.dpy, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, self.app.gpu.ctx);
            _ = c.eglDestroySurface(self.app.gpu.dpy, self.egl_surf);
        }
        if (self.egl_win) |w| c.wl_egl_window_destroy(w);
        if (self.layer) |l| c.zwlr_layer_surface_v1_destroy(l);
        if (self.lock_surf) |l| c.ext_session_lock_surface_v1_destroy(l);
        self.app.forgetSurface(self);
        c.wl_surface_destroy(self.wl);
        self.app.alloc.destroy(self);
    }

    /// サイズ変更(layer surface の set_size)
    pub fn resize(self: *Surface, w: u32, h: u32) void {
        if (self.layer) |l| {
            c.zwlr_layer_surface_v1_set_size(l, w, h);
            c.wl_surface_commit(self.wl);
        }
    }

    pub fn setMargin(self: *Surface, m: [4]i32) void {
        if (self.layer) |l| c.zwlr_layer_surface_v1_set_margin(l, m[0], m[1], m[2], m[3]);
    }

    pub fn setExclusive(self: *Surface, z: i32) void {
        if (self.layer) |l| c.zwlr_layer_surface_v1_set_exclusive_zone(l, z);
    }

    /// 入力を受け付ける領域を指定(w=0 で入力を全て透過)。ポップアップの隙間をクリック透過にするため。
    pub fn setInputRect(self: *Surface, x: i32, y: i32, w: i32, h: i32) void {
        const r = c.wl_compositor_create_region(self.app.compositor);
        if (w > 0 and h > 0) c.wl_region_add(r, x, y, w, h);
        c.wl_surface_set_input_region(self.wl, r);
        c.wl_region_destroy(r);
        self.input_region_full = false;
    }

    /// 複数の矩形を入力領域にする(枠: バー・縁・開いているドロワーだけクリックを受け、それ以外は窓へ透過)
    pub fn setInputRects(self: *Surface, rects: []const [4]f32) void {
        const r = c.wl_compositor_create_region(self.app.compositor);
        for (rects) |q| {
            if (q[2] < 1 or q[3] < 1) continue;
            c.wl_region_add(r, @intFromFloat(@floor(q[0])), @intFromFloat(@floor(q[1])), @intFromFloat(@ceil(q[2])), @intFromFloat(@ceil(q[3])));
        }
        c.wl_surface_set_input_region(self.wl, r);
        c.wl_region_destroy(r);
        self.input_region_full = false;
    }

    /// 次のフレームで描き直す。
    pub fn schedule(self: *Surface) void {
        if (!self.configured) {
            self.want_frame = true;
            return;
        }
        if (self.frame_cb != null) {
            self.want_frame = true;
            return;
        }
        self.requestFrame();
        c.wl_surface_commit(self.wl);
    }

    fn requestFrame(self: *Surface) void {
        const cb = c.wl_surface_frame(self.wl) orelse return;
        self.frame_cb = cb;
        _ = c.wl_callback_add_listener(cb, &frame_listener, self);
    }

    fn ensureEgl(self: *Surface) void {
        const pw: c_int = @intCast(self.width * @as(u32, @intCast(self.scale)));
        const ph: c_int = @intCast(self.height * @as(u32, @intCast(self.scale)));
        if (self.egl_win) |w| {
            c.wl_egl_window_resize(w, pw, ph, 0, 0);
        } else {
            self.egl_win = c.wl_egl_window_create(self.wl, pw, ph);
            self.egl_surf = c.eglCreateWindowSurface(self.app.gpu.dpy, self.app.gpu.cfg, @ptrCast(self.egl_win.?), null);
            self.app.gpu.makeCurrent(self.egl_surf);
            // フレームコールバックで同期するので、eglSwapBuffers 自体は待たせない。
            // (待たせると複数サーフェスで互いの vblank を待ってカクつく)
            _ = c.eglSwapInterval(self.app.gpu.dpy, 0);
        }
        c.wl_surface_set_buffer_scale(self.wl, self.scale);
    }

    /// 実際の描画。frame コールバックか、configure 直後に呼ばれる。
    pub fn render(self: *Surface, dt: f32) void {
        if (!self.configured or self.width == 0 or self.height == 0) return;
        const app = self.app;
        const t0 = std.time.nanoTimestamp();
        app.gpu.makeCurrent(self.egl_surf);
        var out_size: [2]f32 = .{ @floatFromInt(self.width), @floatFromInt(self.height) };
        var blur: c.GLuint = 0;
        if (app.outputFor(self)) |o| {
            out_size = .{ @floatFromInt(o.width), @floatFromInt(o.height) };
            blur = o.backdrop.blurred;
        }
        const cv = &app.canvas;
        cv.begin(@floatFromInt(self.width), @floatFromInt(self.height), @floatFromInt(self.scale), self.origin, out_size, blur, app.timeSec());
        const t_draw = std.time.nanoTimestamp();
        const animating = self.handler.draw(self.handler.ctx, self, cv, dt);
        const t_flush = std.time.nanoTimestamp();
        cv.end();
        const t_swap = std.time.nanoTimestamp();
        self.want_frame = false;
        // swap の commit にフレーム要求を相乗りさせる
        if (animating and self.frame_cb == null) self.requestFrame();
        app.frame_stats.record(dt);
        if (app.fonts.needs_redraw) {
            app.fonts.needs_redraw = false;
            app.redrawAll();
        }
        _ = c.eglSwapBuffers(app.gpu.dpy, self.egl_surf);
        const t_end = std.time.nanoTimestamp();
        app.frame_stats.recordRender(@intCast(@divTrunc(t_end - t0, 1000)));
        // AME_DEBUG_FRAMES=<ms>: その時間を超えたフレームの内訳を出す(性能調査用)
        const thr_ms: i128 = if (std.posix.getenv("AME_DEBUG_FRAMES")) |v| (std.fmt.parseInt(i128, v, 10) catch 20) else std.math.maxInt(i64);
        if (t_end - t0 > thr_ms * 1_000_000) {
            std.log.warn("slow frame {d}x{d}: setup={d}us draw={d}us gl={d}us swap={d}us", .{ self.width, self.height, @divTrunc(t_draw - t0, 1000), @divTrunc(t_flush - t_draw, 1000), @divTrunc(t_swap - t_flush, 1000), @divTrunc(t_end - t_swap, 1000) });
        }
    }
};

// ---------------------------------------------------------------------------
// リスナ
// ---------------------------------------------------------------------------

fn onFrameDone(data: ?*anyopaque, cb: ?*c.struct_wl_callback, time: u32) callconv(.C) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    c.wl_callback_destroy(cb);
    s.frame_cb = null;
    // 前回描画からの経過時間。初回や長い休止明けは 1/60 秒として扱う(ジャンプ防止)。
    var dt: f32 = 1.0 / 60.0;
    if (s.last_ms != 0 and time > s.last_ms) {
        dt = @as(f32, @floatFromInt(time - s.last_ms)) / 1000.0;
        if (dt > 0.1) dt = 1.0 / 60.0;
    }
    s.last_ms = time;
    s.render(dt);
}
const frame_listener = c.struct_wl_callback_listener{ .done = onFrameDone };

fn onLayerConfigure(data: ?*anyopaque, ls: ?*c.struct_zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.C) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    c.zwlr_layer_surface_v1_ack_configure(ls, serial);
    s.width = w;
    s.height = h;
    s.configured = true;
    s.ensureEgl();
    if (s.handler.configured) |f| f(s.handler.ctx, s);
    s.last_ms = 0;
    s.render(1.0 / 60.0);
}

fn onLayerClosed(data: ?*anyopaque, _: ?*c.struct_zwlr_layer_surface_v1) callconv(.C) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    if (s.handler.closed) |f| f(s.handler.ctx, s);
}
const layer_listener = c.struct_zwlr_layer_surface_v1_listener{ .configure = onLayerConfigure, .closed = onLayerClosed };

fn onLockConfigure(data: ?*anyopaque, ls: ?*c.struct_ext_session_lock_surface_v1, serial: u32, w: u32, h: u32) callconv(.C) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    c.ext_session_lock_surface_v1_ack_configure(ls, serial);
    s.width = w;
    s.height = h;
    s.configured = true;
    s.ensureEgl();
    if (s.handler.configured) |f| f(s.handler.ctx, s);
    s.render(1.0 / 60.0);
}
const lock_listener = c.struct_ext_session_lock_surface_v1_listener{ .configure = onLockConfigure };

fn onEnter(data: ?*anyopaque, _: ?*c.struct_wl_surface, out: ?*c.struct_wl_output) callconv(.C) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    // wl_compositor v6 未満(preferred_buffer_scale が来ない)ときは出力のスケールを使う
    if (s.app.compositor_version < 6) {
        if (s.app.outputByWl(out)) |o| {
            if (o.scale != s.scale) {
                s.scale = o.scale;
                if (s.configured) {
                    s.ensureEgl();
                    s.schedule();
                }
            }
        }
    }
}
fn onLeave(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: ?*c.struct_wl_output) callconv(.C) void {}
fn onPreferredScale(data: ?*anyopaque, _: ?*c.struct_wl_surface, factor: i32) callconv(.C) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    if (factor == s.scale or factor < 1) return;
    s.scale = factor;
    if (s.configured) {
        s.ensureEgl();
        s.schedule();
    }
}
fn onPreferredTransform(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: u32) callconv(.C) void {}
const surface_listener = c.struct_wl_surface_listener{
    .enter = onEnter,
    .leave = onLeave,
    .preferred_buffer_scale = onPreferredScale,
    .preferred_buffer_transform = onPreferredTransform,
};
