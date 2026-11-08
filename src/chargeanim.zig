// 充電器をつないだ・外したときの、画面全体のアニメーション(iPhone の MagSafe のように)。
//
// つないだとき:
//   1. 画面が少し暗くなり、真ん中から光の輪(衝撃波)が画面の端へ広がる
//   2. 真ん中にリングがポンと現れ、0 から今の残り % まで光りながら満ちる。中に稲妻と % の数字
//   3. 少し見せてから、縮みながら消える(全部で約 2.8 秒)
// 外したとき:
//   1. 画面の端から光の輪が真ん中へ吸い込まれる(つないだときの逆)
//   2. 満ちたリングの緑が抜けて白くなり、中の稲妻が電池の形に替わる
//   3. 縮みながら消える(全部で約 2.2 秒)
// アニメーションを出すときは、抜き差しの通知は出さない(syswatch.zig)。
//
// ロック中はロック画面(lockui.zig)がその上に描き、それ以外は全面の OVERLAY のサーフェスを出す
// (クリック・キーは下の窓へそのまま通す。終わったらサーフェスごと消す)。
// 設定: shell { charge-animation off } で出さない。試験: AME_DEBUG=1 で ame-ctl debug-battery 60 ac
const std = @import("std");
const anim = @import("anim.zig");
const Color = anim.Color;
const appmod = @import("app.zig");
const App = appmod.App;
const Output = appmod.Output;
const c = @import("c.zig");
const gfx = @import("gfx.zig");
const theme = @import("theme.zig");
const surface = @import("surface.zig");
const Surface = surface.Surface;

pub const Kind = enum(u8) { plug, unplug };

/// 全体の長さ(秒)
pub const DURATION: f32 = 2.8;
pub const DURATION_UNPLUG: f32 = 2.2;

pub fn duration(k: Kind) f32 {
    return if (k == .plug) DURATION else DURATION_UNPLUG;
}

const white = Color.hex(0xffffff);
const black = Color.hex(0x000000);
const I_BOLT = "\u{F140B}";

fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0, 1);
}

fn easeOutCubic(x: f32) f32 {
    const t = 1 - clamp01(x);
    return 1 - t * t * t;
}

/// 少し行き過ぎて戻る(ポンと出る)
fn easeOutBack(x: f32) f32 {
    const t = clamp01(x) - 1;
    const s: f32 = 1.9;
    return 1 + t * t * ((s + 1) * t + s);
}

/// 充電の色: 少ないときは黄色、あとは緑(iPhone と同じ考え)
fn chargeColor(pct: u8) Color {
    return if (pct <= 20) Color.hex(0xffd60a) else Color.hex(0x34c759);
}

/// t 秒目の絵を W×H の全面に描く。pct は残り %
pub fn draw(cv: *gfx.Canvas, W: f32, H: f32, t: f32, pct: u8, kind: Kind) void {
    if (kind == .unplug) return drawUnplug(cv, W, H, t, pct);
    drawPlug(cv, W, H, t, pct);
}

