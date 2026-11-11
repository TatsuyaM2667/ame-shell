// レッスンの本文に書いた数値を、その場で測り直す(本文の数値はここから取った)。
// measure_test.zig(答えの Zig 版)と real_test.zig(本物の Odin)の両方から呼ぶ。
const std = @import("std");
const spec = @import("spec.zig");
const Spring = spec.Spring;

pub const Run = struct { peak: f32, reach95: f32, settle: f32 };

/// 0 → 100 を 60fps で動かし、最大・95% に届いた時刻・止まった時刻を測る
pub fn run(step: spec.StepFn, response: f32, damping: f32) Run {
    var s = Spring{ .x = 0, .v = 0, .target = 100, .response = response, .damping = damping };
    var r = Run{ .peak = 0, .reach95 = -1, .settle = -1 };
    var t: f32 = 0;
    for (0..600) |_| {
        const moving = step(&s, 1.0 / 60.0);
        t += 1.0 / 60.0;
        r.peak = @max(r.peak, s.x);
        if (r.reach95 < 0 and s.x >= 95) r.reach95 = t;
        if (!moving and r.settle < 0) r.settle = t;
    }
    return r;
}

/// 本文の表の数値と、許す誤差(1 コマ = 0.017 秒の半分)
pub fn checkTable(step: spec.StepFn) !void {
    const a = run(step, 0.3, 0.3);
    const b = run(step, 0.3, 1.0);
    std.debug.print("\nresponse 0.3・damping 0.3: 最大 {d:.1}・95% に {d:.3} 秒・止まる {d:.3} 秒\n", .{ a.peak, a.reach95, a.settle });
    std.debug.print("response 0.3・damping 1.0: 最大 {d:.1}・95% に {d:.3} 秒・止まる {d:.3} 秒\n", .{ b.peak, b.reach95, b.settle });
    try std.testing.expectApproxEqAbs(@as(f32, 136.8), a.peak, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), b.peak, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.100), a.reach95, 0.009);
    try std.testing.expectApproxEqAbs(@as(f32, 0.233), b.reach95, 0.009);
    try std.testing.expectApproxEqAbs(@as(f32, 1.567), a.settle, 0.009);
    try std.testing.expectApproxEqAbs(@as(f32, 0.750), b.settle, 0.009);
}

/// 1 回で大きく進める(刻まない)とき、壊れない最大の刻み(秒)。0.5 ミリ秒ずつ調べる
pub fn stabilityLimit(response: f32, damping: f32) f32 {
    const omega: f32 = 6.2831853 / response;
    const k = omega * omega;
    const c = 2 * damping * omega;
    var h: f32 = 0.0005;
    var last_ok: f32 = 0;
    while (h < 0.2) : (h += 0.0005) {
        var x: f32 = 0;
        var v: f32 = 0;
        var ok = true;
        for (0..2000) |_| {
            const a = -k * (x - 100) - c * v;
            v += a * h;
            x += v * h;
            if (!std.math.isFinite(x) or @abs(x) > 1000) {
                ok = false;
                break;
            }
        }
        if (!ok) break;
        last_ok = h;
    }
    return last_ok;
}
