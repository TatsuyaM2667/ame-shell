// ホーム画面の曲のウィジェット: ロック画面と同じ曲のカード(musiccard.zig)を、デスクトップの四隅のどこかに置く。
//
//   * 窓の下(layer-shell の BOTTOM)に出す。窓を開くと隠れ、デスクトップが見えているときだけ見える
//   * 曲が無いときはサーフェスごと消す(何も描かない・何も動かさない)。再生中だけレコードが回り、
//     液体のビジュアライザーの音を拾う
//   * カードの操作はロック画面と同じ(前へ・再生・次へ・再生位置・音量・消音・ホイールで音量)
//   * カードの何もない所をつかんでドラッグすると動かせる。離すと近い隅へ吸い付き、その隅を覚える
//     ($XDG_STATE_HOME/ame-shell/music-widget)。ame-ctl widget music top-left|top-right|bottom-left|bottom-right|on|off
//   * 設定: music-widget { enabled on / corner bottom-right }
const std = @import("std");
const anim = @import("anim.zig");
const Spring = anim.Spring;
const appmod = @import("app.zig");
const App = appmod.App;
const Output = appmod.Output;
const c = @import("c.zig");
const gfx = @import("gfx.zig");
const theme = @import("theme.zig");
const cfgmod = @import("config.zig");
const Corner = cfgmod.Corner;
const surface = @import("surface.zig");
const Surface = surface.Surface;
const framedata = @import("frame/data.zig");
const musiccard = @import("musiccard.zig");

const log = std.log.scoped(.musicwidget);

/// カードの周りの余白(影がはみ出す分)
const PAD: f32 = 36;

