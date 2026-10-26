// 配色。基本の配色(アクセント・ガラスの色・文字色)は壁紙から自動で作り(theme.auto-color)、
// 再生中のアルバムアートがあればアクセントだけをその色で上書きする(theme.media-accent)。
// どちらも時間ベースで補間するので、どのサーフェスが何回描いても同じ色になり、切り替えは滑らか。
const std = @import("std");
const anim = @import("anim.zig");
const Color = anim.Color;
const gfx = @import("gfx.zig");
const App = @import("app.zig").App;
const loop = @import("platform/loop.zig");

/// 壁紙から作る配色(null の項目は設定値を使う)
pub const Scheme = struct {
    accent: Color,
    tint: Color,
    text: Color,
    subtext: Color,
};

const FADE_MS: f32 = 1100;

// ---- 壁紙の配色(基本) ----
var scheme_from: ?Scheme = null;
var scheme_to: ?Scheme = null;
var scheme_t0: u64 = 0;

// ---- アルバムアートのアクセント(上書き) ----
var media_from: Color = Color.hex(0x7ab8ff);
var media_to: ?Color = null;
var media_t0: u64 = 0;
var media_fading_out: bool = false;

fn cfgScheme(app: *App) Scheme {
    return .{ .accent = Color.hex(app.cfg.accent), .tint = Color.hex(app.cfg.tint), .text = Color.hex(app.cfg.text), .subtext = Color.hex(app.cfg.subtext) };
}

fn progress(t0: u64) f32 {
    return std.math.clamp(@as(f32, @floatFromInt(loop.nowMs() -| t0)) / FADE_MS, 0, 1);
}

fn ease(t: f32) f32 {
    const u = 1 - t;
    return 1 - u * u * u;
}

/// 今の基本配色(壁紙由来、無ければ設定値)
fn base(app: *App) Scheme {
    const to = if (app.cfg.auto_color) (scheme_to orelse cfgScheme(app)) else cfgScheme(app);
    const t = progress(scheme_t0);
    if (t >= 1 or scheme_from == null) return to;
    const from = scheme_from.?;
    const e = ease(t);
    return .{
        .accent = Color.mix(from.accent, to.accent, e),
        .tint = Color.mix(from.tint, to.tint, e),
        .text = Color.mix(from.text, to.text, e),
        .subtext = Color.mix(from.subtext, to.subtext, e),
    };
}

/// 壁紙が変わったときに呼ぶ(null = シェーダ壁紙など。設定の配色に戻す)
pub fn setWallScheme(app: *App, s: ?Scheme) void {
    scheme_from = base(app);
    scheme_to = s;
    scheme_t0 = loop.nowMs();
    app.redrawAll();
    if (app.wm) |w| w.themeChanged();
}

/// アクセント色をアルバムアートの色で上書きする(null で上書きをやめる)
pub fn setAccent(app: *App, col: ?Color) void {
    media_from = accent(app);
    media_fading_out = col == null;
    if (col) |cc| media_to = cc;
    media_t0 = loop.nowMs();
    if (app.wm) |w| w.themeChanged();
}

pub fn accent(app: *App) Color {
    const b = base(app).accent;
    const t = progress(media_t0);
    if (media_to == null) return b;
    if (media_fading_out) {
        if (t >= 1) {
            media_to = null;
            return b;
        }
        return Color.mix(media_from, b, ease(t));
    }
    return Color.mix(media_from, media_to.?, ease(t));
}

pub fn accentAnimating() bool {
    return progress(media_t0) < 1 or progress(scheme_t0) < 1;
}

pub fn text(app: *App) Color {
    return base(app).text;
}
pub fn subtext(app: *App) Color {
    return base(app).subtext;
}
/// ガラス・枠の色(透明度は別に掛ける)
pub fn tint(app: *App) Color {
    return base(app).tint;
}

