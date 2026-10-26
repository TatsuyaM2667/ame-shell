// バー: 画面上端に浮かぶガラスの「島」を3つ並べる。
//   左: ロゴ + ワークスペース(River のタグ 1..9)。選択インジケータは2本のスプリング
//       (先頭は速く、後尾は遅く)で両端を動かし、移動中は伸びて液体のように見える。
//   中: フォーカス中のウィンドウタイトル(変化時に上下へクロスフェード)
//   右: ネットワーク / 音量 / バッテリー / 時計
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
const sys = @import("platform/sys.zig");

const TAGS = 9;
const SLOT: f32 = 28;

const Hit = enum(u8) { none, logo, tag, title, net, volume, battery, clock };
const HitBox = struct { kind: Hit, idx: u8 = 0, x: f32, w: f32 };

pub const Bar = struct {
    app: *App,
    out: *Output,
    surf: *Surface,
    // アニメーション
    enter: Spring = Spring.init(0, 0.55, 0.78), // 起動時に上からすべり込む
    lead: Spring = Spring.init(0, 0.20, 0.72),
    trail: Spring = Spring.init(0, 0.42, 0.92),
    squish: Spring = Spring.init(0, 0.25, 0.5), // クリック時の弾み
    title_t: Spring = Spring.init(1, 0.38, 1.0),
    hover: [24]Spring = [_]Spring{Spring.init(0, 0.22, 1.0)} ** 24,
    occupied: [TAGS]Spring = [_]Spring{Spring.init(0, 0.3, 0.8)} ** TAGS,
    width_l: Spring = Spring.init(0, 0.40, 0.85),
    width_r: Spring = Spring.init(0, 0.40, 0.85),
    width_c: Spring = Spring.init(0, 0.40, 0.85),
    prev_title: [256]u8 = undefined,
    prev_title_len: usize = 0,
    cur_title: [256]u8 = undefined,
    cur_title_len: usize = 0,
    hits: [32]HitBox = undefined,
    n_hits: usize = 0,
    hover_idx: ?usize = null,
    first: bool = true,

    pub fn create(app: *App, out: *Output) !*Bar {
        const self = try app.alloc.create(Bar);
        self.* = .{ .app = app, .out = out, .surf = undefined };
        const t = app.cfg.bar_position == .top;
        const anchor: u32 = @intCast(c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
            (if (t) c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP else c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM));
        self.surf = try Surface.createLayer(app, .{
            .ctx = self,
            .draw = draw,
            .pointer = pointer,
            .configured = configured,
        }, .{
            .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            .anchor = anchor,
            .height = self.surfHeight(),
            .exclusive = @intFromFloat(app.cfg.bar_height + app.cfg.bar_margin),
            .namespace = "ame-bar",
            .output = out.wl,
        });
        self.surf.output = out;
        const tl = app.focused_title.get();
        self.setCur(tl);
        self.lead.snap(self.focusedIndex());
        self.trail.snap(self.focusedIndex());
        self.enter.snap(0);
        self.enter.set(1);
        return self;
    }

    pub fn destroy(self: *Bar) void {
        self.surf.destroy();
        self.app.alloc.destroy(self);
    }

    fn surfHeight(self: *Bar) u32 {
        // 影が切れないよう、下に余白(=margin)を取ったサーフェスにする
        return @intFromFloat(self.app.cfg.bar_height + self.app.cfg.bar_margin * 2 + 6);
    }

    pub fn applyGeometry(self: *Bar) void {
        self.surf.setExclusive(@intFromFloat(self.app.cfg.bar_height + self.app.cfg.bar_margin));
        self.surf.resize(0, self.surfHeight());
    }

    fn configured(ctx: *anyopaque, s: *Surface) void {
        const self: *Bar = @ptrCast(@alignCast(ctx));
        const cfg = &self.app.cfg;
        const h: i32 = @intFromFloat(cfg.bar_height + cfg.bar_margin);
        // クリックはバー本体だけで受け、下の影の帯はウィンドウにクリックを通す
        if (cfg.bar_position == .top) {
            s.origin = .{ 0, 0 };
            s.setInputRect(0, 0, @intCast(s.width), h);
        } else {
            const oh: f32 = @floatFromInt(self.out.logicalSize()[1]);
            s.origin = .{ 0, oh - @as(f32, @floatFromInt(s.height)) };
            s.setInputRect(0, @as(i32, @intCast(s.height)) - h, @intCast(s.width), h);
        }
    }

    fn focusedIndex(self: *Bar) f32 {
        const t = self.out.focused_tags;
        if (t == 0) return 0;
        return @floatFromInt(@min(@ctz(t), TAGS - 1));
    }

    pub fn tagsChanged(self: *Bar) void {
        const idx = self.focusedIndex();
        self.lead.set(idx);
        self.trail.set(idx);
        self.surf.schedule();
    }

    fn setCur(self: *Bar, t: []const u8) void {
        self.cur_title_len = @min(t.len, self.cur_title.len);
        @memcpy(self.cur_title[0..self.cur_title_len], t[0..self.cur_title_len]);
    }

    pub fn titleChanged(self: *Bar) void {
        // 旧タイトルを退避してクロスフェード
        self.prev_title_len = self.cur_title_len;
        @memcpy(self.prev_title[0..self.prev_title_len], self.cur_title[0..self.cur_title_len]);
        self.setCur(self.app.focused_title.get());
        self.title_t.snap(0);
        self.title_t.set(1);
        self.surf.schedule();
    }

    fn addHit(self: *Bar, kind: Hit, idx: u8, x: f32, w: f32) usize {
        if (self.n_hits >= self.hits.len) return 0;
        self.hits[self.n_hits] = .{ .kind = kind, .idx = idx, .x = x, .w = w };
        self.n_hits += 1;
        return self.n_hits - 1;
    }

    fn hov(self: *Bar, i: usize) f32 {
        return if (i < self.hover.len) self.hover[i].x else 0;
    }

    // ---------------------------------------------------------------------
    // 描画
    // ---------------------------------------------------------------------

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *Bar = @ptrCast(@alignCast(ctx));
        const app = self.app;
        const cfg = &app.cfg;

        // 占有タグの表示もスプリングで出し入れする
        for (0..TAGS) |i| {
            const occ = (self.out.view_tags >> @intCast(i)) & 1 == 1;
            self.occupied[i].set(if (occ) 1 else 0);
            if (self.first) self.occupied[i].snap(if (occ) 1 else 0);
        }

        var animating = false;
        var springs = [_]*Spring{ &self.enter, &self.lead, &self.trail, &self.squish, &self.title_t, &self.width_l, &self.width_r, &self.width_c };
        if (anim.stepAll(&springs, dt)) animating = true;
        for (&self.hover) |*h| if (h.step(dt)) {
            animating = true;
        };
        for (&self.occupied) |*o| if (o.step(dt)) {
            animating = true;
        };
        if (theme.accentAnimating()) animating = true;

        const W: f32 = @floatFromInt(s.width);
        const H = cfg.bar_height;
        const m = cfg.bar_margin;
        const top = cfg.bar_position == .top;
        const y0: f32 = if (top) m else @as(f32, @floatFromInt(s.height)) - m - H;
        const r = @min(cfg.radius, H / 2);
        const acc = theme.accent(app);
        const txt = theme.text(app);
        const sub = theme.subtext(app);
        const gl = theme.glass(app);
        const fs = H * 0.38; // 本文サイズ
        const base = y0 + H / 2 + fs * 0.36; // 文字のベースライン(縦中央)

        // 起動時のすべり込み: 上から(下バーなら下から)フェードイン
        cv.save();
        const slide = (1 - self.enter.x) * (H + m) * (if (top) @as(f32, -1) else 1);
        cv.translate(0, slide);
        cv.opacity(std.math.clamp(self.enter.x * 1.4, 0, 1));
        self.n_hits = 0;

        // ===== 左の島: ロゴ + タグ =====
        const pad: f32 = 6;
        const logo_w = H;
        const left_w_target = pad + logo_w + 4 + SLOT * TAGS + pad;
        if (self.first) self.width_l.snap(left_w_target) else self.width_l.set(left_w_target);
        const lx = m;
        const lw = self.width_l.x;
        cv.shadow(lx, y0 + 3, lw, H, r, 12, theme.shadow());
        cv.glass(lx, y0, lw, H, r, gl);

        // ロゴ「雨」: アクセント色で発光。ホバーで明るく。
        const hl = self.addHit(.logo, 0, lx, pad + logo_w);
        const lh = self.hov(hl);
        cv.rect(lx + pad, y0 + 4, logo_w - 4, H - 8, r - 4, acc.alpha(0.10 + 0.18 * lh));
        _ = cv.text(lx + pad + (logo_w - 4) / 2, base + 1, fs * 1.25, Color.mix(acc, txt, 0.35), "雨", .{ .bold = true, .alignment = .center, .glow = 4 + 4 * lh, .glow_color = acc.alpha(0.55) });

        // タグ
        const tx0 = lx + pad + logo_w + 4;
        const ty = y0 + H / 2;
        // 液体インジケータ: 2つのスプリングの間を角丸で埋める
        const a_ = @min(self.lead.x, self.trail.x);
        const b_ = @max(self.lead.x, self.trail.x);
        const stretch = b_ - a_;
        const ih = H - 12 - @min(stretch, 1.0) * 4 + self.squish.x * 3; // 伸びると少し細くなる
        const ix = tx0 + a_ * SLOT + 3;
        const iw = (b_ - a_) * SLOT + SLOT - 6;
        cv.shadow(ix, ty - ih / 2 + 1, iw, ih, ih / 2, 10, acc.alpha(0.45));
        cv.rectGrad(ix, ty - ih / 2, iw, ih, ih / 2, acc.lighten(0.25), acc);
        cv.rectBorder(ix, ty - ih / 2, iw, ih, ih / 2, .{ .a = 0 }, Color.hex(0xffffff).alpha(0.35), 1);

        for (0..TAGS) |i| {
            const fi: f32 = @floatFromInt(i);
            const cx = tx0 + fi * SLOT + SLOT / 2;
            const hi = self.addHit(.tag, @intCast(i), tx0 + fi * SLOT, SLOT);
            const hv = self.hov(hi);
            // 選択インジケータの上かどうか(文字色を反転させる)
            const on = std.math.clamp(1 - @abs(fi - self.lead.x), 0, 1);
            const urgent = (self.out.urgent_tags >> @intCast(i)) & 1 == 1;
            if (hv > 0.01) cv.rect(cx - SLOT / 2 + 3, ty - (H - 12) / 2, SLOT - 6, H - 12, (H - 12) / 2, Color.hex(0xffffff).alpha(0.08 * hv));
            var label: [2]u8 = .{ '1' + @as(u8, @intCast(i)), 0 };
            const occ = self.occupied[i].x;
            const col = Color.mix(Color.mix(sub.alpha(0.55), txt, occ), Color.hex(0x08101e), on);
            const ucol = if (urgent) Color.hex(0xff7a90) else col;
            _ = cv.text(cx, base, fs * 0.95, ucol, label[0..1], .{ .bold = occ > 0.5 or on > 0.5, .alignment = .center });
            // 占有ドット
            if (occ > 0.01) {
                const dr = 1.6 * occ;
                cv.rect(cx - dr, y0 + H - 7, dr * 2, dr * 2, dr, Color.mix(acc, Color.hex(0x08101e), on).alpha(occ));
            }
        }

        // ===== 右の島: ネット / 音量 / バッテリー / 時計 =====
        var clock_buf: [64]u8 = undefined;
        const clock = formatClock(&clock_buf, cfg.clock_24h, cfg.show_seconds);
        var date_buf: [64]u8 = undefined;
        const date = formatDate(&date_buf);
        var vol_buf: [32]u8 = undefined;
        var bat_buf: [32]u8 = undefined;
        const st = &app.sys;

        const items_font = fs * 0.92;
        const icon_font = fs * 1.15;
        const gap: f32 = 14;
        // 各項目の幅を先に測る
        const net_icon: []const u8 = switch (st.net.kind) {
            .wifi => "\u{F0928}",
            .wired => "\u{F0200}",
            .none => "\u{F092D}",
        };
        const vol_icon: []const u8 = if (!st.volume.known) "\u{F0581}" else if (st.volume.muted) "\u{F075F}" else if (st.volume.level > 0.6) "\u{F057E}" else if (st.volume.level > 0.25) "\u{F0580}" else "\u{F057F}";
        const vol_txt = if (st.volume.known) (std.fmt.bufPrint(&vol_buf, "{d}%", .{@as(u32, @intFromFloat(@round(st.volume.level * 100)))}) catch "") else "--";
        const bat_icon = batteryIcon(st.battery);
        const bat_txt = std.fmt.bufPrint(&bat_buf, "{d}%", .{st.battery.percent}) catch "";

        const w_net = cv.measure(net_icon, icon_font, false);
        const w_vol = cv.measure(vol_icon, icon_font, false) + 5 + cv.measure(vol_txt, items_font, false);
        const w_bat = if (st.battery.present) cv.measure(bat_icon, icon_font, false) + 5 + cv.measure(bat_txt, items_font, false) else 0;
        const w_clock = cv.measure(clock, fs * 1.05, true) + 8 + cv.measure(date, items_font * 0.92, false);
        var right_w_target = 14 + w_net + gap + w_vol + gap + w_clock + 14;
        if (st.battery.present) right_w_target += w_bat + gap;
        if (self.first) self.width_r.snap(right_w_target) else self.width_r.set(right_w_target);
        const rw = self.width_r.x;
        const rx = W - m - rw;
        cv.shadow(rx, y0 + 3, rw, H, r, 12, theme.shadow());
        cv.glass(rx, y0, rw, H, r, gl);
        cv.setClip(rx, y0, rw, H);

        var x = rx + 14;
        // ネット
        {
            const hi = self.addHit(.net, 0, x - gap / 2, w_net + gap);
            const col = Color.mix(if (st.net.kind == .none) sub else txt, acc, self.hov(hi));
            _ = cv.text(x, base + 1, icon_font, col, net_icon, .{});
            x += w_net + gap;
        }
        // 音量
        {
            const hi = self.addHit(.volume, 0, x - gap / 2, w_vol + gap);
            const hv = self.hov(hi);
            const col = Color.mix(txt, acc, hv);
            const iw2 = cv.measure(vol_icon, icon_font, false);
            _ = cv.text(x, base + 1, icon_font, col, vol_icon, .{});
            _ = cv.text(x + iw2 + 5, base, items_font, col, vol_txt, .{});
            // 細い音量バーを下に
            if (st.volume.known) {
                const bw = w_vol;
                cv.rect(x, y0 + H - 6, bw, 2, 1, sub.alpha(0.25));
                cv.rect(x, y0 + H - 6, bw * std.math.clamp(st.volume.level, 0, 1), 2, 1, acc.alpha(0.6 + 0.4 * hv));
            }
            x += w_vol + gap;
        }
        // バッテリー
        if (st.battery.present) {
            const hi = self.addHit(.battery, 0, x - gap / 2, w_bat + gap);
            const low = st.battery.percent <= 15 and !st.battery.charging;
            const col = if (low) Color.hex(0xff7a90) else if (st.battery.charging) Color.hex(0x7dffc4) else Color.mix(txt, acc, self.hov(hi));
            const iw2 = cv.measure(bat_icon, icon_font, false);
            _ = cv.text(x, base + 1, icon_font, col, bat_icon, .{ .glow = if (st.battery.charging) 3 else 0, .glow_color = Color.hex(0x7dffc4).alpha(0.5) });
            _ = cv.text(x + iw2 + 5, base, items_font, col, bat_txt, .{});
            x += w_bat + gap;
        }
        // 時計
        {
            const hi = self.addHit(.clock, 0, x - gap / 2, w_clock + 14 + gap / 2);
            const hv = self.hov(hi);
            if (hv > 0.01) cv.rect(x - 7, y0 + 4, w_clock + 14, H - 8, r - 4, acc.alpha(0.12 * hv));
            const cw = cv.text(x, base, fs * 1.05, txt, clock, .{ .bold = true });
            _ = cv.text(x + cw + 8, base, items_font * 0.92, sub, date, .{});
        }
        cv.setClip(0, 0, 0, 0);

        // ===== 中央の島: タイトル =====
        const title = self.cur_title[0..self.cur_title_len];
        const prev = self.prev_title[0..self.prev_title_len];
        const max_title = @max(0, @min(W * 0.36, rx - (lx + lw) - 40));
        const tw_cur = @min(cv.measure(title, fs, false), max_title);
        const tw_prev = @min(cv.measure(prev, fs, false), max_title);
        const t = self.title_t.x;
        const cw_target = if (title.len == 0) 0 else tw_cur + 32;
        if (self.first) self.width_c.snap(cw_target) else self.width_c.set(cw_target);
        const cw_ = @max(self.width_c.x, @max(0, (tw_prev + 32) * (1 - t)));
        if (cw_ > 4 and max_title > 40) {
            const cx = W / 2 - cw_ / 2;
            cv.shadow(cx, y0 + 3, cw_, H, r, 12, theme.shadow().alpha(std.math.clamp(cw_ / 40, 0, 1)));
            cv.glass(cx, y0, cw_, H, r, gl);
            cv.setClip(cx, y0, cw_, H);
            if (prev.len > 0 and t < 1) {
                cv.save();
                cv.opacity(1 - t);
                _ = cv.text(W / 2, base - t * 10, fs, sub, prev, .{ .alignment = .center, .max_w = max_title });
                cv.restore();
            }
            cv.save();
            cv.opacity(t);
            _ = cv.text(W / 2, base + (1 - t) * 10, fs, txt, title, .{ .alignment = .center, .max_w = max_title });
            cv.restore();
            cv.setClip(0, 0, 0, 0);
        }

        cv.restore();
        if (self.first and app.startup_ms == 0) app.startup_ms = @import("platform/loop.zig").nowMs() - app.start_ms;
        self.first = false;
        return animating;
    }

    // ---------------------------------------------------------------------
    // 入力
    // ---------------------------------------------------------------------

    fn hitAt(self: *Bar, x: f32) ?usize {
        for (self.hits[0..self.n_hits], 0..) |h, i| if (x >= h.x and x < h.x + h.w) return i;
        return null;
    }

    fn pointer(ctx: *anyopaque, s: *Surface, ev: surface.PointerEvent) void {
        const self: *Bar = @ptrCast(@alignCast(ctx));
        const app = self.app;
        const now = if (ev.kind == .leave) null else self.hitAt(ev.x);
        if (now != self.hover_idx) {
            if (self.hover_idx) |i| if (i < self.hover.len) self.hover[i].set(0);
            if (now) |i| if (i < self.hover.len) self.hover[i].set(1);
            self.hover_idx = now;
            s.schedule();
        }
        const i = now orelse return;
        const h = self.hits[i];
        switch (ev.kind) {
            .press => {
                switch (h.kind) {
                    .tag => {
                        const mask = @as(u32, 1) << @intCast(h.idx);
                        if (ev.button == 0x111) { // BTN_RIGHT: タグの表示を足し引き
                            var buf: [16]u8 = undefined;
                            app.riverCommand(&.{ "toggle-focused-tags", std.fmt.bufPrintZ(&buf, "{d}", .{mask}) catch return });
                        } else {
                            app.focusTags(mask);
                        }
                        self.squish.kick(18);
                    },
                    .logo => app.launcher.toggle(),
                    .clock, .net, .battery => app.dashboard.toggle(),
                    .volume => {
                        sys.toggleMute();
                        app.sys.volume = sys.volume();
                        app.osd.show(.volume);
                    },
                    else => {},
                }
                if (h.kind != .tag) self.hover[i].kick(-6); // 押した感触
                s.schedule();
            },
            .scroll => {
                switch (h.kind) {
                    .volume => {
                        sys.setVolumeDelta(if (ev.scroll < 0) 3 else -3);
                        app.sys.volume = sys.volume();
                        app.osd.show(.volume);
                        app.redrawBars();
                    },
                    .tag, .logo => {
                        // ホイールで隣のタグへ
                        const cur: i32 = @intFromFloat(self.focusedIndex());
                        const next = std.math.clamp(cur + @as(i32, if (ev.scroll > 0) 1 else -1), 0, TAGS - 1);
                        app.focusTags(@as(u32, 1) << @intCast(next));
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

fn batteryIcon(b: sys.Battery) []const u8 {
    if (b.charging) return "\u{F0084}";
    const icons = [_][]const u8{ "\u{F008E}", "\u{F007A}", "\u{F007B}", "\u{F007C}", "\u{F007D}", "\u{F007E}", "\u{F007F}", "\u{F0080}", "\u{F0081}", "\u{F0082}", "\u{F0079}" };
    return icons[@min(@as(usize, b.percent) / 10, 10)];
}

pub fn localTime() c.struct_tm {
    var t: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&t, &tm);
    return tm;
}

pub fn formatClock(buf: []u8, h24: bool, secs: bool) []const u8 {
    const tm = localTime();
    var h = tm.tm_hour;
    if (!h24) {
        h = @mod(h, 12);
        if (h == 0) h = 12;
    }
    if (secs) return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(h)), @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)) }) catch "";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(h)), @as(u32, @intCast(tm.tm_min)) }) catch "";
}

pub const weekdays_ja = [_][]const u8{ "日", "月", "火", "水", "木", "金", "土" };

pub fn formatDate(buf: []u8) []const u8 {
    const tm = localTime();
    return std.fmt.bufPrint(buf, "{d}月{d}日({s})", .{ @as(u32, @intCast(tm.tm_mon + 1)), @as(u32, @intCast(tm.tm_mday)), weekdays_ja[@intCast(tm.tm_wday)] }) catch "";
}