pub const MusicWidget = struct {
    app: *App,
    surf: ?*Surface = null,
    out: ?*Output = null,
    card: musiccard.Card = .{},
    /// 出入り(0 = 消えている / 1 = 出ている)
    show_s: Spring = Spring.init(0, 0.45, 0.85),
    spectrum: framedata.Spectrum,
    corner: Corner = .bottom_right,
    /// ユーザーが消した(ame-ctl widget music off)。設定の enabled とは別
    hidden: bool = false,
    /// 設定の corner(変わったときだけ従う)
    cfg_corner: Corner = .bottom_right,
    // ---- ドラッグで動かす: 置き場所(隅)からのずれ(画面の向きで +x = 右、+y = 下)----
    off_x: f32 = 0,
    off_y: f32 = 0,
    snap_x: Spring = Spring.init(0, 0.35, 0.8),
    snap_y: Spring = Spring.init(0, 0.35, 0.8),
    snapping: bool = false,
    pressed: bool = false,
    moving: bool = false,
    press_gx: f32 = 0,
    press_gy: f32 = 0,
    press_ox: f32 = 0,
    press_oy: f32 = 0,
    /// 最後にコンポジタへ伝えたずれ(ポインタの座標はこの位置のサーフェスが基準)
    applied_x: f32 = 0,
    applied_y: f32 = 0,
    /// サーフェスの大きさ(論理 px)
    w: f32 = 0,
    h: f32 = 0,

    pub fn create(app: *App) !*MusicWidget {
        const self = try app.alloc.create(MusicWidget);
        self.* = .{ .app = app, .spectrum = .{ .app = app } };
        self.spectrum.ctx = self;
        self.spectrum.on_frame = struct {
            fn f(ctx: *anyopaque) void {
                const w: *MusicWidget = @ptrCast(@alignCast(ctx));
                w.schedule();
            }
        }.f;
        self.cfg_corner = app.cfg.music_corner;
        self.corner = loadCorner() orelse app.cfg.music_corner;
        return self;
    }

    fn k(self: *const MusicWidget) f32 {
        return std.math.clamp(self.app.cfg.ui_scale * 0.8, 0.75, 1.4);
    }

    fn wanted(self: *const MusicWidget) bool {
        return self.app.cfg.music_widget and !self.hidden and self.app.media.status != .none;
    }

    /// 曲の情報・再生状態が変わった(dashboard.dataChanged から)
    pub fn update(self: *MusicWidget) void {
        if (self.wanted()) {
            if (self.surf == null) self.open();
            self.show_s.set(1);
        } else self.show_s.set(0);
        self.updateSpectrum();
        self.schedule();
    }

    pub fn schedule(self: *MusicWidget) void {
        if (self.surf) |s| s.schedule();
    }

    fn open(self: *MusicWidget) void {
        const app = self.app;
        const out = app.activeOutput() orelse return;
        const kk = self.k();
        const pw = 400 * kk;
        self.w = @round(pw + PAD * 2);
        self.h = @round(musiccard.Card.height(kk) + PAD * 2);
        self.off_x = 0;
        self.off_y = 0;
        self.snapping = false;
        self.surf = Surface.createLayer(app, .{ .ctx = self, .draw = draw, .pointer = pointer, .configured = configured }, .{
            .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
            .anchor = anchorOf(self.corner),
            .width = @intFromFloat(self.w),
            .height = @intFromFloat(self.h),
            .namespace = "ame-music-widget",
            .output = out.wl,
        }) catch |e| {
            log.warn("ウィジェットを作れません: {}", .{e});
            return;
        };
        self.out = out;
        self.surf.?.output = out;
        self.card.reset(app);
        self.show_s.snap(0);
    }

    fn close(self: *MusicWidget) void {
        self.spectrum.stop();
        if (self.surf) |s| s.destroy();
        self.surf = null;
        self.out = null;
        self.pressed = false;
        self.moving = false;
    }

    /// 消え終わったら破棄(app の reap から。描画中には消さない)
    pub fn reap(self: *MusicWidget) void {
        if (self.surf != null and !self.wanted() and self.show_s.x < 0.01 and !self.show_s.moving()) self.close();
    }

    pub fn outputRemoved(self: *MusicWidget, o: *Output) void {
        if (self.out == o) {
            self.close();
            self.update(); // 残っている出力に出し直す
        }
    }

    /// 設定を読み直した
    pub fn configChanged(self: *MusicWidget, old: *const cfgmod.Config) void {
        const cfg = &self.app.cfg;
        if (old.music_widget == cfg.music_widget and old.music_corner == cfg.music_corner and old.ui_scale == cfg.ui_scale) return;
        if (cfg.music_corner != self.cfg_corner) {
            self.cfg_corner = cfg.music_corner;
            self.setCorner(cfg.music_corner, false);
        }
        // 大きさ(ui_scale)が変わったかもしれないので作り直す
        self.close();
        self.update();
    }

    /// ame-ctl widget music ...
    pub fn command(self: *MusicWidget, arg: []const u8) []const u8 {
        if (std.mem.eql(u8, arg, "off")) {
            self.hidden = true;
        } else if (std.mem.eql(u8, arg, "on")) {
            self.hidden = false;
        } else if (std.mem.eql(u8, arg, "toggle")) {
            self.hidden = !self.hidden;
        } else if (Corner.parse(arg)) |cn| {
            self.hidden = false;
            self.setCorner(cn, true);
        } else if (arg.len != 0 and !std.mem.eql(u8, arg, "status")) {
            return "error: widget music top-left|top-right|bottom-left|bottom-right|on|off|toggle|status";
        }
        self.update();
        return if (self.hidden or !self.app.cfg.music_widget) "off" else self.corner.name();
    }

    /// 隅を変える。いまの見た目の位置から新しい隅へ滑らせる
    fn setCorner(self: *MusicWidget, cn: Corner, save: bool) void {
        if (save) saveCorner(cn);
        if (cn == self.corner) return;
        const s = self.surf orelse {
            self.corner = cn;
            return;
        };
        // いまの左上(画面の座標)を保ったまま、新しい隅からのずれに直す
        const sz = self.areaSize();
        const ax = self.absX(sz[0]);
        const ay = self.absY(sz[1]);
        self.corner = cn;
        self.off_x = ax - self.restX(sz[0]);
        self.off_y = ay - self.restY(sz[1]);
        if (s.layer) |ls| c.zwlr_layer_surface_v1_set_anchor(ls, anchorOf(cn));
        self.startSnap();
    }

    // ---- 置き場所 ----

    fn anchorOf(cn: Corner) u32 {
        const h: u32 = if (cn.left()) c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT else c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
        const v: u32 = if (cn.top()) c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP else c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
        return h | v;
    }

    /// ウィジェットを置ける広さ(出力の論理サイズから、枠・バーの幅を引いたおおよそ)
    fn areaSize(self: *const MusicWidget) [2]f32 {
        const o = self.out orelse return .{ 1920, 1080 };
        const sz = o.logicalSize();
        const ins = self.insets();
        return .{ @as(f32, @floatFromInt(sz[0])) - ins[0] - ins[2], @as(f32, @floatFromInt(sz[1])) - ins[1] - ins[3] };
    }

    /// 枠(caelestia)の左・上・右・下の幅。ガラスの背景を正しい場所から取るため
    fn insets(self: *const MusicWidget) [4]f32 {
        const o = self.out orelse return .{ 0, 0, 0, 0 };
        const f = o.frame orelse return .{ 0, 0, 0, 0 };
        const s = self.app.cfg.ui_scale;
        return .{ f.BW() * s, f.T() * s, f.T() * s, f.T() * s };
    }

    fn restX(self: *const MusicWidget, aw: f32) f32 {
        return if (self.corner.left()) 0 else aw - self.w;
    }
    fn restY(self: *const MusicWidget, ah: f32) f32 {
        return if (self.corner.top()) 0 else ah - self.h;
    }
    fn absX(self: *const MusicWidget, aw: f32) f32 {
        return self.restX(aw) + self.off_x;
    }
    fn absY(self: *const MusicWidget, ah: f32) f32 {
        return self.restY(ah) + self.off_y;
    }

    /// ずれを余白(margin)にしてコンポジタへ伝える(次のコミットで動く)
    fn applyMargins(self: *MusicWidget, s: *Surface) void {
        const ls = s.layer orelse return;
        const ox: i32 = @intFromFloat(@round(self.off_x));
        const oy: i32 = @intFromFloat(@round(self.off_y));
        // 上・右・下・左
        const top: i32 = if (self.corner.top()) oy else 0;
        const bottom: i32 = if (self.corner.top()) 0 else -oy;
        const left: i32 = if (self.corner.left()) ox else 0;
        const right: i32 = if (self.corner.left()) 0 else -ox;
        c.zwlr_layer_surface_v1_set_margin(ls, top, right, bottom, left);
        self.applied_x = @floatFromInt(ox);
        self.applied_y = @floatFromInt(oy);
        const sz = self.areaSize();
        const ins = self.insets();
        s.origin = .{ ins[0] + self.absX(sz[0]), ins[1] + self.absY(sz[1]) };
    }

    fn startSnap(self: *MusicWidget) void {
        self.snap_x.snap(self.off_x);
        self.snap_y.snap(self.off_y);
        self.snap_x.set(0);
        self.snap_y.set(0);
        self.snapping = true;
        self.schedule();
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        const self: *MusicWidget = @ptrCast(@alignCast(ctx));
        self.applyMargins(s);
    }

    // ---- 音(液体のビジュアライザー)----

    fn updateSpectrum(self: *MusicWidget) void {
        const want = self.surf != null and self.wanted() and self.app.media.status == .playing and !self.app.lock.locked;
        if (want and !self.spectrum.running()) self.spectrum.start();
        if (!want and self.spectrum.running()) self.spectrum.stop();
    }

    // ---- 描画 ----

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *MusicWidget = @ptrCast(@alignCast(ctx));
        const app = self.app;
        var animating = false;
        if (self.snapping) {
            var sp = [_]*Spring{ &self.snap_x, &self.snap_y };
            self.snapping = anim.stepAll(&sp, dt);
            self.off_x = self.snap_x.x;
            self.off_y = self.snap_y.x;
            if (self.snapping) animating = true;
        }
        self.applyMargins(s);
        if (self.show_s.step(dt)) animating = true;
        const e = self.show_s.x;
        if (!self.wanted() and e < 0.01) {
            app.reap_pending = true;
            return false;
        }
        // 曲が無い間に消えていく途中でも、最後に見えていたカードを描く
        if (app.media.status != .none and self.card.step(app, dt)) animating = true;
        const kk = self.k();
        const pw = self.w - PAD * 2;
        const ch = musiccard.Card.height(kk);
        cv.save();
        cv.opacity(e);
        cv.scaleAbout(PAD + pw / 2, PAD + ch / 2, 0.92 + 0.08 * e);
        // 持ち上げている間は少し大きく
        if (self.moving) cv.scaleAbout(PAD + pw / 2, PAD + ch / 2, 1.03);
        self.card.draw(app, cv, PAD, PAD, pw, kk, theme.accent(app), if (self.spectrum.running()) &self.spectrum.values else null);
        cv.restore();
        // クリックはカードの上だけ(影の所は下の壁紙へ通す)
        s.setInputRect(@intFromFloat(PAD), @intFromFloat(PAD), @intFromFloat(pw), @intFromFloat(ch));
        return animating or self.show_s.moving();
    }

    // ---- 操作 ----

    fn pointer(ctx: *anyopaque, s: *Surface, ev: surface.PointerEvent) void {
        const self: *MusicWidget = @ptrCast(@alignCast(ctx));
        // 動かしている最中はカードの操作より優先
        if (self.pressed) {
            // 画面の上での指の位置 = 自分の置き場所 + サーフェスの中の位置
            const gx = self.applied_x + ev.x;
            const gy = self.applied_y + ev.y;
            switch (ev.kind) {
                .motion => {
                    if (!self.moving and @abs(gx - self.press_gx) + @abs(gy - self.press_gy) > 6) self.moving = true;
                    if (self.moving) {
                        const sz = self.areaSize();
                        const nx = self.press_ox + (gx - self.press_gx);
                        const ny = self.press_oy + (gy - self.press_gy);
                        // 画面の外へは出さない
                        self.off_x = std.math.clamp(nx, -self.restX(sz[0]), sz[0] - self.w - self.restX(sz[0]));
                        self.off_y = std.math.clamp(ny, -self.restY(sz[1]), sz[1] - self.h - self.restY(sz[1]));
                        s.schedule();
                    }
                },
                .release, .leave => {
                    self.pressed = false;
                    if (self.moving) {
                        self.moving = false;
                        // カードの中心がある側の隅へ
                        const sz = self.areaSize();
                        const cx = self.absX(sz[0]) + self.w / 2;
                        const cy = self.absY(sz[1]) + self.h / 2;
                        const cn = Corner.of(cx < sz[0] / 2, cy < sz[1] / 2);
                        if (cn == self.corner) {
                            self.startSnap();
                        } else self.setCorner(cn, true);
                        saveCorner(cn);
                    }
                    s.schedule();
                },
                else => {},
            }
            return;
        }
        if (self.card.pointer(self.app, ev)) {
            s.schedule();
            return;
        }
        if (ev.kind == .press and ev.button == 0x110 and musiccard.inRectPad(self.card.hits.card, ev.x, ev.y, 0)) {
            self.pressed = true;
            self.moving = false;
            self.snapping = false;
            self.press_gx = self.applied_x + ev.x;
            self.press_gy = self.applied_y + ev.y;
            self.press_ox = self.off_x;
            self.press_oy = self.off_y;
        }
    }
};

// ---- 覚えた隅 ----

fn statePath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |s| if (s.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell/music-widget", .{s}) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/ame-shell/music-widget", .{home}) catch null;
}

fn loadCorner() ?Corner {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb) orelse return null;
    var buf: [32]u8 = undefined;
    const d = std.fs.cwd().readFile(p, &buf) catch return null;
    return Corner.parse(std.mem.trim(u8, d, " \t\r\n"));
}

fn saveCorner(cn: Corner) void {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb) orelse return;
    if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
    std.fs.cwd().writeFile(.{ .sub_path = p, .data = cn.name() }) catch {};
}
