// 縦バー(枠の左辺)。上から: ロゴ / ワークスペース(縦の液体インジケータ)/ ウィンドウ名(縦書き)
// … 下から: 電源 / 状態アイコン(音量・ネット・Bluetooth・電池)/ 時計(時と分を縦に)。
// 項目にマウスを乗せると、右側(枠の外)にポップアウトが生えてくる。
const std = @import("std");
const c = @import("../c.zig");
const anim = @import("../anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("../gfx.zig");
const theme = @import("../theme.zig");
const surface = @import("../surface.zig");
const sys = @import("../platform/sys.zig");
const loop = @import("../platform/loop.zig");
const barmod = @import("../bar.zig");
const Frame = @import("frame.zig").Frame;

pub const Pop = enum { none, window, clock, volume, network, bluetooth, battery };

const TAGS = 9;
const SLOT: f32 = 28;

const HitKind = enum(u8) { logo, tag, window, clock, volume, network, bluetooth, battery, power };
const Hit = struct { kind: HitKind, idx: u8 = 0, y: f32, h: f32 };

pub const Bar = struct {
    enter: Spring = Spring.init(0, 0.6, 0.8),
    lead: Spring = Spring.init(0, 0.20, 0.72),
    trail: Spring = Spring.init(0, 0.42, 0.92),
    squish: Spring = Spring.init(0, 0.25, 0.5),
    title_t: Spring = Spring.init(1, 0.4, 1.0),
    hover: [24]Spring = [_]Spring{Spring.init(0, 0.2, 1.0)} ** 24,
    occupied: [TAGS]Spring = [_]Spring{Spring.init(0, 0.3, 0.8)} ** TAGS,
    hits: [24]Hit = undefined,
    n_hits: usize = 0,
    hover_idx: ?usize = null,
    first: bool = true,
    title_ms: u64 = 0,
    bt_on: bool = false,
    bt_checked_ms: u64 = 0,
    logo_tex: c.GLuint = 0,
    logo_tried: bool = false,
    /// 画像のロゴが無い OS のロゴ(Nerd Font の Font Logos の 1 文字)と色
    logo_glyph: []const u8 = "",
    logo_color: ?Color = null,

    fn focusedIndex(f: *Frame) f32 {
        const t = f.out.focused_tags;
        if (t == 0) return 0;
        return @floatFromInt(@min(@ctz(t), TAGS - 1));
    }

    pub fn tagsChanged(self: *Bar, f: *Frame) void {
        const i = focusedIndex(f);
        self.lead.set(i);
        self.trail.set(i);
        f.schedule();
    }

    pub fn titleChanged(self: *Bar, f: *Frame) void {
        // 頻繁に変わるタイトル(スピナー等)ではフェードし直さない(常時描画を避ける)
        const now = loop.nowMs();
        if (now - self.title_ms > 1000) {
            self.title_t.snap(0);
            self.title_t.set(1);
        }
        self.title_ms = now;
        f.schedule();
    }

    fn addHit(self: *Bar, kind: HitKind, idx: u8, y: f32, h: f32) usize {
        if (self.n_hits >= self.hits.len) return 0;
        self.hits[self.n_hits] = .{ .kind = kind, .idx = idx, .y = y, .h = h };
        self.n_hits += 1;
        return self.n_hits - 1;
    }

    fn hov(self: *Bar, i: usize) f32 {
        return self.hover[i].x;
    }

    pub fn draw(self: *Bar, f: *Frame, cv: *gfx.Canvas, dt: f32) bool {
        const app = f.app;
        const BW = f.BW();
        const T = f.T();
        const H = f.H;
        const cx = BW / 2;
        for (0..TAGS) |i| {
            const occ = (f.out.view_tags >> @intCast(i)) & 1 == 1;
            if (self.first) self.occupied[i].snap(if (occ) 1 else 0) else self.occupied[i].set(if (occ) 1 else 0);
        }
        if (self.first) {
            self.lead.snap(focusedIndex(f));
            self.trail.snap(focusedIndex(f));
        }
        var animating = false;
        var sp = [_]*Spring{ &self.enter, &self.lead, &self.trail, &self.squish, &self.title_t };
        if (anim.stepAll(&sp, dt)) animating = true;
        for (&self.hover) |*h| if (h.step(dt)) {
            animating = true;
        };
        for (&self.occupied) |*o| if (o.step(dt)) {
            animating = true;
        };

        const acc = theme.accent(app);
        const txt = theme.text(app);
        const sub = theme.subtext(app);
        const dark = Color.hex(0x08101e);
        self.n_hits = 0;
        cv.save();
        cv.translate(-(1 - self.enter.x) * BW, 0); // 起動時に左からすべり込む
        cv.opacity(std.math.clamp(self.enter.x * 1.5, 0, 1));

        // ---- ロゴ ----
        var y: f32 = T + 6;
        {
            const hi = self.addHit(.logo, 0, y - 4, 40);
            const hv = self.hov(hi);
            if (!self.logo_tried) {
                self.logo_tried = true;
                self.logo_tex = loadOsLogo();
                if (self.logo_tex == 0) if (osLogoGlyph()) |g| {
                    self.logo_glyph = g.glyph;
                    self.logo_color = g.color;
                };
            }
            if (self.logo_tex != 0) {
                // OS のロゴ(/etc/os-release の LOGO=)。ホバーで少し大きく、背後に淡い光
                const s: f32 = 26 + 4 * hv;
                if (hv > 0.01) cv.shadow(cx - s / 2, y + 15 - s / 2, s, s, s / 2, 10, acc.alpha(0.5 * hv));
                cv.image(self.logo_tex, cx - s / 2, y + 15 - s / 2, s, s, 0);
            } else if (self.logo_glyph.len > 0) {
                // OS のロゴの文字(FreeBSD など。Nerd Font の Font Logos)。ホバーで少し大きく、光る
                const col = self.logo_color orelse Color.mix(acc, txt, 0.2);
                const s: f32 = 26 + 3 * hv;
                _ = cv.text(cx, y + 15 + s * 0.36, s, col, self.logo_glyph, .{ .alignment = .center, .glow = 2 + 5 * hv, .glow_color = col.alpha(0.55) });
            } else {
                cv.rect(cx - 15, y, 30, 30, 15, acc.alpha(0.14 + 0.2 * hv));
                _ = cv.text(cx, y + 22, 18, Color.mix(acc, txt, 0.3), "雨", .{ .bold = true, .alignment = .center, .glow = 3 + 4 * hv, .glow_color = acc.alpha(0.6) });
            }
            y += 46;
        }

        // ---- ワークスペース(縦) ----
        const ws_y = y;
        {
            cv.rect(cx - 15, ws_y - 4, 30, SLOT * TAGS + 8, 15, Color.hex(0xffffff).alpha(0.04));
            const a_ = @min(self.lead.x, self.trail.x);
            const b_ = @max(self.lead.x, self.trail.x);
            const iw: f32 = 24 - @min(b_ - a_, 1.0) * 4 + self.squish.x * 3;
            const iy = ws_y + a_ * SLOT + 2;
            const ih = (b_ - a_) * SLOT + SLOT - 4;
            cv.shadow(cx - iw / 2, iy, iw, ih, iw / 2, 9, acc.alpha(0.45));
            cv.rectGrad(cx - iw / 2, iy, iw, ih, iw / 2, acc.lighten(0.25), acc);
            for (0..TAGS) |i| {
                const fi: f32 = @floatFromInt(i);
                const ty = ws_y + fi * SLOT;
                const hi = self.addHit(.tag, @intCast(i), ty, SLOT);
                const hv = self.hov(hi);
                const on = std.math.clamp(1 - @abs(fi - self.lead.x), 0, 1);
                const occ = self.occupied[i].x;
                const urgent = (f.out.urgent_tags >> @intCast(i)) & 1 == 1;
                if (hv > 0.01) cv.rect(cx - 12, ty + 2, 24, SLOT - 4, 12, Color.hex(0xffffff).alpha(0.10 * hv));
                if (occ > 0.02 or on > 0.02) {
                    var lab: [1]u8 = .{'1' + @as(u8, @intCast(i))};
                    const col = if (urgent) theme.danger(app) else Color.mix(Color.mix(sub, txt, occ), dark, on);
                    _ = cv.text(cx, ty + SLOT / 2 + 5, 13, col, lab[0..], .{ .bold = true, .alignment = .center });
                } else {
                    // 空のタグは小さな点
                    cv.rect(cx - 2, ty + SLOT / 2 - 2, 4, 4, 2, sub.alpha(0.45));
                }
            }
            y = ws_y + SLOT * TAGS + 18;
        }

        // ---- 下から: 電源・状態アイコン・時計 ----
        var by = H - T - 8;
        {
            const hi = self.addHit(.power, 0, by - 34, 36);
            const hv = self.hov(hi);
            cv.rect(cx - 15, by - 32, 30, 30, 15, theme.danger(app).alpha(0.08 + 0.25 * hv));
            _ = cv.text(cx, by - 11, 16, Color.mix(theme.danger(app).lighten(0.18), txt, 0.2), "\u{F0425}", .{ .alignment = .center });
            by -= 44;
        }
        const st = &app.sys;
        const status = [_]struct { kind: HitKind, icon: []const u8, col: Color, show: bool }{
            .{ .kind = .battery, .icon = barmod.batteryIconPub(st.battery), .col = if (st.battery.charging) theme.accent(app) else if (st.battery.held()) Color.mix(txt, theme.accent(app), 0.5) else if (st.battery.percent <= 15) theme.danger(app) else txt, .show = st.battery.present },
            .{ .kind = .bluetooth, .icon = if (self.bt_on) "\u{F00AF}" else "\u{F00B2}", .col = if (self.bt_on) txt else sub, .show = true },
            .{ .kind = .network, .icon = switch (st.net.kind) {
                .wifi => "\u{F0928}",
                .wired => "\u{F0200}",
                .none => "\u{F092D}",
            }, .col = if (st.net.kind == .none) sub else txt, .show = true },
            .{ .kind = .volume, .icon = if (st.volume.muted) "\u{F075F}" else "\u{F057E}", .col = txt, .show = true },
        };
        // 状態アイコンをまとめる角丸の帯
        var n_status: f32 = 0;
        for (status) |s| {
            if (s.show) n_status += 1;
        }
        cv.rect(cx - 15, by - n_status * 28 - 4, 30, n_status * 28 + 8, 15, Color.hex(0xffffff).alpha(0.04));
        for (status) |s| {
            if (!s.show) continue;
            const hi = self.addHit(s.kind, 0, by - 28, 28);
            const hv = self.hov(hi);
            if (hv > 0.01) cv.rect(cx - 13, by - 27, 26, 26, 13, acc.alpha(0.18 * hv));
            _ = cv.text(cx, by - 8, 15, Color.mix(s.col, acc, hv), s.icon, .{ .alignment = .center });
            by -= 28;
        }
        by -= 18;
        // 時計: 時と分を縦に(caelestia と同じ)
        {
            const tm = barmod.localTime();
            var hb: [4]u8 = undefined;
            var mb: [4]u8 = undefined;
            const hs = std.fmt.bufPrint(&hb, "{d:0>2}", .{@as(u32, @intCast(tm.tm_hour))}) catch "";
            const ms = std.fmt.bufPrint(&mb, "{d:0>2}", .{@as(u32, @intCast(tm.tm_min))}) catch "";
            const hi = self.addHit(.clock, 0, by - 44, 50);
            const hv = self.hov(hi);
            if (hv > 0.01) cv.rect(cx - 15, by - 46, 30, 50, 15, acc.alpha(0.16 * hv));
            _ = cv.text(cx, by - 25, 14, txt, hs, .{ .bold = true, .alignment = .center });
            _ = cv.text(cx, by - 7, 14, Color.mix(txt, acc, 0.5), ms, .{ .bold = true, .alignment = .center });
            by -= 60;
        }

        // ---- ウィンドウ名(縦書き。ワークスペースと時計の間に収める) ----
        {
            const title = app.focused_title.get();
            const avail = by - y - 8;
            if (title.len > 0 and avail > 40) {
                const hi = self.addHit(.window, 0, y, avail);
                const hv = self.hov(hi);
                cv.save();
                cv.opacity(self.title_t.x);
                _ = cv.text(cx, y + 2, 16, Color.mix(sub, acc, hv), "\u{F05B6}", .{ .alignment = .center }); // ウィンドウのアイコン
                _ = cv.textV(cx, y + 26 + (1 - self.title_t.x) * 8, 13, Color.mix(txt, acc, hv * 0.5), title, .{ .max_w = avail - 30 });
                cv.restore();
            }
        }
        cv.restore();
        if (self.first and app.startup_ms == 0) app.startup_ms = loop.nowMs() - app.start_ms;
        self.first = false;
        if (theme.accentAnimating()) animating = true;
        return animating;
    }

    pub fn popoutAt(self: *Bar, y: f32) struct { kind: Pop, cy: f32 } {
        for (self.hits[0..self.n_hits]) |h| {
            if (y < h.y or y >= h.y + h.h) continue;
            const k: Pop = switch (h.kind) {
                .window => .window,
                .clock => .clock,
                .volume => .volume,
                .network => .network,
                .bluetooth => .bluetooth,
                .battery => .battery,
                else => .none,
            };
            // ウィンドウ名は縦に長いので、マウスの高さに出す
            const cy = if (h.kind == .window) y else h.y + h.h / 2;
            return .{ .kind = k, .cy = cy };
        }
        return .{ .kind = .none, .cy = 0 };
    }

    pub fn pointer(self: *Bar, f: *Frame, ev: surface.PointerEvent, x: f32, y: f32) bool {
        _ = x;
        const app = f.app;
        var now: ?usize = null;
        if (ev.kind != .leave and y >= 0) {
            for (self.hits[0..self.n_hits], 0..) |h, i| if (y >= h.y and y < h.y + h.h) {
                now = i;
                break;
            };
        }
        var redraw = false;
        if (now != self.hover_idx) {
            if (self.hover_idx) |i| self.hover[i].set(0);
            if (now) |i| self.hover[i].set(1);
            self.hover_idx = now;
            redraw = true;
            // Bluetooth の状態はアイコンに乗ったときだけ確認(常時監視はしない)
            if (now) |i| if (self.hits[i].kind == .bluetooth) self.checkBt(f);
        }
        const i = now orelse return redraw;
        const h = self.hits[i];
        switch (ev.kind) {
            .press => {
                switch (h.kind) {
                    .logo => app.launcher.toggle(),
                    .tag => {
                        app.focusTags(@as(u32, 1) << @intCast(h.idx));
                        self.squish.kick(18);
                    },
                    .clock => f.toggleDashboard(),
                    .volume => {
                        sys.toggleMute();
                        app.sys.volume = sys.volume();
                        f.showOsd();
                    },
                    .network => f.toggleNet(0),
                    .bluetooth => f.toggleNet(1),
                    .battery => f.toggleUtilities(),
                    .power => f.toggleSession(),
                    .window => {},
                }
                self.hover[i].kick(-6);
                return true;
            },
            .scroll => {
                switch (h.kind) {
                    .volume => {
                        sys.setVolumeDelta(if (ev.scroll < 0) 3 else -3);
                        app.sys.volume = sys.volume();
                        f.showOsd();
                    },
                    .tag, .logo => {
                        const cur: i32 = @intFromFloat(focusedIndex(f));
                        const nx = std.math.clamp(cur + @as(i32, if (ev.scroll > 0) 1 else -1), 0, TAGS - 1);
                        app.focusTags(@as(u32, 1) << @intCast(nx));
                    },
                    else => {},
                }
                return true;
            },
            else => {},
        }
        return redraw;
    }

    fn checkBt(self: *Bar, f: *Frame) void {
        if (loop.nowMs() - self.bt_checked_ms < 5000) return;
        self.bt_checked_ms = loop.nowMs();
        self.bt_on = f.app.syswatch.btPowered();
    }
};

// ---------------------------------------------------------------------------
// ポップアウト
// ---------------------------------------------------------------------------

pub fn popSize(f: *Frame, kind: Pop) [2]f32 {
    const au = f.app.audio;
    return switch (kind) {
        .none => .{ 200, 60 },
        .window => .{ 340, 78 },
        .clock => .{ 250, 128 },
        // 音量 + 出力先の一覧 + 入力先の一覧
        .volume => .{ 320, 84 + 26 + @as(f32, @floatFromInt(@max(au.sinks.n, 1))) * ROW_A + 26 + @as(f32, @floatFromInt(@max(au.sources.n, 1))) * ROW_A + 24 },
        .network => .{ 290, 96 },
        .bluetooth => .{ 260, 76 },
        .battery => .{ 290, 104 },
    };
}

const audio = @import("../audio.zig");
const ROW_A: f32 = 32;

/// 音量ポップアウトの当たり判定(最後に描いた位置)
const AudioHit = struct { kind: audio.Kind, idx: usize, rect: [4]f32 };
var pop_audio: struct {
    hits: [2 * audio.MAX]AudioHit = undefined,
    n: usize = 0,
    hover: ?usize = null,
    vol_bar: [4]f32 = .{ 0, 0, 0, 0 },
} = .{};

fn drawDevList(f: *Frame, cv: *gfx.Canvas, w: f32, y0: f32, kind: audio.Kind) f32 {
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const l = app.audio.list(kind);
    _ = cv.text(18, y0 + 14, 12, acc, if (kind == .sink) "出力先" else "入力先", .{ .bold = true });
    var y = y0 + 22;
    if (l.n == 0) {
        _ = cv.text(30, y + 20, 12.5, sub, if (app.audio.unavailable) "pactl(pipewire-pulse)がありません" else "読み込み中…", .{});
        return y + ROW_A;
    }
    for (0..l.n) |i| {
        const d = &l.devs[i];
        const sel = l.isDefault(i);
        const hi = pop_audio.n;
        const hv = pop_audio.hover != null and pop_audio.hover.? == hi;
        const r = [4]f32{ 10, y, w - 20, ROW_A - 4 };
        if (pop_audio.n < pop_audio.hits.len) {
            pop_audio.hits[pop_audio.n] = .{ .kind = kind, .idx = i, .rect = r };
            pop_audio.n += 1;
        }
        if (sel) {
            cv.rect(r[0], r[1], r[2], r[3], 10, acc.alpha(0.22));
        } else if (hv) cv.rect(r[0], r[1], r[2], r[3], 10, Color.hex(0xffffff).alpha(0.07));
        const nm = d.nameStr();
        const icon: []const u8 = if (d.bluetooth) "\u{F02CB}" else if (std.ascii.indexOfIgnoreCase(nm, "hdmi") != null) "\u{F0379}" else if (kind == .sink) "\u{F04C3}" else "\u{F036C}";
        const col = if (sel) acc.lighten(0.25) else txt;
        _ = cv.text(30, y + 19, 15, col, icon, .{ .alignment = .center });
        _ = cv.text(46, y + 19, 12.5, col, d.labelStr(), .{ .bold = sel, .max_w = w - 90 });
        if (sel) _ = cv.text(w - 28, y + 19, 14, acc.lighten(0.25), "\u{F012C}", .{ .alignment = .center });
        y += ROW_A;
    }
    return y;
}

/// 音量ポップアウトの操作。扱ったら true
pub fn audioPopPointer(f: *Frame, ev: surface.PointerEvent, lx: f32, ly: f32) bool {
    const app = f.app;
    var hov: ?usize = null;
    for (pop_audio.hits[0..pop_audio.n], 0..) |h, i| {
        const r = h.rect;
        if (lx >= r[0] and lx < r[0] + r[2] and ly >= r[1] and ly < r[1] + r[3]) hov = i;
    }
    const changed = hov != pop_audio.hover;
    pop_audio.hover = if (ev.kind == .leave) null else hov;
    if (ev.kind == .press) {
        if (ev.button == 0x111) {
            sys.toggleMute();
            app.sys.volume = sys.volume();
            return true;
        }
        if (hov) |i| {
            const h = pop_audio.hits[i];
            app.audio.select(h.kind, h.idx);
            return true;
        }
        const b = pop_audio.vol_bar;
        if (lx >= b[0] - 6 and lx <= b[0] + b[2] + 6 and ly >= b[1] and ly <= b[1] + b[3]) {
            sys.setVolume(std.math.clamp((lx - b[0]) / b[2], 0, 1));
            app.sys.volume = sys.volume();
            app.redrawBars();
            return true;
        }
        return true;
    }
    return changed;
}

pub fn drawPopout(f: *Frame, cv: *gfx.Canvas, w: f32, h: f32) bool {
    _ = h;
    const app = f.app;
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const st = &app.sys;
    const x: f32 = 18;
    var buf: [128]u8 = undefined;
    switch (f.pop_kind) {
        .none => {},
        .window => {
            _ = cv.text(x, 28, 12, acc, "アクティブなウィンドウ", .{ .bold = true });
            const t = app.focused_title.get();
            _ = cv.text(x, 54, 15, txt, if (t.len > 0) t else "(なし)", .{ .max_w = w - 36 });
        },
        .clock => {
            const tm = barmod.localTime();
            const time = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) }) catch "";
            _ = cv.text(x, 52, 36, txt, time, .{ .bold = true, .glow = 5, .glow_color = acc.alpha(0.5) });
            var db: [64]u8 = undefined;
            _ = cv.text(x, 82, 14, sub, barmod.formatDate(&db), .{});
            _ = cv.text(x, 108, 11.5, acc, "クリックでダッシュボード", .{});
        },
        .volume => {
            const v = if (st.volume.known) st.volume.level else 0;
            _ = cv.text(x, 28, 12, acc, "音量", .{ .bold = true });
            const pct = std.fmt.bufPrint(&buf, "{d}%{s}", .{ @as(u32, @intFromFloat(@round(v * 100))), if (st.volume.muted) " (ミュート)" else "" }) catch "";
            _ = cv.text(w - 18, 28, 13, if (st.volume.muted) theme.danger(app) else txt, pct, .{ .alignment = .right, .bold = true });
            cv.rect(x, 48, w - 36, 8, 4, Color.hex(0xffffff).alpha(0.12));
            cv.rectGrad(x, 48, @max((w - 36) * std.math.clamp(v, 0, 1), 8), 8, 4, acc.lighten(0.3), acc);
            pop_audio.vol_bar = .{ x, 38, w - 36, 28 };
            _ = cv.text(x, 74, 11, sub, "ホイール・クリックで音量 / 右クリックでミュート", .{});
            // 出力先・入力先(クリックで切り替え。再生中の音も移る)
            pop_audio.n = 0;
            var y: f32 = 84;
            y = drawDevList(f, cv, w, y, .sink);
            _ = drawDevList(f, cv, w, y, .source);
        },
        .network => {
            _ = cv.text(x, 28, 12, acc, "ネットワーク", .{ .bold = true });
            const name = st.net.name_buf[0..st.net.name_len];
            const kind_s: []const u8 = switch (st.net.kind) {
                .wifi => "Wi-Fi",
                .wired => "有線",
                .none => "未接続",
            };
            _ = cv.text(x, 56, 16, txt, if (st.net.kind == .none) "接続されていません" else name, .{ .bold = true, .max_w = w - 36 });
            _ = cv.text(x, 80, 12.5, sub, kind_s, .{});
        },
        .bluetooth => {
            _ = cv.text(x, 28, 12, acc, "Bluetooth", .{ .bold = true });
            _ = cv.text(x, 56, 15, txt, if (f.bar.bt_on) "オン" else "オフ", .{ .bold = true });
            _ = cv.text(w - 18, 56, 12, sub, "クリックで切替パネル", .{ .alignment = .right });
        },
        .battery => {
            _ = cv.text(x, 28, 12, acc, "バッテリー", .{ .bold = true });
            const s = std.fmt.bufPrint(&buf, "{d}%", .{st.battery.percent}) catch "";
            _ = cv.text(x, 62, 28, txt, s, .{ .bold = true });
            const pw = cv.measure(s, 28, true);
            _ = cv.text(x + pw + 10, 50, 12.5, if (st.battery.charging) acc else txt, barmod.batteryState(st.battery), .{ .max_w = w - x - pw - 28 });
            var tb: [48]u8 = undefined;
            _ = cv.text(x + pw + 10, 66, 11.5, sub, barmod.batteryTime(&tb, st.battery), .{});
            const pf = switch (f.sidev.profile) {
                .saver => "省電力",
                .balanced => "バランス",
                .performance => "パフォーマンス",
                .unknown => "",
            };
            if (pf.len > 0) _ = cv.text(x, 88, 12, sub, std.fmt.bufPrint(&buf, "電源プロファイル: {s}", .{pf}) catch "", .{});
        },
    }
    return false;
}