pub fn glass(app: *App) gfx.GlassStyle {
    const acc = accent(app);
    var t = tint(app);
    t.a = app.cfg.tint_strength;
    return .{
        .tint = t,
        .sheen = .{ .r = acc.r, .g = acc.g, .b = acc.b, .a = 0.10 },
        .rim = Color.mix(acc, Color.hex(0xffffff), 0.55).alpha(0.55),
        .refraction = app.cfg.refraction,
        .sparkle = app.cfg.sparkle,
    };
}

/// ポップアップ(ウィンドウの上に出るもの)用。背後が壁紙とは限らないので濃いめにする。
pub fn glassStrong(app: *App) gfx.GlassStyle {
    var g = glass(app);
    g.tint.a = @min(1.0, app.cfg.tint_strength + 0.30);
    return g;
}

pub fn shadow() Color {
    return .{ .r = 0.0, .g = 0.02, .b = 0.08, .a = 0.45 };
}

pub const ease_fns = struct {
    pub fn outCubic(t: f32) f32 {
        const u = 1 - std.math.clamp(t, 0, 1);
        return 1 - u * u * u;
    }
};

// ---------------------------------------------------------------------------
// 壁紙の画素から配色を作る
//
// Odin の ame_dominant_color で「彩度で重み付けした代表色」を取り、その色相を軸に
//   アクセント = 明るく鮮やか / ガラス = 同じ色相のごく暗い色 / 文字 = ほぼ白に色相を少し
// を作る(Material You の考え方を簡略化)。モノクロに近い壁紙は青みのある既定の色相にする。
// ---------------------------------------------------------------------------

pub fn schemeFromPixels(rgba: [*]const u8, w: c_int, h: c_int) Scheme {
    var work: [4096 * 4]u32 = undefined;
    const count = w * h;
    const stride = @max(1, @divTrunc(count, 60_000));
    const rgb = anim.ame_dominant_color(rgba, count, stride, &work);
    const col = Color.hex(rgb);
    var hsl = toHsl(col);
    if (hsl[1] < 0.08) {
        // ほぼ無彩色: 寒色寄りの落ち着いた配色にする
        hsl[0] = 0.60;
        hsl[1] = 0.25;
    }
    const hh = hsl[0];
    const s = hsl[1];
    return .{
        .accent = fromHsl(hh, std.math.clamp(s * 1.1, 0.45, 0.85), 0.74),
        .tint = fromHsl(hh, std.math.clamp(s * 0.6, 0.18, 0.45), 0.085),
        .text = fromHsl(hh, 0.40, 0.95),
        .subtext = fromHsl(hh, 0.22, 0.75),
    };
}

fn toHsl(cc: Color) [3]f32 {
    const mx = @max(cc.r, @max(cc.g, cc.b));
    const mn = @min(cc.r, @min(cc.g, cc.b));
    const l = (mx + mn) / 2;
    if (mx == mn) return .{ 0, 0, l };
    const d = mx - mn;
    const s = if (l > 0.5) d / (2 - mx - mn) else d / (mx + mn);
    var hh: f32 = 0;
    if (mx == cc.r) {
        hh = (cc.g - cc.b) / d + (if (cc.g < cc.b) @as(f32, 6) else 0);
    } else if (mx == cc.g) {
        hh = (cc.b - cc.r) / d + 2;
    } else hh = (cc.r - cc.g) / d + 4;
    return .{ hh / 6, s, l };
}

fn hue2rgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

fn fromHsl(hh: f32, s: f32, l: f32) Color {
    if (s == 0) return .{ .r = l, .g = l, .b = l, .a = 1 };
    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;
    return .{ .r = hue2rgb(p, q, hh + 1.0 / 3.0), .g = hue2rgb(p, q, hh), .b = hue2rgb(p, q, hh - 1.0 / 3.0), .a = 1 };
}

test "hsl roundtrip" {
    const cc = Color.hex(0x3d7bff);
    const h = toHsl(cc);
    const back = fromHsl(h[0], h[1], h[2]);
    try std.testing.expectApproxEqAbs(cc.r, back.r, 0.01);
    try std.testing.expectApproxEqAbs(cc.b, back.b, 0.01);
}
