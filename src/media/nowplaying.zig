// ホーム画面の「再生中」を広げる(曲のウィジェットのジャケットを押したとき)。ロック画面と同じ見せ方:
// 小さなジャケットが真ん中へ大きくなり、背景はジャケットを大きくぼかした色。下に曲名・再生位置・
// 前/再生/次・音量。もう一度ジャケット・ほかの所を押す・Esc で戻る(スペースで再生/一時停止)。
// 全面の OVERLAY のサーフェスを、開いている間だけ出す(閉じ終わったら消す)。
const std = @import("std");
const anim = @import("../gfx/anim.zig");
const Spring = anim.Spring;
const appmod = @import("../core/app.zig");
const App = appmod.App;
const Output = appmod.Output;
const c = @import("../c.zig");
const gfx = @import("../gfx/gfx.zig");
const theme = @import("../gfx/theme.zig");
const surface = @import("../core/surface.zig");
const Surface = surface.Surface;
const musiccard = @import("musiccard.zig");

pub const NowPlaying = struct {
    app: *App,
    surf: ?*Surface = null,
    out: ?*Output = null,
    /// 操作(再生位置・音量のつまみ)の状態はこちらで持つ(ウィジェットのカードとは別)
    card: musiccard.Card = .{},
    np: Spring = Spring.init(0, 0.46, 0.84),
    is_open: bool = false,
    /// 小さなジャケットの場所(出力の論理座標)。そこから大きくなり、そこへ戻る
    from: [4]f32 = .{ 0, 0, 0, 0 },
    time_s: f32 = 0,

    pub fn create(app: *App) !*NowPlaying {
        const self = try app.alloc.create(NowPlaying);
        self.* = .{ .app = app };
        return self;
    }

    pub fn isOpen(self: *const NowPlaying) bool {
        return self.is_open;
    }

    /// ウィジェットのジャケットを押した(musicwidget.zig)。from は出力の論理座標
    pub fn open(self: *NowPlaying, out: *Output, from: [4]f32) void {
        const app = self.app;
        if (app.media.status == .none or app.lock.locked) return;
        if (self.surf != null and self.out != out) self.destroySurface();
        self.from = from;
        if (self.surf == null) {
            const all = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
            self.surf = Surface.createLayer(app, .{ .ctx = self, .draw = draw, .pointer = pointer, .key = key }, .{
                .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
                .anchor = @intCast(all),
                .exclusive = -1,
                .keyboard = c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
                .namespace = "ame-now-playing",
                .output = out.wl,
            }) catch return;
            self.out = out;
            self.surf.?.output = out;
            self.np.snap(0);
            self.card.reset(app);
        }
        self.is_open = true;
        self.np.set(1);
        self.surf.?.schedule();
    }

    pub fn close(self: *NowPlaying) void {
        if (!self.is_open) return;
        self.is_open = false;
        self.np.set(0);
        if (self.surf) |s| {
            // 閉じていく間はキーを手放す(下の窓へすぐ戻す)
            if (s.layer) |l| c.zwlr_layer_surface_v1_set_keyboard_interactivity(l, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
            s.setInputRect(0, 0, 0, 0);
            s.schedule();
        }
    }

    fn destroySurface(self: *NowPlaying) void {
        if (self.surf) |s| s.destroy();
        self.surf = null;
        self.out = null;
        self.is_open = false;
    }

    /// 閉じ終わったら消す(app の reap から)
    pub fn reap(self: *NowPlaying) void {
        if (self.surf != null and !self.is_open and self.np.x < 0.01 and !self.np.moving()) self.destroySurface();
    }

    pub fn outputRemoved(self: *NowPlaying, o: *Output) void {
        if (self.out == o) self.destroySurface();
    }

    /// 曲が無くなった・ロックした(dashboard.dataChanged / lock から)
    pub fn update(self: *NowPlaying) void {
        if (self.is_open and (self.app.media.status == .none or self.app.lock.locked)) self.close();
        if (self.surf) |s| s.schedule();
    }

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *NowPlaying = @ptrCast(@alignCast(ctx));
        const app = self.app;
        self.time_s += dt;
        _ = self.np.step(dt);
        if (!self.is_open and self.np.x < 0.01 and !self.np.moving()) {
            app.reap_pending = true;
            return false;
        }
        if (app.media.status != .none) _ = self.card.step(app, dt);
        const W: f32 = @floatFromInt(s.width);
        const H: f32 = @floatFromInt(s.height);
        const acc = theme.accent(app);
        const vis = std.math.clamp(self.np.x, 0, 1);
        musiccard.drawNowPlayingBackdrop(app, cv, W, H, vis, self.time_s, acc);
        if (app.media.status != .none) {
            self.card.drawNowPlaying(app, cv, W, H, @max(H * 0.1, 48), self.np.x, vis, self.from, self.is_open, acc);
        }
        // 開いている間は背景の色が流れ続けるので描き続ける(閉じ終わったら上で止まる)
        return true;
    }

    fn pointer(ctx: *anyopaque, s: *Surface, ev: surface.PointerEvent) void {
        const self: *NowPlaying = @ptrCast(@alignCast(ctx));
        if (!self.is_open) return;
        // 大きなジャケットを押す: 閉じる
        if (ev.kind == .press and ev.button == 0x110 and musiccard.inRectPad(self.card.hits.art, ev.x, ev.y, 0)) {
            self.close();
            return;
        }
        if (self.card.pointer(self.app, ev)) {
            s.schedule();
            return;
        }
        // ほかの所を押す: 閉じる
        if (ev.kind == .press) self.close();
    }

    fn key(ctx: *anyopaque, _: *Surface, ev: surface.KeyEvent) void {
        const self: *NowPlaying = @ptrCast(@alignCast(ctx));
        switch (ev.sym) {
            c.XKB_KEY_Escape => self.close(),
            c.XKB_KEY_space => self.app.media.toggle(),
            c.XKB_KEY_Left => self.app.media.prev(),
            c.XKB_KEY_Right => self.app.media.next(),
            else => {},
        }
        if (self.surf) |s| s.schedule();
    }
};