fn drawPlug(cv: *gfx.Canvas, W: f32, H: f32, t: f32, pct: u8) void {
    if (t < 0 or t > DURATION) return;
    const k = @min(W, H) / 800;
    const cx = W / 2;
    const cy = H / 2;
    const col = chargeColor(pct);
    const glow = col.lighten(0.35);
    // 出ている割合(入り 0.35 秒・出 0.6 秒)
    const in_ = easeOutCubic(t / 0.35);
    const out = 1 - easeOutCubic((t - (DURATION - 0.6)) / 0.6);
    const vis = in_ * out;

    // 1. 背景を暗く + 真ん中のぼんやりした光
    cv.rect(0, 0, W, H, 0, black.alpha(0.5 * vis));
    const R: f32 = 120 * k;
    const bloom = R * 3.2;
    cv.shadow(cx - bloom / 2, cy - bloom / 2, bloom, bloom, bloom / 2, 160 * k, col.alpha(0.16 * vis));

    // 衝撃波: 真ん中から画面の端へ広がる光の輪(最初の 1.1 秒)
    const sw = t / 1.1;
    if (sw < 1) {
        const far = @sqrt(W * W + H * H) / 2;
        const r = R * 0.6 + (far - R * 0.6) * easeOutCubic(sw);
        const a = (1 - sw) * (1 - sw);
        cv.arc(cx, cy, r, 26 * k, 1, glow.alpha(0.10 * a), .{ .a = 0 });
        cv.arc(cx, cy, r, 6 * k, 1, glow.alpha(0.55 * a), .{ .a = 0 });
    }

    // 2. リング: ポンと出て、0 → 残り % まで満ちる。最後は縮みながら消える
    const pop = easeOutBack(t / 0.55);
    const shrink = 1 - 0.15 * (1 - out);
    const rr = R * (0.55 + 0.45 * pop) * shrink;
    const fill = @as(f32, @floatFromInt(pct)) / 100 * easeOutCubic((t - 0.15) / 1.0);
    cv.save();
    cv.opacity(clamp01(vis));
    // 溝
    cv.arc(cx, cy, rr, 14 * k, 1, white.alpha(0.13), .{ .a = 0 });
    // 光のにじみ(太く薄く)→ 本体
    cv.arc(cx, cy, rr + 2 * k, 20 * k, fill, col.alpha(0.18), .{ .a = 0 });
    cv.arc(cx, cy, rr, 14 * k, fill, col, .{ .a = 0 });
    // 満ちていく先端の光
    if (fill > 0.005) {
        const ang = fill * std.math.tau - std.math.pi / 2.0;
        const hx = cx + @cos(ang) * rr;
        const hy = cy + @sin(ang) * rr;
        const hs = 30 * k;
        cv.shadow(hx - hs / 2, hy - hs / 2, hs, hs, hs / 2, 18 * k, glow.alpha(0.9));
    }

    // 中: 稲妻と %(少し遅れて浮かぶ)
    const te = easeOutCubic((t - 0.2) / 0.5);
    cv.save();
    cv.opacity(te);
    cv.translate(0, (1 - te) * 10 * k);
    _ = cv.text(cx, cy - 22 * k, 34 * k * shrink, col, I_BOLT, .{ .alignment = .center });
    // 数字は満ちていくリングに合わせて数え上がる
    const shown: u32 = @intFromFloat(@round(fill * 100));
    var pb: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&pb, "{d}%", .{if (t > 1.2) pct else @as(u8, @intCast(@min(shown, pct)))}) catch "";
    _ = cv.text(cx, cy + 40 * k, 46 * k * shrink, white, ps, .{ .bold = true, .alignment = .center });
    cv.restore();
    cv.restore();
}

