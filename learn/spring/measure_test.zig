// 本文の数値を測り直す(答えの Zig 版で)。
//   zig test learn/spring/measure_test.zig
// 本物の Odin で同じことをするには: sh learn/check-real.sh
const std = @import("std");
const spec = @import("spec.zig");
const measure = @import("measure.zig");
const answer = @import("answer.zig");
const Spring = spec.Spring;

test "本文の表: 減衰比 0.3 と 1.0" {
    try measure.checkTable(answer.step);
}

/// 障害ラボの表: 一時停止(dt = 2 秒)のあとの位置を、守りを外した 4 通りで
fn variant(s: *Spring, dt: f32, cap: bool, sub: bool) void {
    const omega: f32 = 6.2831853 / s.response;
    const k = omega * omega;
    const c = 2 * s.damping * omega;
    var remaining = dt;
    if (cap and remaining > 0.1) remaining = 0.1;
    while (remaining > 0) {
        var h = remaining;
        if (sub and h > 0.001) h = 0.001;
        const a = -k * (s.x - s.target) - c * s.v;
        s.v += a * h;
        s.x += s.v * h;
        remaining -= h;
    }
}

test "障害ラボの表: 一時停止のあとの位置" {
    const cases = [_]struct { cap: bool, sub: bool, name: []const u8, want: f32 }{
        .{ .cap = true, .sub = true, .name = "上限と刻み(本物)", .want = 93.0 },
        .{ .cap = false, .sub = true, .name = "上限なし", .want = 100.0 },
        .{ .cap = true, .sub = false, .name = "刻みなし", .want = 286.8 },
        .{ .cap = false, .sub = false, .name = "両方なし", .want = 82058.4 },
    };
    for (cases) |cs| {
        var s = Spring{ .x = 0, .v = 0, .target = 100, .response = 0.3, .damping = 0.6 };
        variant(&s, 1.0 / 60.0, cs.cap, cs.sub);
        variant(&s, 2.0, cs.cap, cs.sub);
        std.debug.print("{s}: x = {d:.1}\n", .{ cs.name, s.x });
        try std.testing.expectApproxEqRel(cs.want, s.x, 0.001);
    }
}

test "刻みの安定: 1 回で進めてよい最大の時間" {
    const cases = [_]struct { r: f32, z: f32, want: f32 }{
        .{ .r = 0.3, .z = 0.0, .want = 0.094 },
        .{ .r = 0.3, .z = 0.3, .want = 0.071 },
        .{ .r = 0.3, .z = 0.6, .want = 0.054 },
        .{ .r = 0.3, .z = 1.0, .want = 0.039 },
        .{ .r = 0.08, .z = 1.0, .want = 0.0105 },
    };
    for (cases) |cs| {
        const got = measure.stabilityLimit(cs.r, cs.z);
        std.debug.print("response {d}・damping {d}: {d:.4} 秒まで(60fps の 1 コマは 0.0167 秒)\n", .{ cs.r, cs.z, got });
        try std.testing.expectApproxEqAbs(cs.want, got, 0.001);
    }
}