/// /etc/os-release の LOGO=(Chimera なら chimera-logo)をアイコンテーマから探して読み込む。
/// 起動直後に呼ばれるので、全テーマの索引は作らず hicolor だけを見る。
/// /etc/os-release の ID(無ければ OS の種類)から、Nerd Font の Font Logos の文字を選ぶ。
/// AME_OS_ID で上書きできる(試験用)。
fn osLogoGlyph() ?struct { glyph: []const u8, color: ?Color } {
    var b: [1024]u8 = undefined;
    var id: []const u8 = if (@import("builtin").os.tag == .freebsd) "freebsd" else "";
    if (sys.readFile("/etc/os-release", &b)) |s| {
        var lines = std.mem.splitScalar(u8, s, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "ID=")) id = std.mem.trim(u8, l[3..], "\"");
        }
    }
    if (std.posix.getenv("AME_OS_ID")) |e| id = e;
    const table = [_]struct { id: []const u8, glyph: []const u8, color: u32 }{
        .{ .id = "freebsd", .glyph = "\u{F30C}", .color = 0xd2302c }, // FreeBSD の赤
        .{ .id = "arch", .glyph = "\u{F303}", .color = 0x1793d1 },
        .{ .id = "debian", .glyph = "\u{F306}", .color = 0xd70a53 },
        .{ .id = "fedora", .glyph = "\u{F30A}", .color = 0x51a2da },
        .{ .id = "ubuntu", .glyph = "\u{F31B}", .color = 0xe95420 },
        .{ .id = "alpine", .glyph = "\u{F300}", .color = 0x2c8dc4 },
        .{ .id = "gentoo", .glyph = "\u{F30D}", .color = 0x9f95d6 },
        .{ .id = "nixos", .glyph = "\u{F313}", .color = 0x7ebae4 },
        .{ .id = "void", .glyph = "\u{F32E}", .color = 0x478061 },
        .{ .id = "linuxmint", .glyph = "\u{F30E}", .color = 0x87cf3e },
        .{ .id = "manjaro", .glyph = "\u{F312}", .color = 0x35bf5c },
    };
    for (table) |t| if (std.mem.eql(u8, t.id, id)) {
        return .{ .glyph = t.glyph, .color = Color.hex(t.color) };
    };
    // その他の Linux はペンギン(テーマの色)
    if (@import("builtin").os.tag == .linux and id.len > 0) return .{ .glyph = "\u{F31A}", .color = null };
    return null;
}

fn loadOsLogo() c.GLuint {
    // AME_OS_ID で別の OS のロゴを試しているときは画像のロゴを使わない
    if (std.posix.getenv("AME_OS_ID") != null) return 0;
    const icons = @import("../icons.zig");
    var b: [1024]u8 = undefined;
    var name: []const u8 = "";
    if (sys.readFile("/etc/os-release", &b)) |s| {
        var lines = std.mem.splitScalar(u8, s, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "LOGO=")) name = std.mem.trim(u8, l[5..], "\"");
        }
    }
    if (name.len == 0) return 0;
    var pb: [512]u8 = undefined;
    const p = icons.quickFind(name, &pb) orelse return 0;
    const px = icons.decode(p, 96, 96, false) orelse return 0;
    defer std.c.free(px);
    return gfx.uploadImage(px, 96, 96);
}