/// 外したとき: 光の輪が画面の端から真ん中へ吸い込まれ、リングの緑が抜けて白くなる。稲妻は電池の形に
fn drawUnplug(cv: *gfx.Canvas, W: f32, H: f32, t: f32, pct: u8) void {
    const D = DURATION_UNPLUG;
    if (t < 0 or t > D) return;
    const k = @min(W, H) / 800;
    const cx = W / 2;
    const cy = H / 2;
    const green = chargeColor(pct);
    // 緑 → 白(電源から離れた)。少ないときは最後に少し赤みを残す
    const rest = if (pct <= 20) Color.hex(0xff9f0a) else Color.hex(0xf2f4f8);
    const drain = easeOutCubic((t - 0.5) / 0.9);
    const col = Color.mix(green, rest, drain);
    const in_ = easeOutCubic(t / 0.3);
    const out = 1 - easeOutCubic((t - (D - 0.55)) / 0.55);
    const vis = in_ * out;

    // 1. 背景を少し暗く(つないだときより控えめ)+ 真ん中のぼんやりした光が消えていく
    cv.rect(0, 0, W, H, 0, black.alpha(0.42 * vis));
    const R: f32 = 120 * k;
    const bloom = R * 3.0;
    cv.shadow(cx - bloom / 2, cy - bloom / 2, bloom, bloom, bloom / 2, 160 * k, green.alpha(0.14 * vis * (1 - drain)));

    // 吸い込まれる光の輪: 画面の端から真ん中へ(最初の 0.8 秒)
    const sw = t / 0.8;
    if (sw < 1) {
        const far = @sqrt(W * W + H * H) / 2;
        const e = easeOutCubic(sw);
        const r = far - (far - R * 1.05) * e;
        const a = @sin(clamp01(sw) * std.math.pi);
        cv.arc(cx, cy, r, 22 * k, 1, rest.alpha(0.08 * a), .{ .a = 0 });
        cv.arc(cx, cy, r, 5 * k, 1, rest.alpha(0.45 * a), .{ .a = 0 });
    }

    // 2. リング: 満ちたまま現れ、吸い込まれた輪がぶつかると小さく揺れて色が抜ける
    const bump = if (t > 0.7 and t < 1.1) @sin((t - 0.7) / 0.4 * std.math.pi) * 0.06 else 0;
    const shrink = (1 - 0.15 * (1 - out)) * (1 + bump);
    const rr = R * (0.85 + 0.15 * in_) * shrink;
    const fill = @as(f32, @floatFromInt(pct)) / 100;
    cv.save();
    cv.opacity(clamp01(vis));
    cv.arc(cx, cy, rr, 14 * k, 1, white.alpha(0.13), .{ .a = 0 });
    cv.arc(cx, cy, rr + 2 * k, 20 * k, fill, col.alpha(0.18 * (1 - drain * 0.7)), .{ .a = 0 });
    cv.arc(cx, cy, rr, 14 * k, fill, col, .{ .a = 0 });

    // 中: 稲妻が消えて、電池の形が出る。その下に %
    const swap = easeOutCubic((t - 0.55) / 0.45);
    cv.save();
    cv.opacity(1 - swap);
    cv.scaleAbout(cx, cy - 22 * k, 1 - 0.4 * swap);
    _ = cv.text(cx, cy - 22 * k, 34 * k * shrink, green, I_BOLT, .{ .alignment = .center });
    cv.restore();
    {
        cv.save();
        cv.opacity(swap);
        const bw = 40 * k * shrink;
        const bh = 20 * k * shrink;
        const bx = cx - bw / 2 - 2 * k;
        const by = cy - 33 * k - bh / 2 + (1 - swap) * 6 * k;
        cv.rectBorder(bx, by, bw, bh, 5 * k, .{ .a = 0 }, rest.alpha(0.9), 2 * k);
        cv.rect(bx + bw + 1.5 * k, by + bh * 0.3, 3.5 * k, bh * 0.4, 1.5 * k, rest.alpha(0.9));
        cv.rect(bx + 3.5 * k, by + 3.5 * k, (bw - 7 * k) * fill, bh - 7 * k, 2.5 * k, rest);
        cv.restore();
    }
    var pb: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&pb, "{d}%", .{pct}) catch "";
    _ = cv.text(cx, cy + 40 * k, 46 * k * shrink, white, ps, .{ .bold = true, .alignment = .center });
    cv.restore();
}

/// ロック中でないときに出す全面のサーフェス
// ---------------------------------------------------------------------------
// ダイナミックアイランドごと動く充電のアニメーション(つないだとき・デスクトップのときだけ。ロック画面は今までどおり)
//   1. 滴る   … 島が枠から水のように垂れ下がり、首が細くなって、しずくがちぎれる
//   2. うずまき … しずくが速さの向きに伸び、水の流れを引きながら、うずを描いて回り込み、そのままリングを 1 周
//   3. 喜ぶ   … 一番上でぷるぷる揺れる。光の線は今の % まで戻る
//   4. 戻る   … 枠から水が伸びてきて、上がってくるしずくとつながり、吸い込まれて島の形に戻る
// 枠の島は、描いている形がぴったり島と同じになった瞬間に入れ替える(最初と最後)
// ---------------------------------------------------------------------------

const CHAR_TOTAL: f32 = 4.6;
const T_DRIP: f32 = 1.0;
const T_SWIRL: f32 = 2.9;
const T_HOLD: f32 = 3.35;

