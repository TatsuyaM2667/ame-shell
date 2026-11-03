// 再生中の曲のカード: ジャケット・回るレコードと液体のビジュアライザー・曲名・再生位置・操作・音量。
// ロック画面(lockui.zig)とホーム画面のウィジェット(musicwidget.zig)で同じものを使う。
//
// 操作: 前へ・再生/一時停止・次へ、再生位置のバー(クリック・ドラッグ)、音量のバー(クリック・ドラッグ)、
//       スピーカー(消音)、カードの上でホイール(音量 ±5)
const std = @import("std");
const anim = @import("anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("gfx.zig");
const theme = @import("theme.zig");
const data = @import("frame/data.zig");
const surface = @import("surface.zig");
const App = @import("app.zig").App;

const white = Color.hex(0xffffff);
const black = Color.hex(0x000000);

const I_PLAY = "\u{F040A}";
const I_PAUSE = "\u{F03E4}";
const I_PREV = "\u{F04AE}";
const I_NEXT = "\u{F04AD}";
const I_MUSIC = "\u{F075A}";
const I_VOL_HI = "\u{F057E}";
const I_VOL_MID = "\u{F0580}";
const I_VOL_LO = "\u{F057F}";
const I_VOL_OFF = "\u{F0581}";
const I_VOL_MUTE = "\u{F075F}";

fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0, 1);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn inRectPad(r: [4]f32, x: f32, y: f32, pad: f32) bool {
    return r[2] > 0 and x >= r[0] - pad and x <= r[0] + r[2] + pad and y >= r[1] - pad and y <= r[1] + r[3] + pad;
}

