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
    drawPlugEx(cv, W, H, t, pct, false);
}

/// with_char: 真ん中は稲妻の代わりに島のキャラクター(drawWithChar が描く)。% は少し下へ
fn drawPlugEx(cv: *gfx.Canvas, W: f32, H: f32, t: f32, pct: u8, with_char: bool) void {
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
    if (!with_char) _ = cv.text(cx, cy - 22 * k, 34 * k * shrink, col, I_BOLT, .{ .alignment = .center });
    // 数字は満ちていくリングに合わせて数え上がる
    const shown: u32 = @intFromFloat(@round(fill * 100));
    var pb: [8]u8 = undefined;
    const ps = std.fmt.bufPrint(&pb, "{d}%", .{if (t > 1.2) pct else @as(u8, @intCast(@min(shown, pct)))}) catch "";
    _ = cv.text(cx, cy + (if (with_char) @as(f32, 58) else 40) * k, 46 * k * shrink, white, ps, .{ .bold = true, .alignment = .center });
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
// ダイナミックアイランドのキャラクターが、水玉になって真ん中へ落ち、くるっと回って充電のリングの中に座り、
// 終わると島へ戻る(つないだとき・デスクトップのときだけ。ロック画面は今までどおり)
// ---------------------------------------------------------------------------

/// 落ちて回るまでの秒数(この後に、いつものリングのアニメーションが続く)
pub const DROP: f32 = 1.1;
/// 島へ戻る秒数(リングが消えるのと重なる)
const RISE: f32 = 0.75;

pub fn durationWithChar() f32 {
    return DROP + DURATION;
}

fn easeInQuad(x: f32) f32 {
    const t = clamp01(x);
    return t * t;
}

/// from = 島の真ん中(この面の座標)
pub fn drawWithChar(cv: *gfx.Canvas, W: f32, H: f32, t: f32, pct: u8, from: [2]f32) void {
    const total = durationWithChar();
    if (t < 0 or t > total) return;
    const k = @min(W, H) / 800;
    const cx = W / 2;
    const cy = H / 2 - 18 * k;
    if (t >= DROP) drawPlugEx(cv, W, H, t - DROP, pct, true);
    const col = chargeColor(pct);
    const sit_r = 30 * k;
    var x = cx;
    var y = cy;
    var r = sit_r;
    var sx: f32 = 1; // 横の伸び(回るときは向きの cos)
    var sy: f32 = 1;
    var tail: f32 = 0; // 水玉のしっぽ(+ で上へ・- で下へ)
    var face: f32 = 1; // 顔が見えている向き(-1 で後ろ向き)
    var happy = false;
    if (t < 0.55) {
        // 落ちる: 小さな水玉が、伸びながら加速して真ん中へ
        const p = t / 0.55;
        const e = easeInQuad(p);
        x = from[0] + (cx - from[0]) * e;
        y = from[1] + (cy - from[1]) * e;
        r = 12 * k + (sit_r - 12 * k) * e;
        sy = 1 + 0.5 * @sin(p * std.math.pi);
        sx = 1 / sy;
        tail = 1.2 * (1 - p * 0.5);
    } else if (t < DROP) {
        // 着地してぷにっとつぶれ、くるっと 1 回転(縦の軸で)
        const q = (t - 0.55) / (DROP - 0.55);
        const land = @exp(-q * 7) * @cos(q * 22);
        sy = 1 - 0.35 * land;
        sx = 1 + 0.3 * land;
        const spin = easeOutCubic(clamp01((q - 0.15) / 0.75)) * std.math.tau;
        face = @cos(spin);
        sx *= @max(@abs(face), 0.12);
        happy = q > 0.85;
    } else if (t < total - RISE) {
        // リングの真ん中で、うれしそうにゆれる
        const u = t - DROP;
        happy = true;
        const b = @abs(@sin(u * std.math.pi * 2.2));
        y = cy - b * 5 * k;
        sy = 1 + 0.05 * b;
        sx = 1 - 0.04 * b;
    } else {
        // 島へ戻る: 上へ伸びて、すーっと吸い込まれる
        const p = (t - (total - RISE)) / RISE;
        const e = easeInQuad(p);
        x = cx + (from[0] - cx) * e;
        y = cy + (from[1] - cy) * e;
        r = sit_r + (10 * k - sit_r) * e;
        sy = 1 + 0.6 * @sin(p * std.math.pi);
        sx = 1 / sy;
        tail = -1.2 * p;
    }
    drawBlob(cv, x, y, r, sx, sy, tail, face, happy, col, k);
}

/// 水玉のキャラクター: 島と同じ暗いガラスの体に、充電の色のふち。顔は白い 2 つの目
fn drawBlob(cv: *gfx.Canvas, x: f32, y: f32, r: f32, sx: f32, sy: f32, tail: f32, face: f32, happy: bool, col: Color, k: f32) void {
    const w = r * 2 * sx;
    const h = r * 2 * sy;
    const body = Color.hex(0x0c1222);
    // 光
    cv.shadow(x - w / 2, y - h / 2, w, h, @min(w, h) / 2, 26 * k, col.alpha(0.55));
    // しっぽ(落ちるときは上、戻るときは下へ細くなる)
    if (@abs(tail) > 0.01) {
        const dir: f32 = if (tail > 0) -1 else 1;
        const len = r * @abs(tail) * 1.6;
        var i: f32 = 0;
        while (i < 6) : (i += 1) {
            const f = i / 6;
            const tw = w * 0.5 * (1 - f) * (1 - f);
            const ty = y + dir * (h * 0.3 + f * len);
            cv.rect(x - tw / 2, ty - 3 * k, tw, 6 * k, 3 * k, body);
        }
    }
    cv.rect(x - w / 2, y - h / 2, w, h, @min(w, h) / 2, body);
    cv.rectBorder(x - w / 2, y - h / 2, w, h, @min(w, h) / 2, .{ .a = 0 }, col.alpha(0.85), 2 * k);
    // 顔(後ろ向きの間は出さない)
    if (face <= 0.05 or r < 14 * k) return;
    const gap = r * 0.36 * sx;
    const ew = r * 0.24 * @abs(face);
    const eh = r * 0.5 * sy;
    for ([_]f32{ -1, 1 }) |side| {
        const ex = x + side * gap;
        const ey = y - r * 0.06;
        if (happy) {
            const a = r * 0.17;
            cv.line(ex - a, ey + 2 * k, ex, ey - 4 * k, 3 * k, white);
            cv.line(ex, ey - 4 * k, ex + a, ey + 2 * k, 3 * k, white);
        } else cv.rect(ex - ew / 2, ey - eh / 2, ew, eh, ew / 2, white);
    }
}

pub const ChargeAnim = struct {
    app: *App,
    surf: ?*Surface = null,
    out: ?*Output = null,
    t: f32 = -1,
    pct: u8 = 0,
    kind: Kind = .plug,
    /// 島のキャラクターが水玉になって出てくる(つないだとき・島が出ているとき)
    with_char: bool = false,
    from: [2]f32 = .{ 0, 0 },

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
        if (kind == .plug and app.cfg.island) if (app.activeFrame()) |f| if (f.island.visible()) {
            const r = f.island.vis;
            self.from = .{ (r[0] + r[2] / 2) * f.S, (r[1] + r[3] / 2) * f.S };
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
        self.t += @min(dt, 0.05);
        if (self.t > (if (self.with_char) durationWithChar() else duration(self.kind))) {
            self.t = -1;
            self.app.reap_pending = true;
            return false;
        }
        if (self.with_char) {
            drawWithChar(cv, @floatFromInt(s.width), @floatFromInt(s.height), self.t, self.pct, self.from);
        } else draw(cv, @floatFromInt(s.width), @floatFromInt(s.height), self.t, self.pct, self.kind);
        return true;
    }

    /// 島のキャラクターが出かけている(島は目を出さない)
    pub fn charAway(self: *const ChargeAnim) bool {
        return self.with_char and self.t >= 0;
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