/// 枠の島の形と色(この面の座標)
pub const Geo = struct {
    rect: [4]f32 = .{ 0, 0, 0, 0 }, // 島の見えている部分(x, 上 = 枠の帯の下端, 幅, 高さ)
    rad: f32 = 25, // 枠の角の丸み
    s: f32 = 1, // 表示倍率
    body: Color = .{},
    rim: Color = .{},
};

pub fn durationWithChar() f32 {
    return CHAR_TOTAL;
}

fn smooth(x: f32) f32 {
    const t = clamp01(x);
    return t * t * (3 - 2 * t);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn circle(cv: *gfx.Canvas, x: f32, y: f32, r: f32, col: Color) void {
    if (r <= 0.3) return;
    cv.rect(x - r, y - r, r * 2, r * 2, r, col);
}

/// 水の首(A から B へ、太さ ra → rb。pinch で真ん中が細る)。重なった丸で描くので、ひとつながりに見える
fn neck(cv: *gfx.Canvas, ax: f32, ay: f32, ra: f32, bx: f32, by: f32, rb: f32, pinch: f32, col: Color) void {
    const d = @sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    const step = @max(@min(ra, rb) * (1 - pinch * 0.9) * 0.35, 1.2);
    const n: usize = @intFromFloat(std.math.clamp(@ceil(d / step), 2, 220));
    for (0..n + 1) |i| {
        const s = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const r = lerp(ra, rb, s) * (1 - pinch * @sin(s * std.math.pi));
        circle(cv, lerp(ax, bx, s), lerp(ay, by, s), r, col);
    }
}

/// 枠にくっついた島の形(上の角は枠の帯に隠れるので、上へはみ出して描いて切る)
fn pill(cv: *gfx.Canvas, cx: f32, top: f32, w: f32, h: f32, rad: f32, col: Color, rim: Color) void {
    if (w < 1 or h < 0.5) return;
    const old = cv.clip;
    cv.setClip(0, top, 100000, 100000);
    const r = @min(rad, @min(w, h + rad) / 2);
    cv.rect(cx - w / 2, top - rad, w, h + rad, r, col);
    cv.rectBorder(cx - w / 2, top - rad, w, h + rad, r, .{ .a = 0 }, rim, 1);
    cv.clip = old;
}

/// しずく(速さの向きへ伸びた涙の形)。v = 速さ(px/秒)
fn drop(cv: *gfx.Canvas, x: f32, y: f32, r: f32, vx: f32, vy: f32, col: Color, glow: Color, s: f32) void {
    const sp = @sqrt(vx * vx + vy * vy);
    cv.shadow(x - r * 1.4, y - r * 1.4, r * 2.8, r * 2.8, r * 1.4, 22 * s, glow);
    circle(cv, x, y, r, col);
    if (sp < 1) return;
    const ux = vx / sp;
    const uy = vy / sp;
    const stretch = std.math.clamp(sp / (900 * s), 0, 1.3);
    var i: f32 = 1;
    while (i <= 7) : (i += 1) {
        const f = i / 7;
        const off = r * f * 1.7 * stretch;
        circle(cv, x - ux * off, y - uy * off, r * (1 - 0.7 * f * stretch), col);
    }
}

/// 島と同じ白い目。(x, y) が真ん中、es が大きさ。look = 見る向き、happy = ^ ^
fn eyes(cv: *gfx.Canvas, x: f32, y: f32, es: f32, look: [2]f32, happy: bool, tint: Color) void {
    const gap = 17 * es;
    const ox = look[0] * 6 * es;
    const oy = look[1] * 3 * es;
    for ([_]f32{ -1, 1 }) |side| {
        const ex = x + side * gap + ox;
        const ey = y + oy;
        if (happy) {
            const a = 8 * es;
            cv.line(ex - a, ey + 3 * es, ex, ey - 5 * es, 3.4 * es, white);
            cv.line(ex, ey - 5 * es, ex + a, ey + 3 * es, 3.4 * es, white);
        } else {
            const ew = 14 * es;
            const eh = 23 * es;
            cv.shadow(ex - ew / 2, ey - eh / 2, ew, eh, ew / 2, 9 * es, tint.alpha(0.38));
            cv.rectGrad(ex - ew / 2, ey - eh / 2, ew, eh, ew / 2, white, tint);
        }
    }
}

const Ctx = struct { W: f32, H: f32, g: Geo, R: f32, cx: f32, cy: f32, rel: [2]f32 };

/// うずまき〜リングを 1 周する間のしずくの位置(t は T_DRIP〜T_SWIRL)
fn swirlAt(cx_: Ctx, t: f32) [2]f32 {
    const cc = cx_;
    const u = clamp01((t - T_DRIP) / (T_SWIRL - T_DRIP));
    // 回る角度: 上から時計回りに 2 周(1 周目でうずを描いて回り込み、2 周目はリングの上)。最初から少し速さを持たせる
    const e = 0.25 * u + 0.75 * smooth(u);
    const ang = -std.math.pi / 2.0 + e * std.math.tau * 2;
    const r0 = @sqrt((cc.rel[0] - cc.cx) * (cc.rel[0] - cc.cx) + (cc.rel[1] - cc.cy) * (cc.rel[1] - cc.cy));
    const r = lerp(r0, cc.R, smooth(e * 2));
    return .{ cc.cx + @cos(ang) * r, cc.cy + @sin(ang) * r };
}

pub fn drawWithChar(cv: *gfx.Canvas, W: f32, H: f32, t: f32, pct: u8, g: Geo) void {
    if (t < 0 or t > CHAR_TOTAL) return;
    const k = @min(W, H) / 800;
    const S = g.s;
    const cx = W / 2;
    const cy = H / 2;
    const R: f32 = 120 * k;
    const col = chargeColor(pct);
    const glow = col.lighten(0.35);
    const tint = Color.mix(white, glow, 0.35);
    const ix = g.rect[0] + g.rect[2] / 2;
    const top = g.rect[1];
    const iw = g.rect[2];
    const ih = g.rect[3];
    const ball = 22 * S;
    const eye_y_island = top + ih / 2 - S; // 島の目の位置(island.zig と同じ)
    const vis = smooth(t / 0.5) * (1 - smooth((t - (CHAR_TOTAL - 0.6)) / 0.6));

    // 背景を暗く + 真ん中のぼんやりした光
    cv.rect(0, 0, W, H, 0, black.alpha(0.45 * vis));
    const bloom = R * 3.2;
    cv.shadow(cx - bloom / 2, cy - bloom / 2, bloom, bloom, bloom / 2, 160 * k, col.alpha(0.14 * vis));

    // しずくがちぎれる所(滴る終わりの位置)
    const rel = [2]f32{ ix, top + ih + 70 * S };
    const cxt = Ctx{ .W = W, .H = H, .g = g, .R = R, .cx = cx, .cy = cy, .rel = rel };
    const pct_f = @as(f32, @floatFromInt(pct)) / 100;

    // ---- リングと光の線 ----
    var fill: f32 = 0;
    var head_on = false;
    if (t >= T_DRIP and t < T_SWIRL) {
        const u = clamp01((t - T_DRIP) / (T_SWIRL - T_DRIP));
        const e = 0.25 * u + 0.75 * smooth(u);
        fill = clamp01(e * 2 - 1); // 2 周目
        head_on = fill > 0;
    } else if (t >= T_SWIRL) fill = lerp(1, pct_f, smooth((t - T_SWIRL) / 0.45));
    {
        cv.save();
        cv.opacity(clamp01(vis));
        cv.arc(cx, cy, R, 12 * k, 1, white.alpha(0.12 * smooth((t - 0.6) / 0.6)), .{ .a = 0 });
        if (fill > 0.002) {
            cv.arc(cx, cy, R + 2 * k, 20 * k, fill, col.alpha(0.2), .{ .a = 0 });
            cv.arc(cx, cy, R, 12 * k, fill, col, .{ .a = 0 });
        }
        const te = smooth((t - 1.6) / 0.6);
        if (te > 0.01) {
            cv.save();
            cv.opacity(te);
            var pb: [8]u8 = undefined;
            const shown: u32 = @intFromFloat(@round(@min(fill, pct_f) * 100));
            const ps = std.fmt.bufPrint(&pb, "{d}%", .{if (t > T_SWIRL) pct else @as(u8, @intCast(@min(shown, pct)))}) catch "";
            _ = cv.text(cx, cy + 16 * k, 46 * k, white, ps, .{ .bold = true, .alignment = .center });
            _ = cv.text(cx, cy - 30 * k, 26 * k, col, I_BOLT, .{ .alignment = .center });
            cv.restore();
        }
        cv.restore();
    }

    if (t < T_DRIP) {
        // ---- 1. 滴る: 島が垂れ下がり、下にしずくがふくらみ、首が細くなってちぎれる ----
        const d = t / T_DRIP;
        const body = g.body;
        // 枠に残る部分: 少し伸びて細くなり、ちぎれた後は枠へ引っ込む(ぷるんと揺れながら)
        const retract = smooth((d - 0.72) / 0.28);
        const wobble = @sin(clamp01((d - 0.72) / 0.28) * std.math.pi * 2.5) * (1 - retract) * 0.12;
        const pw = iw * lerp(1, 0.55, smooth(d / 0.7)) * (1 - retract) * (1 + wobble);
        const ph = ih * (1 + 0.35 * smooth(d / 0.6)) * (1 - retract);
        // しずく: 島の下の方から生まれて、重さで下へ
        const dy = lerp(top + ih * 0.55, rel[1], d * d);
        const dr = lerp(ih * 0.45, ball, smooth(d));
        const pinch = smooth((d - 0.35) / 0.45);
        // 首(ちぎれるまで)
        if (d < 0.8) {
            const old = cv.clip;
            cv.setClip(0, top, 100000, 100000);
            neck(cv, ix, top + ph * 0.6, @min(pw * 0.28, ph * 0.4), ix, dy, dr * 0.85, pinch * 0.98, body);
            cv.clip = old;
        }
        pill(cv, ix, top, pw, ph, g.rad, body, g.rim);
        // ちぎれた瞬間の小さなしずく(しずくへ吸い込まれる)
        if (d >= 0.8) {
            const q = clamp01((d - 0.8) / 0.2);
            circle(cv, ix, lerp((top + ph + dy) / 2, dy - dr, q), 3.5 * S * (1 - q), body);
        }
        const vy = 2 * d * (rel[1] - top - ih * 0.55) / T_DRIP;
        drop(cv, ix, dy, dr, 0, vy, body, col.alpha(0.0), S);
        // 目: 島の中から、しずくの中へ移る
        const m = smooth(d / 0.75);
        eyes(cv, ix, lerp(eye_y_island, dy, m), S * lerp(1, 0.78, m), .{ 0, lerp(0, 1, m) }, false, tint);
        return;
    }

    if (t < T_SWIRL) {
        // ---- 2. うずまき: 流れを引きながら回り込み、そのままリングを 1 周 ----
        const p = swirlAt(cxt, t);
        const p0 = swirlAt(cxt, t - 0.016);
        const vx = (p[0] - p0[0]) / 0.016;
        const vy = (p[1] - p0[1]) / 0.016;
        const u = (t - T_DRIP) / (T_SWIRL - T_DRIP);
        const green = smooth(u * 1.8);
        const body = Color.mix(g.body, col, green * 0.92);
        // 水の流れ: 通った道に沿って、先へいくほど細くなる一本の流れ(重なった丸で、つなぎ目なく)
        var j: f32 = 40;
        while (j >= 1) : (j -= 1) {
            const tt = t - j * 0.007;
            if (tt < T_DRIP) continue;
            const q = swirlAt(cxt, tt);
            const f = j / 40;
            const taper = (1 - f) * (1 - f);
            circle(cv, q[0], q[1], ball * 0.7 * taper, body);
        }
        if (head_on) cv.shadow(p[0] - 40 * S, p[1] - 40 * S, 80 * S, 80 * S, 40 * S, 30 * S, glow.alpha(0.7));
        const jig = 1 + 0.06 * @sin(t * 21);
        drop(cv, p[0], p[1], ball * jig, vx, vy, body, col.alpha(0.5 * green), S);
        const sp = @max(@sqrt(vx * vx + vy * vy), 1);
        eyes(cv, p[0], p[1], S * 0.78, .{ vx / sp, vy / sp }, false, tint);
        return;
    }

    const ring_top = [2]f32{ cx, cy - R };
    if (t < T_HOLD) {
        // ---- 3. 一番上で、ぷるぷる喜ぶ ----
        const u = (t - T_SWIRL) / (T_HOLD - T_SWIRL);
        const body = Color.mix(g.body, col, 0.92);
        const amp = @exp(-u * 3) * 0.18;
        const wob = @sin(u * std.math.pi * 7);
        const bw = ball * (1 + amp * wob);
        const bh = ball * (1 - amp * wob);
        const y = ring_top[1] - @abs(@sin(u * std.math.pi * 2)) * 7 * S;
        cv.shadow(ring_top[0] - bw * 1.4, y - bh * 1.4, bw * 2.8, bh * 2.8, bw * 1.4, 22 * S, col.alpha(0.5));
        cv.rect(ring_top[0] - bw, y - bh, bw * 2, bh * 2, @min(bw, bh), body);
        eyes(cv, ring_top[0], y, S * 0.78, .{ 0, 0 }, true, tint);
        return;
    }

    // ---- 4. 戻る: 枠から水が伸びてきて、上がるしずくとつながり、吸い込まれて島になる ----
    const u = (t - T_HOLD) / (CHAR_TOTAL - T_HOLD);
    const green = 1 - smooth(u / 0.85);
    const body = Color.mix(g.body, col, green * 0.92);
    // しずくの道: ふわっと左右に揺れながら、島の真下へ
    const rise = smooth(u / 0.7);
    const meet_y = top + ih + ball * 0.8;
    var dx = lerp(ring_top[0], ix, smooth(u / 0.7)) + @sin(u / 0.7 * std.math.pi) * 34 * S;
    var dy = lerp(ring_top[1], meet_y, rise);
    var dr = ball;
    // 枠から伸びてくる水(だんだん太く、長く)
    const reach = smooth((u - 0.25) / 0.45);
    var bw = iw * lerp(0.22, 0.5, reach);
    var bh = ih * 0.75 * reach;
    // つながる首(最初は細く、つながると太る)
    const bridge = smooth((u - 0.55) / 0.2);
    // 吸い込まれて島の形に(最後の 30%)
    const m = smooth((u - 0.7) / 0.3);
    bw = lerp(bw, iw, m);
    bh = lerp(bh, ih, m);
    dy = lerp(dy, top + ih * 0.5, m);
    dx = lerp(dx, ix, m);
    dr = ball * (1 - m);
    if (bridge > 0 and m < 1) {
        const old = cv.clip;
        cv.setClip(0, top, 100000, 100000);
        neck(cv, ix, top + bh * 0.5, @max(@min(bw * 0.22, bh * 0.45), 2 * S), dx, dy, dr * 0.85, (1 - bridge) * 0.95, body);
        cv.clip = old;
    }
    pill(cv, ix, top, bw, bh, g.rad, body, Color.mix(g.rim.alpha(0), g.rim, m));
    const vy_up = if (u < 0.7) -(meet_y - ring_top[1]) / ((CHAR_TOTAL - T_HOLD) * 0.7) * 1.5 * @sin(u / 0.7 * std.math.pi) else 0;
    if (dr > 0.5) drop(cv, dx, dy, dr, 0, vy_up, body, col.alpha(0.4 * green), S);
    // 目: しずくの中から、島の目の位置へ。最後は島と同じ大きさ・向き
    eyes(cv, lerp(dx, ix, m), lerp(dy, eye_y_island, m), S * lerp(0.78, 1, m), .{ 0, lerp(-0.6, 0, m) }, u < 0.85, tint);
}

pub const ChargeAnim = struct {
    app: *App,
    surf: ?*Surface = null,
    out: ?*Output = null,
    t: f32 = -1,
    pct: u8 = 0,
    kind: Kind = .plug,
    /// ダイナミックアイランドごと動く(つないだとき・島が出ているとき)
    with_char: bool = false,
    geo: Geo = .{},
    /// 枠の島を閉じて、こちらで描いている間
    away: bool = false,

    pub fn create(app: *App) !*ChargeAnim {
        const self = try app.alloc.create(ChargeAnim);
        self.* = .{ .app = app };
        return self;
    }

    /// 充電器をつないだ・外した(syswatch.zig)
    pub fn play(self: *ChargeAnim, pct: u8, kind: Kind) void {
        const app = self.app;
        if (!app.cfg.charge_anim) return;
        // ロック中(ログイン画面も)はロック画面の上に描く
        if (app.lock.locked) {
            app.lock.playCharge(pct, kind);
            return;
        }
        self.pct = pct;
        self.kind = kind;
        self.t = 0;
        self.with_char = false;
        if (kind == .plug and app.cfg.island and !self.away) if (app.activeFrame()) |f| if (f.island.open and f.island.t.x > 0.98) {
            const r = f.island.vis;
            var tint = theme.tint(app);
            tint.a = 1;
            self.geo = .{ .rect = .{ r[0] * f.S, r[1] * f.S, r[2] * f.S, r[3] * f.S }, .rad = f.R() * f.S, .s = f.S, .body = tint, .rim = theme.glass(app).rim };
            self.with_char = true;
        };
        if (self.surf == null) {
            const out = app.activeOutput() orelse return;
            const all = c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
            self.surf = Surface.createLayer(app, .{ .ctx = self, .draw = drawSurf }, .{
                .layer = c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
                .anchor = @intCast(all),
                .exclusive = -1,
                .namespace = "ame-charge",
                .output = out.wl,
            }) catch return;
            self.out = out;
            self.surf.?.output = out;
            self.surf.?.setInputRect(0, 0, 0, 0); // クリックは下へ通す
        }
        self.surf.?.schedule();
    }

    fn drawSurf(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *ChargeAnim = @ptrCast(@alignCast(ctx));
        if (self.t < 0) return false;
        // 最初のコマ: 枠の島を一瞬で閉じ、同じ形をこちらで描き始める(入れ替わりが見えないように)
        if (self.with_char and !self.away and self.t == 0) {
            self.away = true;
            if (self.app.activeFrame()) |f| f.islandSnap(false);
        }
        self.t += @min(dt, 0.05);
        // 終わる直前: 形がぴったり島に戻ったところで、枠の島を一瞬で開く(しばらく両方が重なる)
        if (self.away and self.t >= CHAR_TOTAL - 0.1) {
            self.away = false;
            if (self.app.activeFrame()) |f| f.islandSnap(true);
        }
        if (self.t > (if (self.with_char) durationWithChar() else duration(self.kind))) {
            self.t = -1;
            self.app.reap_pending = true;
            return false;
        }
        if (self.with_char) {
            drawWithChar(cv, @floatFromInt(s.width), @floatFromInt(s.height), @min(self.t, CHAR_TOTAL), self.pct, self.geo);
        } else draw(cv, @floatFromInt(s.width), @floatFromInt(s.height), self.t, self.pct, self.kind);
        return true;
    }

    /// 島が出かけている(枠の島は閉じる)
    pub fn charAway(self: *const ChargeAnim) bool {
        return self.away;
    }

    /// 終わったらサーフェスを消す(app の reap から)
    pub fn reap(self: *ChargeAnim) void {
        if (self.t >= 0) return;
        if (self.surf) |s| s.destroy();
        self.surf = null;
        self.out = null;
    }

    pub fn outputRemoved(self: *ChargeAnim, o: *Output) void {
        if (self.out != o) return;
        if (self.surf) |s| s.destroy();
        self.surf = null;
        self.out = null;
        self.t = -1;
    }
};

test "イージングは端で 0 と 1" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), easeOutCubic(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), easeOutCubic(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), easeOutBack(1), 1e-6);
    // 途中で 1 を少し超える(ポンと出る)
    var over = false;
    var x: f32 = 0;
    while (x < 1) : (x += 0.05) {
        if (easeOutBack(x) > 1.01) over = true;
    }
    try std.testing.expect(over);
}
