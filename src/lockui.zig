// ロック画面の見た目(iOS / iPadOS のロック画面のような構成)。状態と認証は lock.zig、ここは描くだけ。
//
//  眺める画面(auth = 0)        : くっきりした壁紙・日付・特大の時計・電池、再生中の曲(回るレコードと
//                                 液体のスペクトラム・操作ボタン)、ロック中に来た通知のスタック、
//                                 下に光が流れる「解除するには…」とホームバー
//  入力画面(auth = 1)          : 背景がぼけて暗くなり、時計は小さく上へ。写真・名前・ガラスの入力欄
//  解除(unlock_s 0 → 1)        : 全体が少し拡大しながら消え、背景のぼかしも消えてデスクトップへ
//
// 大きさは論理 px。アニメーションはすべてバネ(anim.zig、計算は Odin)。
const std = @import("std");
const c = @import("c.zig");
const anim = @import("anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("gfx.zig");
const theme = @import("theme.zig");
const bar = @import("bar.zig");
const data = @import("frame/data.zig");
const lockmod = @import("lock.zig");
const Lock = lockmod.Lock;
const App = @import("app.zig").App;
const Surface = @import("surface.zig").Surface;

const white = Color.hex(0xffffff);
const black = Color.hex(0x000000);

const I_LOCK = "\u{F033E}";
const I_UNLOCK = "\u{F0FC6}";
const I_PLAY = "\u{F040A}";
const I_PAUSE = "\u{F03E4}";
const I_PREV = "\u{F04AE}";
const I_NEXT = "\u{F04AD}";
const I_BELL = "\u{F009A}";
const I_BOLT = "\u{F140B}";
const I_MUSIC = "\u{F075A}";
const I_VOL_HI = "\u{F057E}";
const I_VOL_MID = "\u{F0580}";
const I_VOL_LO = "\u{F057F}";
const I_VOL_OFF = "\u{F0581}";
const I_VOL_MUTE = "\u{F075F}";

fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0, 1);
}

