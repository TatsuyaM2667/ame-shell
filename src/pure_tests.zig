// OS/GPU に依存しない部分のテスト(`zig build test`)。クロスターゲットでも走らせられる。
const std = @import("std");
const anim = @import("anim.zig");
test {
    _ = @import("config.zig");
}

test "spring converges and is velocity-continuous" {
    var s = anim.Spring.init(0, 0.3, 0.8);
    s.set(100);
    var t: f32 = 0;
    while (t < 0.1) : (t += 1.0 / 60.0) _ = s.step(1.0 / 60.0);
    const v_before = s.v;
    try std.testing.expect(v_before > 0);
    // 途中で目標を変えても速度は保たれる
    s.set(-50);
    try std.testing.expectEqual(v_before, s.v);
    var frames: usize = 0;
    while (s.step(1.0 / 60.0)) frames += 1;
    try std.testing.expectEqual(@as(f32, -50), s.x);
    try std.testing.expect(frames < 200);
}

test "fuzzy match ranks prefix and word starts" {
    try std.testing.expect(anim.fuzzy("ff", "Firefox") > 0);
    try std.testing.expect(anim.fuzzy("xyz", "Firefox") < 0);
    try std.testing.expect(anim.fuzzy("fi", "Firefox") > anim.fuzzy("fi", "Profile"));
    try std.testing.expect(anim.fuzzy("ter", "ターミナル Terminal") > 0);
    try std.testing.expect(anim.fuzzy("ターミ", "ターミナル") > 0);
}

test "dominant color picks saturated" {
    var px: [16 * 4]u8 = undefined;
    for (0..16) |i| {
        const sat = i < 5;
        px[i * 4 + 0] = if (sat) 30 else 128;
        px[i * 4 + 1] = if (sat) 90 else 128;
        px[i * 4 + 2] = if (sat) 230 else 128;
        px[i * 4 + 3] = 255;
    }
    var work: [4096 * 4]u32 = undefined;
    const col = anim.ame_dominant_color(&px, 16, 1, &work);
    try std.testing.expect((col & 0xff) > 200); // 青が選ばれる
}
