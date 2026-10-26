// 配色とガラスの見た目を設定から作る。アクセント色はアルバムアート等で動的に変わるので、
// 時間ベースで補間する(どのサーフェスが何回描いても同じ色になるように)。
const std = @import("std");
const anim = @import("anim.zig");
const Color = anim.Color;
const gfx = @import("gfx.zig");
const App = @import("app.zig").App;
const loop = @import("platform/loop.zig");

var accent_from: Color = Color.hex(0x7ab8ff);
var accent_to: Color = Color.hex(0x7ab8ff);
var accent_t0: u64 = 0;
var accent_override: bool = false;
const ACCENT_MS: f32 = 900;

/// アクセント色を一時的に差し替える(null で設定値に戻す)。
pub fn setAccent(app: *App, col: ?Color) void {
    accent_from = accent(app);
    accent_override = col != null;
    accent_to = col orelse Color.hex(app.cfg.accent);
    accent_t0 = loop.nowMs();
}

fn progress() f32 {
    const t = @as(f32, @floatFromInt(loop.nowMs() -| accent_t0)) / ACCENT_MS;
    return std.math.clamp(t, 0, 1);
}

pub fn accent(app: *App) Color {
    if (!accent_override) accent_to = Color.hex(app.cfg.accent);
    const t = progress();
    if (t >= 1) return accent_to;
    // ease-out cubic(色はスプリングより単調な方が自然)
    const e = 1 - (1 - t) * (1 - t) * (1 - t);
    return Color.mix(accent_from, accent_to, e);
}

pub fn accentAnimating() bool {
    return progress() < 1;
}

pub fn text(app: *App) Color {
    return Color.hex(app.cfg.text);
}
pub fn subtext(app: *App) Color {
    return Color.hex(app.cfg.subtext);
}

pub fn glass(app: *App) gfx.GlassStyle {
    const acc = accent(app);
    var tint = Color.hex(app.cfg.tint);
    tint.a = app.cfg.tint_strength;
    return .{
        .tint = tint,
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

pub const ease = struct {
    pub fn outCubic(t: f32) f32 {
        const u = 1 - std.math.clamp(t, 0, 1);
        return 1 - u * u * u;
    }
};
