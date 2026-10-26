// 壁紙: background レイヤーの全画面サーフェス。
//
// シーン(オーロラ / 雨 / 画像)を出力解像度 × scale の FBO に描き、それを拡大表示する。
// 同時にそのシーンからブラー段を作り、各パネルのガラスが「真後ろの壁紙」をサンプルできるようにする。
//
// 省電力: ライブ壁紙はフレームコールバックを毎回は要求せず、timerfd で設定 FPS ごとに1回だけ
// 描く。AC 電源から外れたら battery-fps に落とし、解像度も 3/4 にする。画像壁紙は
// 切り替えのトランジション中しか描かないので待機時の負荷は 0。
const std = @import("std");
const c = @import("c.zig");
const anim = @import("anim.zig");
const Color = anim.Color;
const Spring = anim.Spring;
const gfx = @import("gfx.zig");
const appmod = @import("app.zig");
const App = appmod.App;
const Output = appmod.Output;
const cfgmod = @import("config.zig");
const surface = @import("surface.zig");
const Surface = surface.Surface;
const loop = @import("platform/loop.zig");

pub const Image = struct {
    tex: c.GLuint = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const Wallpaper = struct {
    app: *App,
    out: *Output,
    surf: *Surface,
    timer: loop.Timer,
    mode: cfgmod.WallMode,
    prev_mode: cfgmod.WallMode,
    img: Image = .{},
    prev_img: Image = .{},
    trans: Spring = Spring.init(1, 1.6, 1.0),
    /// 時間は「描いた分だけ」進める(止めている間に時間が飛ばないように)
    scene_time: f32 = 0,
    last_ms: u64 = 0,
    first_frames: u8 = 0,

    pub fn create(app: *App, out: *Output) !*Wallpaper {
        const self = try app.alloc.create(Wallpaper);
        self.* = .{
            .app = app,
            .out = out,
            .surf = undefined,
            .timer = try loop.Timer.init(),
            .mode = app.cfg.wall_mode,
            .prev_mode = app.cfg.wall_mode,
        };
        const all = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        self.surf = try Surface.createLayer(app, .{ .ctx = self, .draw = draw, .configured = configured }, .{
            .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
            .anchor = all,
            .exclusive = -1, // バーの排他領域を無視して全面を覆う
            .namespace = "ame-wallpaper",
            .output = out.wl,
        });
        self.surf.output = out;
        // 壁紙は入力を受けない(デスクトップのクリックはコンポジタへ)
        self.surf.setInputRect(0, 0, 0, 0);
        try app.loop.add(self.timer.fd, c.EPOLLIN, self, onTimer);
        if (self.mode == .image) self.loadImage(app.cfg.wall_image.get());
        self.updateTimer();
        return self;
    }

    pub fn destroy(self: *Wallpaper) void {
        self.app.loop.remove(self.timer.fd);
        _ = c.close(self.timer.fd);
        self.surf.destroy();
        self.app.alloc.destroy(self);
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        const self: *Wallpaper = @ptrCast(@alignCast(ctx));
        // 全面サーフェスのサイズ = 出力の論理サイズ
        self.out.width = s.width;
        self.out.height = s.height;
        if (self.out.bar) |b| b.surf.schedule();
    }

    fn animated(self: *Wallpaper) bool {
        return self.app.cfg.wall_animate and self.mode != .image;
    }

    fn fps(self: *Wallpaper) f32 {
        const cfg = &self.app.cfg;
        const on_ac = self.app.sys.battery.on_ac;
        // 出力のリフレッシュレートを超えて描いても見えないので上限にする
        // refresh=0 は「不明」(ヘッドレス等)。60Hz とみなす。
        const refresh: f32 = if (self.out.refresh_mhz <= 0) 60 else @as(f32, @floatFromInt(self.out.refresh_mhz)) / 1000.0;
        return @min(if (on_ac) cfg.wall_fps else cfg.wall_battery_fps, refresh);
    }

    fn updateTimer(self: *Wallpaper) void {
        if (self.animated()) {
            const ms: u64 = @intFromFloat(1000.0 / self.fps());
            self.timer.arm(ms, ms);
        } else {
            self.timer.disarm();
        }
    }

    pub fn powerChanged(self: *Wallpaper) void {
        self.updateTimer();
        self.surf.schedule();
    }

    pub fn configChanged(self: *Wallpaper, old: *const cfgmod.Config) void {
        const cfg = &self.app.cfg;
        if (old.wall_mode != cfg.wall_mode or !std.mem.eql(u8, old.wall_image.get(), cfg.wall_image.get())) {
            self.switchTo(cfg.wall_mode, cfg.wall_image.get());
        }
        self.updateTimer();
        self.surf.schedule();
    }

    /// 壁紙を切り替える(波紋トランジション付き)
    pub fn switchTo(self: *Wallpaper, mode: cfgmod.WallMode, image_path: []const u8) void {
        // 前の画像テクスチャは捨てる(トランジション中なら途中のものも)
        if (self.prev_img.tex != 0 and self.prev_img.tex != self.img.tex) c.glDeleteTextures(1, &self.prev_img.tex);
        self.prev_img = self.img;
        self.img = .{};
        self.prev_mode = self.mode;
        self.mode = mode;
        if (mode == .image) self.loadImage(image_path);
        self.trans.snap(0);
        self.trans.set(1);
        self.last_ms = 0;
        self.updateTimer();
        self.surf.schedule();
    }

    fn loadImage(self: *Wallpaper, path_in: []const u8) void {
        var buf: [600]u8 = undefined;
        // "~/" を展開
        const path = if (std.mem.startsWith(u8, path_in, "~/"))
            std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ std.posix.getenv("HOME") orelse "", path_in[2..] }) catch return
        else
            std.fmt.bufPrintZ(&buf, "{s}", .{path_in}) catch return;
        var w: c_int = 0;
        var h: c_int = 0;
        var n: c_int = 0;
        const px = c.stbi_load(path.ptr, &w, &h, &n, 4) orelse {
            std.log.warn("壁紙画像を読めません: {s}(オーロラにフォールバック)", .{path});
            self.mode = .aurora;
            return;
        };
        defer c.stbi_image_free(px);
        self.app.gpu.makeCurrent(self.surf.egl_surf);
        self.img = .{ .tex = gfx.uploadImage(px, w, h), .w = @floatFromInt(w), .h = @floatFromInt(h) };
    }

    fn onTimer(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *Wallpaper = @ptrCast(@alignCast(ctx));
        self.timer.ack();
        self.surf.schedule();
    }

    fn draw(ctx: *anyopaque, s: *Surface, _: *gfx.Canvas, dt: f32) bool {
        const self: *Wallpaper = @ptrCast(@alignCast(ctx));
        const app = self.app;
        const cfg = &app.cfg;
        const now = loop.nowMs();
        // 時間の進め方: 実時間で進めるが、長く止まっていた分はスキップ
        if (self.last_ms != 0 and self.animated()) {
            const d = @as(f32, @floatFromInt(now - self.last_ms)) / 1000.0;
            self.scene_time += @min(d, 0.25);
        }
        self.last_ms = now;
        const transitioning = self.trans.step(dt);

        var scale = cfg.wall_scale;
        if (!app.sys.battery.on_ac) scale *= 0.75;
        // 画像は等倍で(縮小すると細部が潰れる)
        if (self.mode == .image and !transitioning) scale = 1.0;
        const pw: c_int = @intFromFloat(@as(f32, @floatFromInt(s.width * @as(u32, @intCast(s.scale)))) * scale);
        const ph: c_int = @intFromFloat(@as(f32, @floatFromInt(s.height * @as(u32, @intCast(s.scale)))) * scale);
        self.out.backdrop.render(&app.gpu, pw, ph, .{
            .time = self.scene_time,
            .mode = @intFromEnum(self.mode),
            .prev_mode = @intFromEnum(self.prev_mode),
            .mix = self.trans.x,
            .img = self.img.tex,
            .img_w = self.img.w,
            .img_h = self.img.h,
            .prev = self.prev_img.tex,
            .prev_w = self.prev_img.w,
            .prev_h = self.prev_img.h,
            .ca = Color.hex(cfg.aurora_a),
            .cb = Color.hex(cfg.aurora_b),
            .cc = Color.hex(cfg.aurora_c),
        }, cfg.blur);
        self.out.backdrop.blitTo(&app.gpu, @intCast(s.width * @as(u32, @intCast(s.scale))), @intCast(s.height * @as(u32, @intCast(s.scale))));

        if (!transitioning and self.prev_img.tex != 0) {
            c.glDeleteTextures(1, &self.prev_img.tex);
            self.prev_img = .{};
        }
        // ガラス面は壁紙が変わった直後だけ描き直す(ライブ壁紙の毎フレームでは描き直さない:
        // ブラーの微小な変化のためにバーを再描画するのは割に合わない)
        if (transitioning or self.first_frames < 2) {
            app.backdropChanged(self.out);
            self.first_frames += 1;
        }
        return transitioning;
    }
};
