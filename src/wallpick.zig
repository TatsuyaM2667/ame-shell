// 壁紙ピッカー(ilyamiro の serpantinum を参考に再設計。コードは使っていない)。
//
// 全画面のオーバーレイに、斜め(平行四辺形)のカードを横一列に並べる。選択中のカードだけが
// スプリングで大きく広がり、ほかは細い短冊になって暗くなる。カードの中の画像は横位置に応じて
// 少しずれる(パララックス)。開くときはカードが下から時間差で飛び上がり、閉じるときは沈む。
// 決定すると、そのカードの位置を起点に壁紙が切り替わる(wallpaper.zig の円/斜めワイプ/短冊)。
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
const wallpaper = @import("wallpaper.zig");

const SKEW: f32 = -0.35;
const MAX_CARDS = 128;

pub const WallPick = struct {
    app: *App,
    surf: ?*Surface = null,
    out: ?*Output = null,
    is_open: bool = false,
    sel: usize = 0,
    hover: ?usize = null,
    open_s: Spring = Spring.init(0, 0.5, 0.82),
    scroll: Spring = Spring.init(0, 0.42, 0.86),
    wide: [MAX_CARDS]Spring = [_]Spring{Spring.init(0, 0.38, 0.78)} ** MAX_CARDS,
    appear: [MAX_CARDS]Spring = [_]Spring{Spring.init(0, 0.55, 0.72)} ** MAX_CARDS,
    /// カードの当たり判定用(最後に描いた中心 x と幅)
    card_x: [MAX_CARDS]f32 = undefined,
    card_w: [MAX_CARDS]f32 = undefined,
    card_y: f32 = 0,
    card_h: f32 = 0,
    live_tex: [2]c.GLuint = .{ 0, 0 },

    pub fn create(app: *App) !*WallPick {
        const self = try app.alloc.create(WallPick);
        self.* = .{ .app = app };
        return self;
    }

    fn count(self: *WallPick) usize {
        return @min(self.app.launcher.walls.items.len, MAX_CARDS);
    }

    pub fn toggle(self: *WallPick) void {
        if (self.is_open) self.close() else self.open();
    }

    pub fn open(self: *WallPick) void {
        if (self.is_open) return;
        const app = self.app;
        app.launcher.ensureScanned();
        if (self.count() == 0) return;
        if (self.surf == null) {
            const out = app.activeOutput() orelse return;
            self.out = out;
            const all = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
            self.surf = Surface.createLayer(app, .{ .ctx = self, .draw = draw, .pointer = pointer, .key = key, .configured = configured }, .{
                .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
                .anchor = @intCast(all),
                .exclusive = -1,
                .keyboard = c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE,
                .namespace = "ame-wallpaper-picker",
                .output = out.wl,
            }) catch return;
            self.surf.?.output = out;
        }
        self.is_open = true;
        // いま使っている壁紙を最初に選ぶ
        self.sel = self.currentIndex();
        self.scroll.snap(@floatFromInt(self.sel));
        for (0..self.count()) |i| {
            self.wide[i].snap(if (i == self.sel) 1 else 0);
            self.appear[i].snap(0);
        }
        self.open_s.snap(0);
        self.open_s.set(1);
        self.surf.?.schedule();
    }

    fn currentIndex(self: *WallPick) usize {
        const o = self.app.activeOutput() orelse return 0;
        const w = o.wall orelse return 0;
        for (self.app.launcher.walls.items[0..self.count()], 0..) |wl, i| {
            if (wl.mode != w.mode) continue;
            if (wl.mode != .image) return i;
            if (std.mem.eql(u8, wl.path, w.img_path[0..w.img_path_len])) return i;
        }
        return 0;
    }

    pub fn close(self: *WallPick) void {
        if (!self.is_open) return;
        self.is_open = false;
        self.open_s.set(0);
        if (self.surf) |s| {
            if (s.layer) |l| c.zwlr_layer_surface_v1_set_keyboard_interactivity(l, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
            s.setInputRect(0, 0, 0, 0);
            s.schedule();
        }
    }

    pub fn reap(self: *WallPick) void {
        if (!self.is_open and self.open_s.x < 0.01 and self.surf != null) {
            self.surf.?.destroy();
            self.surf = null;
            self.out = null;
        }
    }

    pub fn outputRemoved(self: *WallPick, o: *Output) void {
        if (self.out == o) {
            if (self.surf) |s| s.destroy();
            self.surf = null;
            self.out = null;
            self.is_open = false;
        }
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        _ = ctx;
        s.origin = .{ 0, 0 };
    }

    fn select(self: *WallPick, i: usize) void {
        self.sel = i;
        self.scroll.set(@floatFromInt(i));
        if (self.surf) |s| s.schedule();
    }

    fn apply(self: *WallPick) void {
        const app = self.app;
        const wl = app.launcher.walls.items[self.sel];
        // 選んだカードの中心から切り替える
        const W: f32 = if (self.surf) |s| @floatFromInt(s.width) else 1;
        const H: f32 = if (self.surf) |s| @floatFromInt(s.height) else 1;
        const origin = [2]f32{ self.card_x[self.sel] / W, (self.card_y + self.card_h / 2) / H };
        for (app.outputs.items) |o| if (o.wall) |w| w.switchFx(wl.mode, wl.path, app.cfg.wall_transition, origin);
        wallpaper.saveChoice(wl.mode, wl.path);
        self.close();
    }

    fn key(ctx: *anyopaque, s: *Surface, ev: surface.KeyEvent) void {
        const self: *WallPick = @ptrCast(@alignCast(ctx));
        if (!self.is_open) return;
        const n = self.count();
        switch (ev.sym) {
            c.XKB_KEY_Escape, c.XKB_KEY_q => self.close(),
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_space => self.apply(),
            c.XKB_KEY_Right, c.XKB_KEY_l, c.XKB_KEY_Tab, c.XKB_KEY_Down => if (self.sel + 1 < n) self.select(self.sel + 1),
            c.XKB_KEY_Left, c.XKB_KEY_h, c.XKB_KEY_ISO_Left_Tab, c.XKB_KEY_Up => if (self.sel > 0) self.select(self.sel - 1),
            c.XKB_KEY_Home => self.select(0),
            c.XKB_KEY_End => self.select(n - 1),
            else => {},
        }
        s.schedule();
    }

    fn cardAt(self: *WallPick, x: f32, y: f32) ?usize {
        if (y < self.card_y or y > self.card_y + self.card_h) return null;
        // 斜めなので、高さに応じて x をずらしてから判定する
        const dy = y - (self.card_y + self.card_h / 2);
        for (0..self.count()) |i| {
            const cx = self.card_x[i] + SKEW * dy;
            if (@abs(x - cx) <= self.card_w[i] / 2) return i;
        }
        return null;
    }

    fn pointer(ctx: *anyopaque, s: *Surface, ev: surface.PointerEvent) void {
        const self: *WallPick = @ptrCast(@alignCast(ctx));
        if (!self.is_open) return;
        const hit = if (ev.kind == .leave) null else self.cardAt(ev.x, ev.y);
        if (hit != self.hover) {
            self.hover = hit;
            s.schedule();
        }
        switch (ev.kind) {
            .press => {
                if (hit) |i| {
                    if (i == self.sel) self.apply() else self.select(i);
                } else if (ev.button == 0x111) self.close(); // 右クリックで閉じる
            },
            .scroll => {
                const n = self.count();
                if (ev.scroll > 0 and self.sel + 1 < n) self.select(self.sel + 1);
                if (ev.scroll < 0 and self.sel > 0) self.select(self.sel - 1);
            },
            else => {},
        }
    }

    /// ライブ壁紙(画像の無いカード)用の小さなテクスチャを作る
    fn liveTex(self: *WallPick, which: usize) c.GLuint {
        if (self.live_tex[which] != 0) return self.live_tex[which];
        const W = 96;
        const H = 60;
        var px: [W * H * 4]u8 = undefined;
        const a = Color.hex(self.app.cfg.aurora_a);
        const b = Color.hex(self.app.cfg.aurora_b);
        const cc = Color.hex(self.app.cfg.aurora_c);
        for (0..H) |y| for (0..W) |x| {
            const fy = @as(f32, @floatFromInt(y)) / H;
            const fx = @as(f32, @floatFromInt(x)) / W;
            var col: Color = undefined;
            if (which == 0) {
                // オーロラ: 紺の空に緑→青→紫の帯
                const band = @exp(-std.math.pow(f32, (fy - 0.45 - 0.08 * @sin(fx * 6)) / 0.16, 2));
                col = Color.mix(Color.hex(0x050a1c), Color.mix(a, Color.mix(b, cc, fx), fy * 1.5), band * 0.9);
            } else {
                // 雨: 夜の街の青いグラデーションと縦の筋
                col = Color.mix(Color.hex(0x1b2a55), Color.hex(0x060914), fy);
                if ((x * 7 + y * 3) % 23 == 0) col = col.lighten(0.25);
            }
            const i = (y * W + x) * 4;
            px[i] = @intFromFloat(std.math.clamp(col.r, 0, 1) * 255);
            px[i + 1] = @intFromFloat(std.math.clamp(col.g, 0, 1) * 255);
            px[i + 2] = @intFromFloat(std.math.clamp(col.b, 0, 1) * 255);
            px[i + 3] = 255;
        };
        self.live_tex[which] = gfx.uploadImage(&px, W, H);
        return self.live_tex[which];
    }

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *WallPick = @ptrCast(@alignCast(ctx));
        const app = self.app;
        const n = self.count();
        var animating = false;
        if (self.open_s.step(dt)) animating = true;
        if (self.scroll.step(dt)) animating = true;
        // 開くとき: 選択中のカードから外側へ順に飛び上がる / 閉じるとき: 一斉に沈む
        for (0..n) |i| {
            self.wide[i].set(if (i == self.sel) 1 else 0);
            const dist: f32 = @floatFromInt(if (i > self.sel) i - self.sel else self.sel - i);
            if (self.is_open) {
                if (self.open_s.x > 0.08 * dist) self.appear[i].set(1);
            } else self.appear[i].set(0);
            if (self.wide[i].step(dt)) animating = true;
            if (self.appear[i].step(dt)) animating = true;
        }
        if (!self.is_open and self.open_s.x < 0.01 and !self.open_s.moving()) {
            app.reap_pending = true;
            return false;
        }

        const W: f32 = @floatFromInt(s.width);
        const H: f32 = @floatFromInt(s.height);
        const t = std.math.clamp(self.open_s.x, 0, 1);
        const acc = theme.accent(app);
        const txt = theme.text(app);
        const sub = theme.subtext(app);

        // 背景: 壁紙のブラーを暗く敷く
        var gl = theme.glass(app);
        gl.tint = Color.hex(0x02040a);
        gl.tint.a = 0.55;
        gl.rim.a = 0;
        gl.refraction = 0;
        cv.save();
        cv.opacity(t);
        cv.glass(0, 0, W, H, 0, gl);
        cv.restore();

        // カードの寸法
        const ch = @min(H * 0.52, 560);
        const narrow = ch * 0.30;
        const wide_w = ch * 1.55;
        const gap: f32 = 10;
        const cy = H / 2 - ch / 2 + 10;
        self.card_y = cy;
        self.card_h = ch;
        // 各カードの幅(スプリング)を積み上げて中心位置を求め、scroll の位置が画面中央に来るようにずらす
        var centers: [MAX_CARDS]f32 = undefined;
        var x: f32 = 0;
        for (0..n) |i| {
            const w = narrow + (wide_w - narrow) * self.wide[i].x;
            self.card_w[i] = w;
            centers[i] = x + w / 2;
            x += w + gap;
        }
        const si = std.math.clamp(self.scroll.x, 0, @as(f32, @floatFromInt(n - 1)));
        const ia: usize = @intFromFloat(@floor(si));
        const ib = @min(ia + 1, n - 1);
        const f = si - @as(f32, @floatFromInt(ia));
        const focus = centers[ia] + (centers[ib] - centers[ia]) * f;
        const shift = W / 2 - focus;

        // 選択中のカードの光(後ろ)
        for (0..n) |i| {
            const cxp = centers[i] + shift;
            self.card_x[i] = cxp;
            const w = self.card_w[i];
            const bb = w + @abs(SKEW) * ch;
            if (cxp + bb / 2 < -50 or cxp - bb / 2 > W + 50) continue;
            const ap = self.appear[i].x;
            const y = cy + (1 - ap) * (H * 0.6);
            const wl = &app.launcher.walls.items[i];
            const tex = if (wl.mode == .image) app.launcher.wallTex(i) else self.liveTex(if (wl.mode == .aurora) 0 else 1);
            const wd = self.wide[i].x;
            const hv: f32 = if (self.hover == i) 1 else 0;
            // 画像の見せる範囲: 縦横比を保って枠を埋める + 横位置に応じたパララックス
            const img_aspect: f32 = 1.6;
            const box_aspect = bb / ch;
            var uv = [4]f32{ 0, 0, 1, 1 };
            if (box_aspect < img_aspect) {
                const span = box_aspect / img_aspect;
                const par = std.math.clamp((cxp - W / 2) / W * 0.35, -(1 - span) / 2, (1 - span) / 2);
                uv[0] = 0.5 - span / 2 + par;
                uv[2] = 0.5 + span / 2 + par;
            } else {
                const span = img_aspect / box_aspect;
                uv[1] = 0.5 - span / 2;
                uv[3] = 0.5 + span / 2;
            }
            cv.save();
            cv.opacity(ap * t);
            if (wd > 0.05) cv.shadow(cxp - w / 2, y + 16, w, ch, 18, 30 * wd, acc.alpha(0.35 * wd));
            const bright = 0.42 + 0.58 * wd + 0.15 * hv;
            if (tex != 0) {
                cv.skewImage(tex, cxp - bb / 2, y, bb, ch, 16, SKEW, uv, @min(bright, 1), 2.5 * wd + 1.2 * hv, acc.lighten(0.3).alpha(@max(wd, hv * 0.6)));
            } else {
                // サムネイル待ち
                cv.rect(cxp - w / 2, y, w, ch, 16, Color.hex(0xffffff).alpha(0.06));
            }
            if (wl.mode != .image and wd > 0.3) {
                _ = cv.text(cxp, y + ch / 2 + 16, 44 * wd, Color.hex(0xffffff).alpha(0.85 * wd), if (wl.mode == .rain) "\u{F0597}" else "\u{F0E09}", .{ .alignment = .center });
            }
            cv.restore();
        }

        // 選択中の名前と位置
        cv.save();
        cv.opacity(t);
        const wl = app.launcher.walls.items[self.sel];
        const ny = cy + ch + 56;
        _ = cv.text(W / 2, ny, 22, txt, wl.name, .{ .bold = true, .alignment = .center, .max_w = W * 0.6, .glow = 4, .glow_color = acc.alpha(0.4) });
        var buf: [32]u8 = undefined;
        _ = cv.text(W / 2, ny + 28, 13, sub, std.fmt.bufPrint(&buf, "{d} / {d}", .{ self.sel + 1, n }) catch "", .{ .alignment = .center });
        _ = cv.text(W / 2, cy - 40, 30, txt, "壁紙", .{ .bold = true, .alignment = .center });
        _ = cv.text(W / 2, H - 36, 13, sub, "← → / ホイールで選択   Enter・クリックで適用   Esc で閉じる", .{ .alignment = .center });
        cv.restore();

        if (self.is_open) s.setInputRect(0, 0, @intFromFloat(W), @intFromFloat(H));
        return animating or theme.accentAnimating();
    }
};
