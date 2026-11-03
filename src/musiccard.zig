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
    /// ジャケット(ロック画面では押すと大きく広げる)
    art: [4]f32 = .{ 0, 0, 0, 0 },
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
        self.hits.art = .{ ax, ay, art, art };
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

    /// 広げた「再生中」(ロック画面でジャケットを押したとき。iPhone / iPad のロック画面のように)の、
    /// 大きなジャケットの下の部分: 曲名・アーティスト・再生位置と時間・前/再生/次・音量。
    /// 横は cx を中心に幅 w、上端 y。hits は呼ぶ側が art(大きなジャケット)を入れたあとに上書きでよい。高さを返す
    pub fn drawExpanded(self: *Card, app: *App, cv: *gfx.Canvas, cx: f32, y: f32, w: f32, k: f32, acc: Color) f32 {
        _ = acc;
        const m = app.media;
        const x0 = cx - w / 2;
        const ps = self.play_s.x;
        const show_t = if (m.lyrics.qTitle().len > 0) m.lyrics.qTitle() else m.title[0..m.title_len];
        const show_a = if (m.lyrics.qArtist().len > 0) m.lyrics.qArtist() else m.artist[0..m.artist_len];
        _ = cv.text(x0, y + 24 * k, 22 * k, white.alpha(0.97), show_t, .{ .bold = true, .max_w = w });
        _ = cv.text(x0, y + 48 * k, 16 * k, white.alpha(0.7), show_a, .{ .max_w = w });

        // 再生位置(つまみは押している間だけ大きく)と、経過・残りの時間
        var yy = y + 70 * k;
        if (m.length_s > 0) {
            const seeking = self.drag == 2;
            const f = if (seeking) self.drag_v else clamp01(m.position() / m.length_s);
            const bh: f32 = @as(f32, if (seeking) 8 else 6) * k;
            cv.rect(x0, yy, w, bh, bh / 2, white.alpha(0.22));
            cv.rect(x0, yy, w * f, bh, bh / 2, white.alpha(if (seeking) 1 else 0.85));
            self.hits.seek = .{ x0, yy - 4 * k, w, bh + 8 * k };
            var b1: [16]u8 = undefined;
            var b2: [16]u8 = undefined;
            const el: u32 = @intFromFloat(f * m.length_s);
            const rem: u32 = @intFromFloat(@max(m.length_s - f * m.length_s, 0));
            const t1 = std.fmt.bufPrint(&b1, "{d}:{d:0>2}", .{ el / 60, el % 60 }) catch "";
            const t2 = std.fmt.bufPrint(&b2, "-{d}:{d:0>2}", .{ rem / 60, rem % 60 }) catch "";
            _ = cv.text(x0, yy + 24 * k, 12 * k, white.alpha(0.6), t1, .{});
            _ = cv.text(x0 + w, yy + 24 * k, 12 * k, white.alpha(0.6), t2, .{ .alignment = .right });
        }
        yy += 70 * k;

        // 前・再生/一時停止・次(大きく)
        const gap: f32 = @min(96 * k, w * 0.3);
        const bs: f32 = 56 * k;
        self.hits.prev = .{ cx - gap - bs / 2, yy - bs / 2, bs, bs };
        self.hits.play = .{ cx - bs / 2, yy - bs / 2, bs, bs };
        self.hits.next = .{ cx + gap - bs / 2, yy - bs / 2, bs, bs };
        _ = cv.text(cx - gap, yy + 12 * k, 34 * k, white.alpha(0.92), I_PREV, .{ .alignment = .center });
        _ = cv.text(cx + gap, yy + 12 * k, 34 * k, white.alpha(0.92), I_NEXT, .{ .alignment = .center });
        cv.save();
        cv.scaleAbout(cx, yy, 0.6 + 0.4 * ps);
        cv.opacity(ps);
        _ = cv.text(cx, yy + 16 * k, 46 * k, white, I_PAUSE, .{ .alignment = .center });
        cv.restore();
        cv.save();
        cv.scaleAbout(cx, yy, 1 - 0.4 * ps);
        cv.opacity(1 - ps);
        _ = cv.text(cx, yy + 16 * k, 46 * k, white, I_PLAY, .{ .alignment = .center });
        cv.restore();
        yy += 58 * k;

        // 音量: 左右にスピーカー(左を押すと消音)、間にバー
        const vol = app.sys.volume;
        const lvl = if (self.drag == 1) self.drag_v else if (vol.known) clamp01(vol.level) else 0;
        const muted = vol.muted and self.drag != 1;
        const bx = x0 + 28 * k;
        const bw = w - 56 * k;
        const bh: f32 = @as(f32, if (self.drag == 1) 8 else 6) * k;
        _ = cv.text(x0 + 8 * k, yy + 6 * k, 17 * k, white.alpha(if (muted) 0.5 else 0.75), if (muted) I_VOL_MUTE else I_VOL_LO, .{ .alignment = .center });
        _ = cv.text(x0 + w - 8 * k, yy + 6 * k, 17 * k, white.alpha(0.75), I_VOL_HI, .{ .alignment = .center });
        cv.rect(bx, yy - bh / 2, bw, bh, bh / 2, white.alpha(0.22));
        cv.rect(bx, yy - bh / 2, bw * lvl, bh, bh / 2, white.alpha(if (muted) 0.35 else 0.85));
        self.hits.mute = .{ x0 - 6 * k, yy - 14 * k, 28 * k, 28 * k };
        self.hits.vol = .{ bx, yy - 10 * k, bw, 20 * k };
        yy += 20 * k;
        self.hits.card = .{ x0, y, w, yy - y };
        return yy - y;
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

/// 同期した歌詞(lyrics.zig)を曲のカードの上(または指定した場所)に浮かべる。ダッシュボードと同じ見せ方:
/// 歌い終えた行が 1 行ずつ上へ積み上がり、今の行は下でポンと弾んで出る(これから歌う行は見せない)。
/// ロック画面とホーム画面のウィジェットで共有する
pub const Lyrics = struct {
    /// 出ている割合(同期歌詞があるときだけ 1)
    show: Spring = Spring.init(0, 0.45, 0.9),
    /// 今の行のポップと、歌い終えた行の押し上げ
    pop: Spring = Spring.init(1, 0.38, 0.55),
    scroll: Spring = Spring.init(0, 0.45, 0.9),
    idx: i32 = -1,

    pub fn visible(app: *App) bool {
        return app.media.status != .none and app.media.lyrics.state == .synced;
    }

    /// 行の進みを見てアニメーションを進める。続くなら true
    pub fn step(self: *Lyrics, app: *App, dt: f32) bool {
        const on = visible(app);
        self.show.set(if (on) 1 else 0);
        if (app.media.status != .none) {
            const cur = app.media.lyrics.current(app.media.position());
            const new_idx: i32 = if (cur.idx) |li| @intCast(li) else -1;
            if (new_idx != self.idx) {
                // 1 行進んだときだけ押し上げる(シークで飛んだときは、その場で並べ直す)
                self.scroll.snap(if (self.idx >= 0 and new_idx == self.idx + 1) 1 else 0);
                self.scroll.set(0);
                self.pop.snap(0);
                self.pop.set(1);
                self.idx = new_idx;
            }
        }
        // 歌詞を出している間は 3 秒おきに本当の再生位置を聞いてずれを直す
        // (シークを知らせないプレイヤーがあり、そのままだと違う行を指したままになる)
        if (on) app.media.resyncPosition();
        var springs = [_]*Spring{ &self.show, &self.pop, &self.scroll };
        return anim.stepAll(&springs, dt);
    }

    /// 横は px0〜px0+pw の中央ぞろえ。今の行の下端を bottom に、古い行は top_limit まで上へ積む。
    /// shade: 壁紙の上でも読めるよう、後ろにぼんやりした影を敷く
    pub fn draw(self: *Lyrics, app: *App, cv: *gfx.Canvas, px0: f32, pw: f32, bottom_y: f32, top_limit: f32, k: f32, acc: Color, alpha: f32, max_prev: usize) void {
        if (self.show.x < 0.01 or app.media.lyrics.lines.items.len == 0) return;
        const lcur = app.media.lyrics.current(app.media.position());
        const ls = app.media.lyrics.lines.items;
        const has_cur = lcur.idx != null;
        const ci = lcur.idx orelse 0;
        const big: f32 = 21 * k;
        const small: f32 = 15 * k;
        const lgap: f32 = 10 * k;
        const max_w = pw;
        const mid = px0 + pw / 2;
        const pop = self.pop.x;
        const sc = self.scroll.x;
        const text_of = struct {
            fn get(l: anytype, i: usize) []const u8 {
                if (i >= l.len) return "";
                return if (l[i].text.len > 0) l[i].text else "♪";
            }
        }.get;
        const cur_s = if (has_cur) text_of(ls, ci) else "♪";
        const n0: f32 = @floatFromInt(cv.wrapCount(cur_s, big, max_w, 2));
        const cur_bottom = bottom_y;
        const base_y = cur_bottom - (n0 - 1) * big * 1.32 - big * 0.3;
        const cur_top = base_y - big * 0.9;
        const shift = (cur_bottom - cur_top) + lgap;
        cv.save();
        cv.opacity(alpha * self.show.x);
        cv.shadow(px0 + 10 * k, top_limit + 40 * k, pw - 20 * k, @max(cur_bottom - top_limit - 30 * k, 10), 40 * k, 60 * k, black.alpha(0.42));
        // 歌い終えた行(新しい順に上へ。古いほど薄く、上の端で消える)
        var bottom = cur_top - lgap;
        var kk: usize = 1;
        while (has_cur and kk <= ci and kk <= max_prev) : (kk += 1) {
            const str = text_of(ls, ci - kk);
            const sz = if (kk == 1) small + (big - small) * sc else small;
            const lh = sz * 1.32;
            const nl: f32 = @floatFromInt(cv.wrapCount(str, sz, max_w, 2));
            const y = bottom - (nl - 1) * lh - sz * 0.3 + sc * shift;
            const top = y - sz * 0.9;
            if (top < top_limit - 40) break;
            const fade = clamp01((top - top_limit) / 50 + 1) * @max(0.2, 1 - @as(f32, @floatFromInt(kk - 1)) * 0.28);
            const col = if (kk == 1) Color.mix(white.alpha(0.7), white, sc) else white.alpha(0.7);
            _ = cv.textWrapOpts(mid, y, sz, col.alpha(col.a * fade), str, max_w, 2, lh, .{ .alignment = .center });
            bottom = top - lgap - sc * shift;
        }
        // 今の行: 下からポップ(少し行き過ぎて戻る)。行の進みに合わせてアクセント色へ
        cv.save();
        cv.translate(0, sc * shift + (1 - pop) * 14);
        cv.scaleAbout(mid, base_y, 0.82 + 0.18 * pop);
        cv.opacity(std.math.clamp(pop * 1.8, 0, 1));
        const col = Color.mix(white, acc.lighten(0.5), 0.2 + 0.5 * lcur.frac);
        _ = cv.textWrapOpts(mid, base_y, big, col, cur_s, max_w, 2, big * 1.32, .{ .alignment = .center, .bold = true });
        cv.restore();
        cv.restore();
    }

    pub fn moving(self: *const Lyrics) bool {
        return self.show.moving() or self.pop.moving() or self.scroll.moving();
    }
};
