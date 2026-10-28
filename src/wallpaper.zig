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
const theme = @import("theme.zig");
const appmod = @import("app.zig");
const App = appmod.App;
const Output = appmod.Output;
const cfgmod = @import("config.zig");
const surface = @import("surface.zig");
const Surface = surface.Surface;
const loop = @import("platform/loop.zig");
const video = @import("video.zig");

/// 壁紙の失敗の通知を最後に出した時刻(出力ごとに重ねて出さない)
var last_fail_ms: u64 = 0;

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
    /// ピッカーなどで本人が切り替えた(失敗したら通知する。起動時の復元では通知しない)
    user_switch: bool = false,
    /// 時間は「描いた分だけ」進める(止めている間に時間が飛ばないように)
    scene_time: f32 = 0,
    last_ms: u64 = 0,
    first_frames: u8 = 0,
    /// 切り替え演出(0=波紋 1=円 2=斜めワイプ 3=短冊)と円の中心(uv、下が 0)
    fx: c_int = 0,
    /// 表示中の画像のパス(ピッカーで「いまの壁紙」を選ぶため)
    img_path: [512]u8 = undefined,
    img_path_len: usize = 0,
    fx_origin: [2]f32 = .{ 0.5, 0.5 },
    /// 動画・GIF の壁紙(mode == .video)。切り替え中は前の動画を prev_player に残す(前のコマを表示し続けるため)
    player: ?*video.Player = null,
    prev_player: ?*video.Player = null,
    /// 動画の最初のコマから配色を作ったか
    video_scheme_done: bool = false,

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
        // ピッカーで最後に選んだ壁紙があればそれを優先(再起動・再ログイン後も保つ)
        var sb: [600]u8 = undefined;
        if (loadSaved(&sb)) |saved| {
            self.mode = saved.mode;
            self.prev_mode = saved.mode;
            if (saved.mode == .image or saved.mode == .video) self.loadMedia(saved.path);
        } else if (self.mode == .image or self.mode == .video) self.loadMedia(app.cfg.wall_image.get());
        self.updateTimer();
        return self;
    }

    pub fn destroy(self: *Wallpaper) void {
        self.dropPlayers();
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
        // 動画は mpv から「新しいコマ」の通知が来たときだけ描くので、タイマーは使わない
        return self.app.cfg.wall_animate and self.mode != .image and self.mode != .video;
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
        self.switchFx(mode, image_path, 0, .{ 0.5, 0.5 });
    }

    /// 演出を指定して切り替える(fx < 0 なら円・斜めワイプ・短冊からランダム)。origin は出力上の uv。
    pub fn switchFx(self: *Wallpaper, mode: cfgmod.WallMode, image_path: []const u8, fx: c_int, origin: [2]f32) void {
        self.fx = if (fx >= 0) fx else @intCast(1 + @mod(loop.nowMs() / 7, 3));
        self.fx_origin = .{ origin[0], 1 - origin[1] };
        // 円の演出は時間をかけた方が映えるので応答を遅めに
        self.trans.response = if (self.fx == 0) 1.6 else 1.25;
        // 前の画像テクスチャは捨てる(トランジション中なら途中のものも)
        self.dropPrev();
        self.prev_img = self.img;
        self.img = .{};
        self.prev_player = self.player;
        self.player = null;
        self.prev_mode = self.mode;
        self.mode = mode;
        self.user_switch = true;
        if (mode == .image or mode == .video) self.loadMedia(image_path) else theme.setWallScheme(self.app, null);
        if ((mode == .image or mode == .video) and self.mode == .aurora) self.reportFail(image_path);
        self.trans.snap(0);
        self.trans.set(1);
        self.last_ms = 0;
        self.updateTimer();
        self.surf.schedule();
    }

    /// 画像か動画(GIF・MP4 等)かを拡張子で見分けて読み込む
    fn loadMedia(self: *Wallpaper, path_in: []const u8) void {
        if (!video.isVideoPath(path_in)) {
            self.mode = .image;
            self.loadImage(path_in);
            return;
        }
        var buf: [600]u8 = undefined;
        const path = if (std.mem.startsWith(u8, path_in, "~/"))
            std.fmt.bufPrint(&buf, "{s}/{s}", .{ std.posix.getenv("HOME") orelse "", path_in[2..] }) catch return
        else
            path_in;
        self.img_path_len = @min(path_in.len, self.img_path.len);
        @memcpy(self.img_path[0..self.img_path_len], path_in[0..self.img_path_len]);
        const app = self.app;
        app.gpu.makeCurrent(self.surf.egl_surf);
        const sz = self.out.logicalSize();
        const sc: i32 = @max(self.out.scale, 1);
        const max_w: c_int = @intCast(@as(i32, @intCast(sz[0])) * sc);
        const max_h: c_int = @intCast(@as(i32, @intCast(sz[1])) * sc);
        if (video.Player.create(app.alloc, path, max_w, max_h)) |p| {
            self.player = p;
            self.mode = .video;
            self.video_scheme_done = false;
            app.loop.add(p.pipe_r, c.EPOLLIN, self, onVideo) catch {};
            return;
        }
        // libmpv が無い: GIF なら 1 コマ目を静止画として使う
        if (std.ascii.endsWithIgnoreCase(path, ".gif")) {
            self.mode = .image;
            self.loadImage(path_in);
        } else {
            std.log.warn("動画の壁紙を再生できません: {s}(オーロラにフォールバック)", .{path});
            self.mode = .aurora;
        }
    }

    fn onVideo(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Wallpaper = @ptrCast(@alignCast(ctx));
        for ([_]?*video.Player{ self.player, self.prev_player }) |pp| if (pp) |p| if (p.pipe_r == fd) {
            if (p.failed and self.player == p and self.mode == .video) {
                // 再生できなかった: オーロラに戻す(プレーヤーは次の切り替えで片付く)
                p.failed = false;
                self.mode = .aurora;
                theme.setWallScheme(self.app, null);
                self.reportFail(self.img_path[0..self.img_path_len]);
                self.surf.schedule();
            } else if (p.pump()) self.surf.schedule();
        };
    }

    /// 切り替え前の壁紙(画像テクスチャまたは動画)を捨てる
    fn dropPrev(self: *Wallpaper) void {
        if (self.prev_player) |p| {
            self.app.loop.remove(p.pipe_r);
            p.destroy(self.app.alloc);
            self.prev_player = null;
        } else if (self.prev_img.tex != 0 and self.prev_img.tex != self.img.tex) {
            c.glDeleteTextures(1, &self.prev_img.tex);
        }
        self.prev_img = .{};
    }

    fn dropPlayers(self: *Wallpaper) void {
        self.dropPrev();
        if (self.player) |p| {
            self.app.loop.remove(p.pipe_r);
            p.destroy(self.app.alloc);
            self.player = null;
        }
    }

    /// 動画の最初のコマから配色を作る(1 回だけ、FBO から読み戻す)
    fn videoScheme(self: *Wallpaper, p: *video.Player) void {
        const w = p.w;
        const h = p.h;
        if (w <= 0 or h <= 0) return;
        const px = self.app.alloc.alloc(u8, @intCast(w * h * 4)) catch return;
        defer self.app.alloc.free(px);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, p.fbo);
        c.glReadPixels(0, 0, w, h, c.GL_RGBA, c.GL_UNSIGNED_BYTE, px.ptr);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        theme.setWallScheme(self.app, theme.schemeFromPixels(px.ptr, w, h));
        self.video_scheme_done = true;
    }

    /// 壁紙を変えられなかったことを知らせる(出力が複数あっても 1 回だけ)
    fn reportFail(self: *Wallpaper, path: []const u8) void {
        if (!self.user_switch) return;
        const now = loop.nowMs();
        if (last_fail_ms != 0 and now -| last_fail_ms < 2000) return;
        last_fail_ms = now;
        theme.flashError(self.app);
        var body: [700]u8 = undefined;
        const reason = if (video.isVideoPath(path)) video.last_error else "画像を読めません";
        const msg = std.fmt.bufPrint(&body, "{s}\n{s}", .{ reason, std.fs.path.basename(path) }) catch reason;
        self.app.notifs.post("ame-shell", "壁紙を変えられませんでした", msg, 0);
    }

    fn loadImage(self: *Wallpaper, path_in: []const u8) void {
        var buf: [600]u8 = undefined;
        // "~/" を展開
        const path = if (std.mem.startsWith(u8, path_in, "~/"))
            std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ std.posix.getenv("HOME") orelse "", path_in[2..] }) catch return
        else
            std.fmt.bufPrintZ(&buf, "{s}", .{path_in}) catch return;
        self.img_path_len = @min(path_in.len, self.img_path.len);
        @memcpy(self.img_path[0..self.img_path_len], path_in[0..self.img_path_len]);
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
        // 壁紙の色から配色を作る(アクセント・ガラス・文字色が壁紙に合わせて滑らかに変わる)
        theme.setWallScheme(self.app, theme.schemeFromPixels(px, w, h));
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
        if ((self.mode == .image or self.mode == .video) and !transitioning) scale = 1.0;
        // 動画: 新しいコマを描いてから、そのテクスチャを「画像」としてシーンに渡す
        if (self.player != null or self.prev_player != null) app.gpu.makeCurrent(s.egl_surf);
        if (self.player) |p| {
            p.render();
            if (p.tex != 0) {
                self.img = .{ .tex = p.tex, .w = @floatFromInt(p.w), .h = @floatFromInt(p.h) };
                if (!self.video_scheme_done) self.videoScheme(p);
            }
        }
        if (self.prev_player) |p| {
            p.render();
            if (p.tex != 0) self.prev_img = .{ .tex = p.tex, .w = @floatFromInt(p.w), .h = @floatFromInt(p.h) };
        }
        const shader_mode = struct {
            fn f(m: cfgmod.WallMode) c_int {
                return if (m == .video) @intFromEnum(cfgmod.WallMode.image) else @intFromEnum(m);
            }
        }.f;
        const pw: c_int = @intFromFloat(@as(f32, @floatFromInt(s.width * @as(u32, @intCast(s.scale)))) * scale);
        const ph: c_int = @intFromFloat(@as(f32, @floatFromInt(s.height * @as(u32, @intCast(s.scale)))) * scale);
        self.out.backdrop.render(&app.gpu, pw, ph, .{
            .time = self.scene_time,
            .mode = shader_mode(self.mode),
            .prev_mode = shader_mode(self.prev_mode),
            .mix = self.trans.x,
            .trans = self.fx,
            .origin = self.fx_origin,
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

        if (!transitioning and (self.prev_img.tex != 0 or self.prev_player != null)) self.dropPrev();
        // ガラス面は壁紙が変わった直後だけ描き直す(ライブ壁紙の毎フレームでは描き直さない:
        // ブラーの微小な変化のためにバーを再描画するのは割に合わない)
        if (transitioning or self.first_frames < 2) {
            app.backdropChanged(self.out);
            self.first_frames += 1;
        }
        return transitioning;
    }
};