/// クリックできる場所(描くたびに作り直す。座標は surface の論理 px)
pub const Hits = struct {
    card: [4]f32 = .{ 0, 0, 0, 0 },
    prev: [4]f32 = .{ 0, 0, 0, 0 },
    play: [4]f32 = .{ 0, 0, 0, 0 },
    next: [4]f32 = .{ 0, 0, 0, 0 },
    vol: [4]f32 = .{ 0, 0, 0, 0 },
    mute: [4]f32 = .{ 0, 0, 0, 0 },
    seek: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Card = struct {
    /// 0 = 止まっている / 1 = 再生中(レコードが滑り出る・アイコンが替わる)
    play_s: Spring = Spring.init(0, 0.3, 0.8),
    /// レコードの回転(ラジアン)
    vinyl: f32 = 0,
    /// ドラッグ中のつまみ(0 = なし / 1 = 音量 / 2 = 再生位置)と、そのとき見せる値(0〜1)
    drag: u8 = 0,
    drag_v: f32 = 0,
    // 音量は wpctl を呼ぶ回数を減らすため、少し動いたときだけ反映する
    vol_sent: f32 = -1,
    vol_sent_ms: u64 = 0,
    hits: Hits = .{},

    /// カードの高さ(幅は呼ぶ側が決める。400 * k くらいがちょうどよい)
    pub fn height(k: f32) f32 {
        return (84 + 16 * 2 + 30) * k;
    }

    /// 出し始め: 今の再生状態にそろえる
    pub fn reset(self: *Card, app: *App) void {
        self.play_s.snap(if (app.media.status == .playing) 1 else 0);
        self.drag = 0;
    }

    /// アニメーションを進める。続くなら true
    pub fn step(self: *Card, app: *App, dt: f32) bool {
        const playing = app.media.status == .playing;
        if (playing) {
            self.vinyl += dt * std.math.tau / 8.0;
            if (self.vinyl > std.math.tau) self.vinyl -= std.math.tau;
        }
        self.play_s.set(if (playing) 1 else 0);
        _ = self.play_s.step(dt);
        return playing or self.play_s.moving();
    }

    /// (px0, cy0) から幅 pw・高さ height(k) に描く。spectrum は液体のビジュアライザーの値(null なら静か)
    pub fn draw(self: *Card, app: *App, cv: *gfx.Canvas, px0: f32, cy0: f32, pw: f32, k: f32, acc: Color, spectrum: ?[]const f32) void {
        const art: f32 = 84 * k;
        const pad: f32 = 16 * k;
        const vrow: f32 = 30 * k;
        const ch: f32 = height(k);
        const rad: f32 = 24 * k;
        const ps = self.play_s.x;
        self.hits = .{};
        cv.shadow(px0, cy0 + 10, pw, ch, rad, 30, black.alpha(0.4));
        cv.shadow(px0, cy0 + 14, pw, ch, rad, 46, acc.alpha(0.32 * ps));
        if (app.media.art_tex != 0) {
            cv.imageEx(app.media.art_tex, px0, cy0, pw, ch, rad, .{ 0, 0.25, 1, 0.75 }, 7, 0, 0.45, 0.97);
            cv.rect(px0, cy0, pw, ch, rad, Color.hex(0x05070f).alpha(0.32));
        } else {
            cv.glass(px0, cy0, pw, ch, rad, theme.glassStrong(app));
        }
        cv.rectBorder(px0, cy0, pw, ch, rad, .{ .a = 0 }, white.alpha(0.15), 1);

        // レコード(ジャケットの後ろから、再生中だけ滑り出て回る)と液体のビジュアライザー
        const ax = px0 + pad;
        const ay = cy0 + pad;
        const R: f32 = art * 0.47;
        const slide = art * 0.34 * ps;
        const dcx = ax + art / 2 + slide;
        const dcy = ay + art / 2;
        if (ps > 0.02) {
            cv.save();
            cv.opacity(ps);
            const zeros = [_]f32{0} ** data.BARS;
            const vals: []const f32 = spectrum orelse &zeros;
            cv.liquid(dcx, dcy, R + 1.5 * k, 16 * k, vals, acc, acc.lighten(0.3), self.vinyl / std.math.tau * 0.25);
            cv.restore();
        }
        cv.rect(dcx - R, dcy - R, R * 2, R * 2, R, Color.hex(0x0c0c11));
        var gr: f32 = R - 3;
        while (gr > R * 0.45) : (gr -= 2.4) cv.arc(dcx, dcy, gr, 0.7, 1, white.alpha(0.045), .{ .a = 0 });
        const lr: f32 = R * 0.38;
        if (app.media.art_tex != 0) {
            cv.imageEx(app.media.art_tex, dcx - lr, dcy - lr, lr * 2, lr * 2, lr, .{ 0, 0, 1, 1 }, 0, self.vinyl, 1, 1);
        } else cv.rect(dcx - lr, dcy - lr, lr * 2, lr * 2, lr, acc.alpha(0.8));
        cv.rect(dcx - 2, dcy - 2, 4, 4, 2, Color.hex(0x0c0c11));
        // ジャケット(手前)
        cv.save();
        cv.scaleAbout(ax + art / 2, ay + art / 2, lerp(0.92, 1, ps));
        cv.shadow(ax, ay + 6, art, art, 14 * k, 16, black.alpha(0.5));
        if (app.media.art_tex != 0) {
            cv.image(app.media.art_tex, ax, ay, art, art, 14 * k);
        } else {
            cv.rectGrad(ax, ay, art, art, 14 * k, acc.lighten(0.25), Color.mix(acc, Color.hex(0x101425), 0.45));
            _ = cv.text(ax + art / 2, ay + art / 2 + 12 * k, 32 * k, white, I_MUSIC, .{ .alignment = .center });
        }
        cv.rectBorder(ax, ay, art, art, 14 * k, .{ .a = 0 }, white.alpha(0.16), 1);
        cv.restore();

        // 曲名・アーティスト・進み具合・操作
        const tx = ax + art + art * 0.34 + R * 0.5 + 14 * k;
        const tw = px0 + pw - pad - tx;
        const m = app.media;
        // 動画サイトの書き方(【MV】アーティスト「曲名」など)は、歌詞の検索で整えた名前で出す
        const show_t = if (m.lyrics.qTitle().len > 0) m.lyrics.qTitle() else m.title[0..m.title_len];
        const show_a = if (m.lyrics.qArtist().len > 0) m.lyrics.qArtist() else m.artist[0..m.artist_len];
        _ = cv.text(tx, ay + 18 * k, 16 * k, white.alpha(0.97), show_t, .{ .bold = true, .max_w = tw });
        _ = cv.text(tx, ay + 37 * k, 12.5 * k, white.alpha(0.72), show_a, .{ .max_w = tw });
        self.hits.card = .{ px0, cy0, pw, ch };
        if (m.length_s > 0) {
            const pos = m.position();
            // 再生位置のバー: クリック・ドラッグで移動(ドラッグ中はつまみの位置を見せる)
            const seeking = self.drag == 2;
            const f = if (seeking) self.drag_v else clamp01(pos / m.length_s);
            const py = ay + 49 * k;
            const bh: f32 = @as(f32, if (seeking) 5.5 else 3.5) * k;
            cv.rect(tx, py, tw, bh, bh / 2, white.alpha(0.18));
            cv.rect(tx, py, tw * f, bh, bh / 2, white.alpha(0.9));
            if (seeking) {
                cv.rect(tx + tw * f - 6 * k, py + bh / 2 - 6 * k, 12 * k, 12 * k, 6 * k, white);
                var tb: [16]u8 = undefined;
                const sec: u32 = @intFromFloat(f * m.length_s);
                const ts = std.fmt.bufPrint(&tb, "{d}:{d:0>2}", .{ sec / 60, sec % 60 }) catch "";
                _ = cv.text(tx + tw, py - 4 * k, 11 * k, white.alpha(0.85), ts, .{ .alignment = .right });
            }
            self.hits.seek = .{ tx, py - 2 * k, tw, bh + 4 * k };
        }
        const by = ay + art - 4 * k;
        const bmid = tx + tw / 2;
        const gap: f32 = 46 * k;
        const bs: f32 = 34 * k;
        self.hits.prev = .{ bmid - gap - bs / 2, by - bs / 2 - 7 * k, bs, bs };
        self.hits.play = .{ bmid - bs / 2, by - bs / 2 - 7 * k, bs, bs };
        self.hits.next = .{ bmid + gap - bs / 2, by - bs / 2 - 7 * k, bs, bs };
        _ = cv.text(bmid - gap, by, 20 * k, white.alpha(0.9), I_PREV, .{ .alignment = .center });
        cv.save();
        cv.scaleAbout(bmid, by - 8 * k, 0.6 + 0.4 * ps);
        cv.opacity(ps);
        _ = cv.text(bmid, by + 2 * k, 27 * k, white, I_PAUSE, .{ .alignment = .center });
        cv.restore();
        cv.save();
        cv.scaleAbout(bmid, by - 8 * k, 1 - 0.4 * ps);
        cv.opacity(1 - ps);
        _ = cv.text(bmid, by + 2 * k, 27 * k, white, I_PLAY, .{ .alignment = .center });
        cv.restore();
        _ = cv.text(bmid + gap, by, 20 * k, white.alpha(0.9), I_NEXT, .{ .alignment = .center });

        // 音量: スピーカー(押すと消音)・バー(クリック・ドラッグ)・数字。カードの上でホイールを回しても変わる
        const vol = app.sys.volume;
        const lvl = if (self.drag == 1) self.drag_v else if (vol.known) clamp01(vol.level) else 0;
        const muted = vol.muted and self.drag != 1;
        const vy = cy0 + pad + art + vrow * 0.5 + 2 * k;
        const icon: []const u8 = if (!vol.known) I_VOL_OFF else if (muted) I_VOL_MUTE else if (lvl > 0.6) I_VOL_HI else if (lvl > 0.25) I_VOL_MID else I_VOL_LO;
        const ix = ax + 10 * k;
        _ = cv.text(ix, vy + 6.5 * k, 18 * k, white.alpha(if (muted) 0.55 else 0.9), icon, .{ .alignment = .center });
        self.hits.mute = .{ ix - 13 * k, vy - 13 * k, 26 * k, 26 * k };
        const bx = ax + 30 * k;
        const bw = px0 + pw - pad - 44 * k - bx;
        const bh: f32 = @as(f32, if (self.drag == 1) 6 else 4.5) * k;
        cv.rect(bx, vy - bh / 2, bw, bh, bh / 2, white.alpha(0.18));
        cv.rect(bx, vy - bh / 2, bw * lvl, bh, bh / 2, (if (muted) white.alpha(0.35) else white.alpha(0.9)));
        const kr: f32 = @as(f32, if (self.drag == 1) 8 else 6) * k;
        cv.shadow(bx + bw * lvl - kr, vy - kr + 1, kr * 2, kr * 2, kr, 6, black.alpha(0.35));
        cv.rect(bx + bw * lvl - kr, vy - kr, kr * 2, kr * 2, kr, white);
        self.hits.vol = .{ bx, vy - 8 * k, bw, 16 * k };
        var pb: [8]u8 = undefined;
        const pct = std.fmt.bufPrint(&pb, "{d}", .{@as(u32, @intFromFloat(@round(lvl * 100)))}) catch "";
        _ = cv.text(px0 + pw - pad, vy + 4.5 * k, 12.5 * k, white.alpha(0.75), if (muted) "消音" else pct, .{ .alignment = .right });
    }

    /// カードの上の操作。扱ったら true(呼ぶ側で描き直す)
    pub fn pointer(self: *Card, app: *App, ev: surface.PointerEvent) bool {
        const sys = @import("platform/sys.zig");
        const now = @import("platform/loop.zig").nowMs();
        const h = &self.hits;
        switch (ev.kind) {
            .press => {
                if (ev.button != 0x110) return false;
                if (inRectPad(h.prev, ev.x, ev.y, 0)) {
                    app.media.prev();
                    return true;
                } else if (inRectPad(h.play, ev.x, ev.y, 0)) {
                    app.media.toggle();
                    return true;
                } else if (inRectPad(h.next, ev.x, ev.y, 0)) {
                    app.media.next();
                    return true;
                } else if (inRectPad(h.vol, ev.x, ev.y, 8)) {
                    self.drag = 1;
                } else if (inRectPad(h.seek, ev.x, ev.y, 7) and app.media.length_s > 0) {
                    self.drag = 2;
                } else if (inRectPad(h.mute, ev.x, ev.y, 4)) {
                    sys.toggleMute();
                    app.sys.volume = sys.volume();
                    return true;
                } else return false;
                self.dragTo(app, ev.x, now, false);
                return true;
            },
            .motion => {
                if (self.drag == 0) return false;
                self.dragTo(app, ev.x, now, false);
                return true;
            },
            .release, .leave => {
                if (self.drag == 0) return false;
                self.dragTo(app, ev.x, now, true);
                self.drag = 0;
                return true;
            },
            .scroll => {
                if (!inRectPad(h.card, ev.x, ev.y, 0) or ev.scroll == 0) return false;
                // タッチパッドは細かい値が続けて来るので、wpctl は 60ms に 1 回まで
                if (now -% self.vol_sent_ms < 60) return true;
                self.vol_sent_ms = now;
                // 下へ回すと小さく(wl_pointer の値は下が正)
                sys.setVolumeDelta(if (ev.scroll > 0) -5 else 5);
                app.sys.volume = sys.volume();
                return true;
            },
            else => return false,
        }
    }

    fn dragTo(self: *Card, app: *App, x: f32, now: u64, final: bool) void {
        const sys = @import("platform/sys.zig");
        const r = if (self.drag == 1) self.hits.vol else self.hits.seek;
        if (r[2] <= 0) return;
        const v = std.math.clamp((x - r[0]) / r[2], 0, 1);
        self.drag_v = v;
        if (self.drag == 1) {
            // wpctl を呼ぶのは 1% 以上動いて 40ms たったとき(と、離したとき)だけ
            if (final or (@abs(v - self.vol_sent) >= 0.01 and now -% self.vol_sent_ms >= 40)) {
                sys.setVolume(v);
                if (app.sys.volume.muted and v > 0) sys.toggleMute();
                self.vol_sent = v;
                self.vol_sent_ms = now;
                app.sys.volume.level = v;
                app.sys.volume.muted = false;
                app.sys.volume.known = true;
            }
        } else if (final) {
            @import("media.zig").seekTo(app.media, v * app.media.length_s);
        }
    }
};