/// 出てくる順をずらす(i 番目は少し遅れて 0 → 1)
fn stagger(t: f32, i: f32) f32 {
    const d = i * 0.08;
    return clamp01((t - d) / (1 - d));
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn inRect(r: [4]f32, x: f32, y: f32) bool {
    return r[2] > 0 and x >= r[0] and x <= r[0] + r[2] and y >= r[1] and y <= r[1] + r[3];
}

/// クリックできる場所(描くたびに作り直す。座標は surface の論理 px)
pub const Hits = struct {
    prev: [4]f32 = .{ 0, 0, 0, 0 },
    play: [4]f32 = .{ 0, 0, 0, 0 },
    next: [4]f32 = .{ 0, 0, 0, 0 },
    stack: [4]f32 = .{ 0, 0, 0, 0 },
    // 曲のカード: カード全体(ホイールで音量)・音量のバー・スピーカー(消音)・再生位置のバー
    card: [4]f32 = .{ 0, 0, 0, 0 },
    vol: [4]f32 = .{ 0, 0, 0, 0 },
    mute: [4]f32 = .{ 0, 0, 0, 0 },
    seek: [4]f32 = .{ 0, 0, 0, 0 },
    // ログイン画面だけ: ユーザーの切り替え・セッション・再起動・電源オフ
    uprev: [4]f32 = .{ 0, 0, 0, 0 },
    unext: [4]f32 = .{ 0, 0, 0, 0 },
    session: [4]f32 = .{ 0, 0, 0, 0 },
    reboot: [4]f32 = .{ 0, 0, 0, 0 },
    poweroff: [4]f32 = .{ 0, 0, 0, 0 },

    pub const Hit = enum { none, prev, play, next, stack, uprev, unext, session, reboot, poweroff };
    pub fn which(self: *const Hits, x: f32, y: f32) Hit {
        if (inRect(self.uprev, x, y)) return .uprev;
        if (inRect(self.unext, x, y)) return .unext;
        if (inRect(self.session, x, y)) return .session;
        if (inRect(self.reboot, x, y)) return .reboot;
        if (inRect(self.poweroff, x, y)) return .poweroff;
        if (inRect(self.prev, x, y)) return .prev;
        if (inRect(self.play, x, y)) return .play;
        if (inRect(self.next, x, y)) return .next;
        if (inRect(self.stack, x, y)) return .stack;
        return .none;
    }
};

/// ロック中に来た通知 1 件ぶんの出入りのアニメーション
pub const Card = struct {
    id: u32 = 0,
    s: Spring = Spring.init(0, 0.42, 0.78),
};

/// 1 枚の出力を描く。アニメーションが続くなら true
pub fn draw(self: *Lock, s: *Surface, out_backdrop: ?*gfx.Backdrop, cv: *gfx.Canvas, primary: bool, dt: f32) bool {
    const app = self.app;
    var animating = false;
    const W: f32 = @floatFromInt(s.width);
    const H: f32 = @floatFromInt(s.height);
    const acc = theme.accent(app);
    const txt = theme.text(app);
    const sub = theme.subtext(app);
    const playing = app.media.status == .playing;
    // ログイン画面には曲も通知も出さない
    const has_media = !self.greeter and app.media.status != .none;
    // 同期した歌詞(lyrics.zig)。曲のカードの下に、前・今・次の行を出す
    const lcur = if (has_media) app.media.lyrics.current(app.media.position()) else @TypeOf(app.media.lyrics.current(0)){ .idx = null, .frac = 0 };

    if (primary) {
        self.time_s += dt;
        if (playing) {
            self.vinyl += dt * std.math.tau / 8.0;
            if (self.vinyl > std.math.tau) self.vinyl -= std.math.tau;
        }
        self.media_s.set(if (has_media) 1 else 0);
        self.play_s.set(if (playing) 1 else 0);
        self.expand.set(if (self.notif_expanded) 1 else 0);
        // 同期歌詞があれば出す(前奏・間奏で今の行が無いときは「♪」)
        self.lyr_s.set(if (has_media and app.media.lyrics.state == .synced) 1 else 0);
        const new_idx: i32 = if (lcur.idx) |li| @intCast(li) else -1;
        if (new_idx != self.lyr_idx) {
            // 1 行進んだときだけ押し上げる(シークで飛んだときは、その場で並べ直す)
            self.lk_scroll.snap(if (self.lyr_idx >= 0 and new_idx == self.lyr_idx + 1) 1 else 0);
            self.lk_scroll.set(0);
            self.lk_pop.snap(0);
            self.lk_pop.set(1);
            self.lyr_idx = new_idx;
        }
        var springs = [_]*Spring{ &self.auth, &self.media_s, &self.play_s, &self.expand, &self.ring, &self.lyr_s, &self.lk_pop, &self.lk_scroll };
        if (anim.stepAll(&springs, dt)) animating = true;
        // 歌詞を出している間は、ダッシュボードと同じく 3 秒おきに本当の再生位置を聞いてずれを直す
        // (シークを知らせないプレイヤーがあり、そのままだと違う行を指したままになる)
        if (has_media and app.media.lyrics.state == .synced) app.media.resyncPosition();
        for (&self.cards) |*cd| if (cd.id != 0 and cd.s.step(dt)) {
            animating = true;
        };
    } else {
        animating = self.auth.moving() or self.media_s.moving() or self.play_s.moving() or self.expand.moving();
    }
    // 光が流れる文字・レコードは動き続ける(眺める画面のときだけ)
    if (self.auth.x < 0.99) animating = true;
    if (self.busy) animating = true;

    const appear = self.appear.x;
    const un = self.unlock_s.x;
    const a = self.auth.x;
    const t = appear * (1 - un);

    // ---- 背景: くっきりした壁紙 → 入力画面・解除でぼける ----
    cv.rect(0, 0, W, H, 0, Color.hex(0x050a18));
    if (out_backdrop) |bd| {
        if (bd.scene.tex != 0) {
            // FBO の絵は下から上なので上下を反転して貼る
            cv.imageEx(bd.scene.tex, 0, 0, W, H, 0, .{ 0, 1, 1, 0 }, 0, 0, 1, 1);
        }
    }
    {
        // ぼかし: 現れるときに少し、入力画面で強く。解除で消える
        // ログイン画面は全体をすりガラスにして、真ん中の穴からだけ壁紙を見せる(下の portal)
        const blur = if (self.greeter) 1.0 else clamp01(0.25 * (1 - appear) + a * 0.95) * (1 - un);
        if (blur > 0.01) {
            cv.save();
            cv.opacity(blur);
            var gl = theme.glass(app);
            gl.tint.a = 0.30;
            gl.rim.a = 0;
            gl.refraction = 0;
            gl.sparkle = 1.0;
            cv.glass(0, 0, W, H, 0, gl);
            cv.restore();
        }
        // 文字を読みやすく: 上と下を少し暗く(入力画面ではさらに全体を)
        cv.rectGrad(0, 0, W, H * 0.45, 0, black.alpha(0.28 * (1 - un)), black.alpha(0));
        cv.rectGrad(0, H * 0.6, W, H * 0.4, 0, black.alpha(0), black.alpha(0.38 * (1 - un)));
        if (self.greeter) {
            cv.rect(0, 0, W, H, 0, black.alpha(0.30));
        } else {
            cv.rect(0, 0, W, H, 0, black.alpha((0.22 * a + 0.3 * (1 - appear)) * (1 - un)));
        }
    }
    if (self.greeter) if (out_backdrop) |bd| portal(self, cv, bd, W, H, acc, appear, a, un);

    // ログイン画面用に、入力画面の背景(ぼかした壁紙)を 1 回だけ書き出す(sddmshare.zig)
    if (primary and !self.sddm_saved and appear > 0.999 and a > 0.999 and !self.unlocking) {
        self.sddm_saved = true;
        cv.flush();
        @import("sddmshare.zig").saveFramebuffer(0, @intFromFloat(W * cv.scale), @intFromFloat(H * cv.scale), acc, true);
    }

    // 解除: 全体が少し拡大しながら消える
    cv.save();
    cv.scaleAbout(W / 2, H / 2, 1 + un * 0.08);
    cv.opacity(t);

    // ---- 上: 鍵のアイコン(解除で開く) ----
    {
        const ly: f32 = 44 + (1 - stagger(appear, 0)) * -20;
        const open = un > 0.05 or self.unlocking;
        _ = cv.text(W / 2, ly, 20, white.alpha(0.92), if (open) I_UNLOCK else I_LOCK, .{ .alignment = .center });
    }

    // ---- 日付と時計(入力画面では小さく上へ)----
    const clock_scale = lerp(1, 0.46, a);
    const date_y = lerp(H * 0.14, 90, a);
    {
        var db: [64]u8 = undefined;
        const tm = bar.localTime();
        const date = std.fmt.bufPrint(&db, "{d}月{d}日 {s}曜日", .{ @as(u32, @intCast(tm.tm_mon + 1)), @as(u32, @intCast(tm.tm_mday)), bar.weekdays_ja[@intCast(tm.tm_wday)] }) catch "";
        const e0 = stagger(appear, 1);
        cv.save();
        cv.opacity(e0 * (1 - a * 0.25));
        _ = cv.text(W / 2, date_y + (1 - e0) * -16, 21 * lerp(1, 0.8, a), white.alpha(0.88), date, .{ .bold = true, .alignment = .center });
        cv.restore();

        var cb: [16]u8 = undefined;
        const clock = bar.formatClock(&cb, app.cfg.clock_24h, false);
        const e1 = stagger(appear, 2);
        const cy = date_y + 128 * clock_scale + (1 - e1) * -24;
        cv.save();
        cv.opacity(e1);
        cv.scaleAbout(W / 2, cy, clock_scale);
        // 息をするようにごくわずかに光る
        const breathe = 0.5 + 0.08 * @sin(self.time_s * 1.2);
        _ = cv.text(W / 2, cy, 132, white.alpha(0.97), clock, .{ .bold = true, .alignment = .center, .glow = 18, .glow_color = acc.alpha(breathe) });
        cv.restore();
    }

    // ---- 電池(時計の下の小さな丸い札)----
    const bat = app.sys.battery;
    var widgets_y: f32 = H * 0.14 + 160;
    if (bat.present) {
        const e = stagger(appear, 3) * (1 - a);
        if (e > 0.01) {
            var bb: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&bb, "{d}%", .{bat.percent}) catch "";
            const lw = cv.measure(label, 14, true);
            const pw: f32 = lw + 62;
            const px = W / 2 - pw / 2;
            const py = widgets_y + (1 - e) * 12;
            cv.save();
            cv.opacity(e);
            cv.glass(px, py, pw, 30, 15, theme.glass(app));
            // 電池の形
            const bx = px + 14;
            const by = py + 9;
            cv.rectBorder(bx, by, 24, 12, 3, .{ .a = 0 }, white.alpha(0.8), 1.2);
            cv.rect(bx + 24.5, by + 3.5, 2, 5, 1, white.alpha(0.8));
            const fill = @as(f32, @floatFromInt(bat.percent)) / 100;
            const fcol = if (bat.charging) Color.hex(0x5ee07a) else if (bat.percent <= 20) theme.danger(app) else white.alpha(0.9);
            cv.rect(bx + 2, by + 2, 20 * fill, 8, 1.5, fcol);
            if (bat.charging) _ = cv.text(bx + 12, by + 10.5, 10, black.alpha(0.7), I_BOLT, .{ .alignment = .center });
            _ = cv.text(px + 46, py + 20, 14, white.alpha(0.92), label, .{ .bold = true });
            cv.restore();
        }
        widgets_y += 46;
    }

    // ---- 再生中の曲: 右下の小さなカード + その上に歌詞(ダッシュボードと同じ見せ方) ----
    //   時計・通知は中央の列、曲は右下の列に分けて重ならないようにする。狭い画面では時計の下の中央に置く
    self.hits = .{};
    const card_w: f32 = @min(440, W - 48);
    const cx0 = W / 2 - card_w / 2;
    var y_next: f32 = @max(widgets_y + 14, H * 0.38);
    const m_e = self.media_s.x * stagger(appear, 4) * (1 - a);
    if (m_e > 0.01) {
        const k = std.math.clamp(@min(W / 1280, H / 800), 0.8, 1.3);
        const margin: f32 = 32 * k;
        // 右の列に置けるか(中央の列 = 通知のカードの幅の半分 + 余白 を避ける)
        const side_w = W / 2 - card_w / 2 - margin - 24;
        const corner = side_w >= 300 * k;
        const pw: f32 = if (corner) @min(400 * k, side_w) else @min(400 * k, W - 40);
        const art: f32 = 84 * k;
        const pad: f32 = 16 * k;
        // 下に音量の行
        const vrow: f32 = 30 * k;
        const ch: f32 = art + pad * 2 + vrow;
        const rad: f32 = 24 * k;
        const px0 = if (corner) W - margin - pw else W / 2 - pw / 2;
        const cy_base = if (corner) H - 64 * k - ch else y_next;
        const cy0 = cy_base + (1 - m_e) * 30;
        const ps = self.play_s.x;
        cv.save();
        cv.opacity(m_e);
        cv.scaleAbout(px0 + pw / 2, cy0 + ch / 2, lerp(0.92, 1, m_e));
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
            const vals: []const f32 = if (self.spectrum.running()) &self.spectrum.values else &zeros;
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
        {
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
        cv.restore();

        // ---- 歌詞: カードの上に浮かべる。ダッシュボードと同じく、歌い終えた行が 1 行ずつ上へ積み上がり、
        //      今の行は下でポンと弾んで出る(これから歌う行は見せない)----
        if (self.lyr_s.x > 0.01 and app.media.lyrics.lines.items.len > 0) {
            const ls = app.media.lyrics.lines.items;
            const has_cur = lcur.idx != null;
            const ci = lcur.idx orelse 0;
            const big: f32 = 21 * k;
            const small: f32 = 15 * k;
            const lgap: f32 = 10 * k;
            const max_w = pw;
            const mid = px0 + pw / 2;

            const pop = self.lk_pop.x;
            const sc = self.lk_scroll.x;
            const text_of = struct {
                fn get(l: anytype, i: usize) []const u8 {
                    if (i >= l.len) return "";
                    return if (l[i].text.len > 0) l[i].text else "♪";
                }
            }.get;
            const cur_s = if (has_cur) text_of(ls, ci) else "♪";
            const n0: f32 = @floatFromInt(cv.wrapCount(cur_s, big, max_w, 2));
            // 今の行の下端をカードの少し上に
            const cur_bottom = cy0 - 18 * k;
            const base_y = cur_bottom - (n0 - 1) * big * 1.32 - big * 0.3;
            const cur_top = base_y - big * 0.9;
            const shift = (cur_bottom - cur_top) + lgap;
            const top_limit = H * 0.42; // ここより上は時計・電池の列
            cv.save();
            cv.opacity(m_e * self.lyr_s.x);
            // 壁紙の上でも読めるよう、歌詞の列の後ろにぼんやりした影を敷く
            cv.shadow(px0 + 10 * k, top_limit + 40 * k, pw - 20 * k, cur_bottom - top_limit - 30 * k, 40 * k, 60 * k, black.alpha(0.42));
            // 歌い終えた行(新しい順に上へ。古いほど薄く、上の端で消える)
            var bottom = cur_top - lgap;
            var kk: usize = 1;
            while (has_cur and kk <= ci and kk <= 4) : (kk += 1) {
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
        // 狭い画面(中央に置いたとき)だけ、通知をカードの下へずらす
        if (!corner) y_next += (ch + 20) * self.media_s.x;
    }

    // ---- 通知(ロック中に来たもの。新しい順に重ねる。押すと広げる)----
    var shown: [6]*const @import("notify.zig").Notif = undefined;
    var ns: usize = 0;
    for (app.notifs.history.items) |*n| {
        if (self.greeter) break; // ログイン画面には出さない
        if (n.id < self.first_notif_id) break;
        if (ns >= shown.len) break;
        shown[ns] = n;
        ns += 1;
    }
    const n_e = stagger(appear, 5) * (1 - a);
    if (ns > 0 and n_e > 0.01) {
        const ex = self.expand.x;
        const card_h: f32 = 88;
        var y = y_next;
        const stack_top = y;
        // 重ねたときに見える枚数(2 枚目・3 枚目は下からのぞく)
        var i: usize = ns;
        while (i > 0) {
            i -= 1;
            const n = shown[i];
            const appear_s = self.cardSpring(n.id);
            const fi: f32 = @floatFromInt(i);
            // 広げたとき: 縦に並ぶ / 重ねたとき: 1 枚目の下に 8px ずつのぞく(3 枚まで)
            const peek_y = stack_top + @min(fi, 2) * 9;
            const list_y = stack_top + fi * (card_h + 10);
            const yy = lerp(peek_y, list_y, ex) + (1 - appear_s) * 40;
            const sc = lerp(1 - @min(fi, 2) * 0.05, 1, ex);
            const vis = if (i < 3) 1 else ex;
            const al = n_e * appear_s * vis * (if (i == 0) 1 else lerp(0.75, 1, ex));
            if (al < 0.01) continue;
            cv.save();
            cv.opacity(al);
            cv.scaleAbout(W / 2, yy + card_h / 2, sc);
            cv.shadow(cx0, yy + 6, card_w, card_h, 20, 18, black.alpha(0.25));
            cv.glass(cx0, yy, card_w, card_h, 20, theme.glassStrong(app));
            // 重ねて隠れている分は中身を描かない
            if (i == 0 or ex > 0.3) {
                const ia = if (i == 0) 1 else clamp01((ex - 0.3) / 0.7);
                cv.save();
                cv.opacity(ia);
                // アプリのアイコン(ランチャーの索引から。無ければベル)
                const ix = cx0 + 16;
                const iy = yy + 15;
                var drew = false;
                if (app.launcher.findApp(n.appName())) |e| {
                    const tex = app.launcher.entryIcon(e);
                    if (tex != 0) {
                        cv.image(tex, ix, iy, 22, 22, 6);
                        drew = true;
                    }
                }
                if (!drew) {
                    cv.rect(ix, iy, 22, 22, 6, acc.alpha(0.85));
                    _ = cv.text(ix + 11, iy + 16, 13, white, I_BELL, .{ .alignment = .center });
                }
                _ = cv.text(ix + 32, iy + 15, 12, white.alpha(0.65), n.appName(), .{ .max_w = card_w - 140 });
                _ = cv.text(cx0 + card_w - 16, iy + 15, 11.5, white.alpha(0.55), n.time_str[0..5], .{ .alignment = .right });
                _ = cv.text(cx0 + 16, yy + 53, 14.5, white.alpha(0.95), n.summaryText(), .{ .bold = true, .max_w = card_w - 32 });
                if (n.body_len > 0) {
                    var lb: [256]u8 = undefined;
                    _ = cv.text(cx0 + 16, yy + 73, 13.5, white.alpha(0.72), firstLine(n.bodyText(), &lb), .{ .max_w = card_w - 32 });
                }
                cv.restore();
            }
            cv.restore();
        }
        const stack_h = lerp(card_h + @min(@as(f32, @floatFromInt(ns - 1)), 2) * 9, @as(f32, @floatFromInt(ns)) * (card_h + 10) - 10, ex);
        self.hits.stack = .{ cx0, stack_top, card_w, stack_h };
        if (ns > 1 and ex < 0.5) {
            var cb: [32]u8 = undefined;
            _ = cv.text(W / 2, stack_top + stack_h + 22, 12, white.alpha(0.6 * (1 - ex * 2)), std.fmt.bufPrint(&cb, "ほか {d} 件の通知", .{ns - 1}) catch "", .{ .alignment = .center });
        }
        y = stack_top + stack_h;
    }

    // ---- 入力画面: 写真・名前・ガラスの入力欄 ----
    if (a > 0.01) {
        const e = a;
        const base_y = H * 0.42 + (1 - e) * 40;
        cv.save();
        cv.opacity(e);
        const az: f32 = 92;
        const ax = W / 2 - az / 2;
        const ay = base_y;
        const av = app.avatar.texture();
        cv.shadow(ax, ay + 8, az, az, az / 2, 22, black.alpha(0.45));
        if (av != 0) {
            cv.image(av, ax, ay, az, az, az / 2);
        } else {
            cv.rect(ax, ay, az, az, az / 2, acc.alpha(0.6));
            var ub0: [64]u8 = undefined;
            const uname0 = self.userName(&ub0);
            if (uname0.len > 0) _ = cv.text(W / 2, ay + az / 2 + 14, 40, white, uname0[0..1], .{ .bold = true, .alignment = .center });
        }
        // 縁: 確認中は回る弧
        if (self.busy) {
            const p = 0.2 + 0.6 * (0.5 + 0.5 * @sin(self.time_s * 3));
            cv.arc(W / 2, ay + az / 2, az / 2 + 6, 3, p, acc.lighten(0.2), white.alpha(0.12));
        } else {
            cv.rectBorder(ax - 3, ay - 3, az + 6, az + 6, az / 2 + 3, .{ .a = 0 }, acc.alpha(0.85), 2.5);
        }
        var ub: [64]u8 = undefined;
        const user = self.userName(&ub);
        _ = cv.text(W / 2, ay + az + 34, 20, txt, user, .{ .bold = true, .alignment = .center });
        // ログイン画面: 写真の左右の ‹ › でユーザーを切り替え
        if (self.greeter and @import("greeter.zig").st.n_users > 1) {
            const mid = ay + az / 2;
            _ = cv.text(ax - 34, mid + 10, 30, white.alpha(0.75), "‹", .{ .alignment = .center });
            _ = cv.text(ax + az + 34, mid + 10, 30, white.alpha(0.75), "›", .{ .alignment = .center });
            self.hits.uprev = .{ ax - 54, mid - 24, 40, 48 };
            self.hits.unext = .{ ax + az + 14, mid - 24, 40, 48 };
        }

        // 入力欄
        const fw: f32 = 300;
        const fh: f32 = 50;
        const fx = W / 2 - fw / 2 + self.shake.x;
        const fy = ay + az + 56;
        cv.shadow(fx, fy + 8, fw, fh, fh / 2, 22, theme.shadow());
        cv.glass(fx, fy, fw, fh, fh / 2, theme.glassStrong(app));
        cv.rectBorder(fx, fy, fw, fh, fh / 2, .{ .a = 0 }, if (self.msg_len > 0 and self.isError()) theme.danger(app).alpha(0.8) else white.alpha(0.22), 1.2);
        const n = @min(countChars(self.pw[0..self.pw_len]), self.dots.len);
        if (n == 0 and !self.busy) {
            // 点滅するカーソルと案内
            const blink: f32 = if (@mod(self.time_s, 1.1) < 0.6) 1 else 0;
            cv.rect(W / 2 - 1, fy + 14, 2, fh - 28, 1, acc.alpha(0.9 * blink));
            _ = cv.text(W / 2 + 8, fy + fh / 2 + 5, 13.5, sub.alpha(0.6), "パスワード", .{});
        }
        const spacing: f32 = 18;
        const shown_dots = @min(n + 1, self.dots.len);
        const total = @as(f32, @floatFromInt(n)) * spacing;
        for (0..shown_dots) |i| {
            const d = self.dots[i].x;
            if (d < 0.01) continue;
            const dx = fx + fw / 2 - total / 2 + @as(f32, @floatFromInt(i)) * spacing + spacing / 2;
            const rr = 5 * d;
            cv.rect(dx - rr, fy + fh / 2 - rr, rr * 2, rr * 2, rr, white.alpha(0.95));
        }
        if (self.msg_len > 0) {
            _ = cv.text(W / 2, fy + fh + 30, 13.5, if (self.isError()) theme.danger(app).lighten(0.25) else sub, self.msg[0..self.msg_len], .{ .alignment = .center });
        }
        cv.restore();
    }

    // ---- 下: 光が流れる案内とホームバー ----
    {
        const e = stagger(appear, 6);
        const hint = if (a > 0.5) "Esc でもどる" else if (self.greeter) "キーを押すかクリックしてログイン" else "キーを押すかクリックしてロックを解除";
        const hy = H - 46 + (1 - e) * 16;
        shimmer(cv, W / 2, hy, 14, hint, self.time_s, e);
        cv.rect(W / 2 - 67, H - 16, 134, 5, 2.5, white.alpha(0.75 * e));
        if (self.greeter) greeterBar(self, cv, W, H, e);
    }

    cv.restore();
    return animating;
}

/// ログイン画面の下の隅: 左にセッション(押すと切り替え)、右に再起動・電源オフ
fn greeterBar(self: *Lock, cv: *gfx.Canvas, W: f32, H: f32, e: f32) void {
    const g = @import("greeter.zig");
    const app = self.app;
    cv.save();
    cv.opacity(e);
    const ph: f32 = 32;
    const y = H - 24 - ph;
    if (g.st.n_sessions > 0) {
        var sb: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&sb, "{s}{s}", .{ g.sessionName(), if (g.st.n_sessions > 1) "  ⇄" else "" }) catch "";
        const w = cv.measure(label, 13, false) + 28;
        cv.glass(24, y, w, ph, ph / 2, theme.glass(app));
        _ = cv.text(24 + 14, y + 21, 13, white.alpha(0.85), label, .{});
        self.hits.session = .{ 24, y, w, ph };
    }
    const labels = [_][]const u8{ "\u{F0709}  再起動", "\u{F0425}  電源オフ" };
    var x = W - 24;
    for (labels, 0..) |l, i| {
        const w = cv.measure(l, 13, false) + 28;
        x -= w;
        cv.glass(x, y, w, ph, ph / 2, theme.glass(app));
        _ = cv.text(x + 14, y + 21, 13, white.alpha(0.85), l, .{});
        if (i == 0) self.hits.reboot = .{ x, y, w, ph } else self.hits.poweroff = .{ x, y, w, ph };
        x -= 10;
    }
    cv.restore();
}

/// ログイン画面の穴: すりガラスの真ん中に丸い穴があき、そこからだけくっきりした壁紙が見える。
/// 入力画面では写真の後ろへ移って、写真を囲む壁紙の輪になる。ログインに成功すると穴が画面いっぱいに
/// 広がり、中の壁紙は拡大した状態から等倍へ戻っていく(穴を抜けてホームへ出るように)
fn portal(self: *Lock, cv: *gfx.Canvas, bd: *gfx.Backdrop, W: f32, H: f32, acc: Color, appear: f32, a: f32, un: f32) void {
    if (bd.scene.tex == 0) return;
    // 穴の中心と半径: 眺める画面 → 入力画面(写真の中心。lockui の入力画面と同じ位置)→ 解除で画面全体
    const idle_r = @min(W, H) * 0.17 * (1 + 0.025 * @sin(self.time_s * 1.4));
    const auth_cy = H * 0.42 + 46;
    var cx = W / 2;
    var cy = lerp(H * 0.55, auth_cy, a);
    var r = lerp(idle_r, 46 + 18, a) * appear;
    const full = @sqrt(W * W + H * H) / 2 + 8;
    // 解除: 少しためてから一気に広がる(バネの値を二乗して出だしを遅く)
    const e = un * un;
    cx = lerp(cx, W / 2, e);
    cy = lerp(cy, H / 2, e);
    r = lerp(r, full, e);
    if (r < 1) return;
    // 穴の外側にアクセント色の光
    cv.shadow(cx - r, cy - r, r * 2, r * 2, r, 34, acc.alpha(0.45 * (1 - e)));
    // 中の壁紙: 拡大(1.35 倍)から等倍へ。穴の位置に対応する部分を切り出す(FBO は下から上)
    const zoom = lerp(1.35, 1.0, e);
    const hw = r / zoom;
    const ua = (cx - hw) / W;
    const ub = (cx + hw) / W;
    const v_top = 1 - (cy - hw) / H;
    const v_bot = 1 - (cy + hw) / H;
    cv.imageEx(bd.scene.tex, cx - r, cy - r, r * 2, r * 2, r, .{ ua, v_top, ub, v_bot }, 0, 0, 1, 1);
    // 縁: 細い光の輪(広がるにつれて消える)
    cv.rectBorder(cx - r, cy - r, r * 2, r * 2, r, .{ .a = 0 }, white.alpha(0.35 * (1 - e)), 1.5);
}

/// 文字の上を光が左から右へ流れる(iOS の「スライドでロック解除」)
fn shimmer(cv: *gfx.Canvas, cx: f32, y: f32, size: f32, str: []const u8, time: f32, alpha: f32) void {
    const total = cv.measure(str, size, false);
    var x = cx - total / 2;
    const sweep = @mod(time * 0.45, 1.6) - 0.3; // -0.3 〜 1.3
    var it = std.unicode.Utf8View.initUnchecked(str).iterator();
    while (it.nextCodepointSlice()) |ch| {
        const w = cv.measure(ch, size, false);
        const pos = (x + w / 2 - (cx - total / 2)) / total;
        const d = @abs(pos - sweep);
        const glow = clamp01(1 - d / 0.18);
        _ = cv.text(x, y, size, white.alpha((0.55 + 0.45 * glow) * alpha), ch, .{});
        x += w;
    }
}

fn firstLine(s: []const u8, buf: []u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    const n = @min(end, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

fn countChars(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if ((ch & 0xC0) != 0x80) n += 1;
    }
    return n;
}