// ---- 最後に選んだ壁紙の保存(~/.local/state/ame-shell/wallpaper)----

fn statePath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |s| return std.fmt.bufPrint(buf, "{s}/ame-shell/wallpaper", .{s}) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/ame-shell/wallpaper", .{home}) catch null;
}

/// 1 行目: aurora|rain|image、2 行目: 画像のパス
pub fn saveChoice(mode: cfgmod.WallMode, path: []const u8) void {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb) orelse return;
    if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
    const f = std.fs.cwd().createFile(p, .{}) catch return;
    defer f.close();
    f.writer().print("{s}\n{s}\n", .{ @tagName(mode), path }) catch {};
}

const Saved = struct { mode: cfgmod.WallMode, path: []const u8 };

fn loadSaved(buf: []u8) ?Saved {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb) orelse return null;
    const f = std.fs.cwd().openFile(p, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    const m = it.next() orelse return null;
    const path = it.next() orelse "";
    const mode: cfgmod.WallMode = if (std.mem.eql(u8, m, "rain")) .rain else if (std.mem.eql(u8, m, "image")) .image else if (std.mem.eql(u8, m, "video")) .video else if (std.mem.eql(u8, m, "aurora")) .aurora else return null;
    // 画像が消えていたら保存内容は使わない
    if ((mode == .image or mode == .video) and std.fs.cwd().access(path, .{}) == error.FileNotFound) return null;
    return .{ .mode = mode, .path = path };
}
