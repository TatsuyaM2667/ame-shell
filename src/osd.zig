// OSD: 音量・明るさの変更時に画面下部中央へ浮かぶガラスのピル。
// 出現はスプリングで下からポップ、値のバーもスプリングで追従、一定時間で沈んで消える。
// サーフェスは表示中だけ作り、消えたら破棄する(常駐させると無駄に合成コストがかかるため)。
const std = @import("std");
const c = @import("c.zig");
const anim = @import("anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("gfx.zig");
const theme = @import("theme.zig");
const appmod = @import("app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("surface.zig");
const Surface = surface.Surface;
const loop = @import("platform/loop.zig");

pub const Kind = enum { volume, brightness, info };

const W: u32 = 360;
const H: u32 = 120;

pub const Osd = struct {
    app: *App,
    surf: ?*Surface = null,
    out: ?*Output = null,
    kind: Kind = .volume,
    show_s: Spring = Spring.init(0, 0.42, 0.68),
    value: Spring = Spring.init(0, 0.28, 0.9),
    hide_timer: loop.Timer,
    visible: bool = false,
    msg: [128]u8 = undefined,
    msg_len: usize = 0,

    pub fn create(app: *App) !*Osd {
        const self = try app.alloc.create(Osd);
        self.* = .{ .app = app, .hide_timer = try loop.Timer.init() };
        try app.loop.add(self.hide_timer.fd, c.EPOLLIN, self, onHide);
        return self;
    }

    /// 文字だけの通知(ロック不可の警告など)
    pub fn info(self: *Osd, msg: []const u8) void {
        self.msg_len = @min(msg.len, self.msg.len);
        @memcpy(self.msg[0..self.msg_len], msg[0..self.msg_len]);
        self.showKind(.info, 0);
    }

    pub fn show(self: *Osd, kind: Kind) void {
        const v: f32 = switch (kind) {
            .volume => if (self.app.sys.volume.muted) 0 else self.app.sys.volume.level,
            .brightness => self.app.sys.brightness orelse 0,
            .info => 0,
        };
        self.showKind(kind, v);
    }

    fn showKind(self: *Osd, kind: Kind, v: f32) void {
        const app = self.app;
        if (self.surf == null) {
            const out = app.activeOutput() orelse return;
            self.out = out;
            self.surf = Surface.createLayer(app, .{ .ctx = self, .draw = draw, .configured = configured }, .{
                .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
                .anchor = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM,
                .width = W,
                .height = H,
                .margin = .{ 0, 0, 40, 0 },
                .namespace = "ame-osd",
                .output = out.wl,
            }) catch return;
            self.surf.?.output = out;
            self.surf.?.setInputRect(0, 0, 0, 0); // クリックを透過
            self.value.snap(v);
            self.show_s.snap(0);
        }
        if (self.kind != kind) self.value.snap(v);
        self.kind = kind;
        self.value.set(v);
        self.show_s.set(1);
        self.visible = true;
        self.hide_timer.arm(if (kind == .info) 2600 else 1400, 0);
        self.surf.?.schedule();
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        const self: *Osd = @ptrCast(@alignCast(ctx));
        const o = self.out orelse return;
        const sz = o.logicalSize();
        s.origin = .{ (@as(f32, @floatFromInt(sz[0])) - W) / 2, @as(f32, @floatFromInt(sz[1])) - 40 - H };
    }

    fn onHide(ctx: *anyopaque, _: c_int, _: u32) void {
        const self: *Osd = @ptrCast(@alignCast(ctx));
        self.hide_timer.ack();
        self.show_s.set(0);
        self.visible = false;
        if (self.surf) |s| s.schedule();
    }

    pub fn backdropChanged(self: *Osd) void {
        if (self.surf) |s| s.schedule();
    }

    pub fn outputRemoved(self: *Osd, o: *Output) void {
        if (self.out == o) self.destroySurface();
    }

    fn destroySurface(self: *Osd) void {
        if (self.surf) |s| s.destroy();
        self.surf = null;
        self.out = null;
    }

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *Osd = @ptrCast(@alignCast(ctx));
        _ = s;
        const app = self.app;
        var springs = [_]*Spring{ &self.show_s, &self.value };
        const moving = anim.stepAll(&springs, dt);
        const t = self.show_s.x;
        if (!self.visible and !moving and t < 0.01) {
            // 沈み終わったら破棄(描画中に消すと危ないので次のループで)
            app.reap_pending = true;
            return false;
        }
        const acc = theme.accent(app);
        const txt = theme.text(app);
        const pw: f32 = 300;
        const ph: f32 = 56;
        const x = (@as(f32, W) - pw) / 2;
        const y = @as(f32, H) - ph - 20;
        cv.save();
        // 下からポップ: 位置・拡大・不透明度を同じスプリングで
        cv.translate(0, (1 - t) * 40);
        cv.scaleAbout(@as(f32, W) / 2, y + ph / 2, 0.85 + 0.15 * t);
        cv.opacity(std.math.clamp(t * 1.5, 0, 1));
        cv.shadow(x, y + 6, pw, ph, ph / 2, 18, theme.shadow());
        cv.glass(x, y, pw, ph, ph / 2, theme.glassStrong(app));

        if (self.kind == .info) {
            _ = cv.text(@as(f32, W) / 2, y + ph / 2 + 6, 16, txt, self.msg[0..self.msg_len], .{ .alignment = .center, .max_w = pw - 30 });
        } else {
            const icon: []const u8 = switch (self.kind) {
                .volume => if (app.sys.volume.muted) "\u{F075F}" else "\u{F057E}",
                else => "\u{F00E0}",
            };
            _ = cv.text(x + 22, y + ph / 2 + 9, 24, acc, icon, .{ .glow = 5, .glow_color = acc.alpha(0.5) });
            const bx = x + 64;
            const bw = pw - 64 - 70;
            const bh: f32 = 10;
            const by = y + ph / 2 - bh / 2;
            const v = std.math.clamp(self.value.x, 0, 1);
            cv.rect(bx, by, bw, bh, bh / 2, Color.hex(0xffffff).alpha(0.12));
            cv.shadow(bx, by, bw * v, bh, bh / 2, 8, acc.alpha(0.5));
            cv.rectGrad(bx, by, @max(bw * v, bh), bh, bh / 2, acc.lighten(0.3), acc);
            var buf: [8]u8 = undefined;
            const pct = std.fmt.bufPrint(&buf, "{d}", .{@as(u32, @intFromFloat(@round(self.value.target * 100)))}) catch "";
            _ = cv.text(x + pw - 24, y + ph / 2 + 7, 19, txt, pct, .{ .bold = true, .alignment = .right });
        }
        cv.restore();
        return moving or theme.accentAnimating();
    }

    /// メインループから呼ばれる遅延破棄
    pub fn reap(self: *Osd) void {
        if (!self.visible and self.show_s.x < 0.01) self.destroySurface();
    }
};
