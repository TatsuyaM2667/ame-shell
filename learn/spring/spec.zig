// ばねの「いつも成り立つはずのこと」(不変条件)の試験。
// 演習のファイル(ex1_fill.zig など)から `try spec.all(step);` で呼ぶ。
// 本物の Odin の ame_spring_step にも同じ試験を当てる(check-real.sh)。
//
// 失敗したときは、何が起きたかを日本語で出す(どこを直せばよいかの手がかり)。
const std = @import("std");

/// anim/anim.odin の Spring と同じ並び
pub const Spring = extern struct {
    x: f32, // 今の位置
    v: f32, // 速度(1 秒あたり)
    target: f32, // 目標
    response: f32, // 応答(秒)。小さいほど速い
    damping: f32, // 減衰比 ζ。1 = 行き過ぎない、1 未満 = 弾む
};

pub const StepFn = *const fn (*Spring, f32) bool;

const FRAME: f32 = 1.0 / 60.0;

fn fail(comptime fmt: []const u8, args: anytype) error{SpecFailed} {
    std.debug.print("\n✗ " ++ fmt ++ "\n", args);
    return error.SpecFailed;
}

/// 1. 時間が経てば目標に着いて止まる
pub fn converges(step: StepFn) !void {
    var s = Spring{ .x = 0, .v = 0, .target = 100, .response = 0.3, .damping = 0.6 };
    var frames: usize = 0;
    while (step(&s, FRAME)) : (frames += 1) {
        if (frames > 600) return fail("収束: 10 秒たっても止まらない(x = {d:.2}, v = {d:.2})。加速度の向き(目標へ引き戻す)と、止まる判定を見直して", .{ s.x, s.v });
    }
    if (s.x != 100 or s.v != 0) return fail("収束: 止まったのに目標ちょうどでない(x = {d}, v = {d})。止まるときに x = target・v = 0 にそろえて", .{ s.x, s.v });
}

/// 2. 減衰比 1 は行き過ぎない / 0.3 は行き過ぎる
pub fn overshoot(step: StepFn) !void {
    var crit = Spring{ .x = 0, .v = 0, .target = 100, .response = 0.3, .damping = 1.0 };
    var bouncy = Spring{ .x = 0, .v = 0, .target = 100, .response = 0.3, .damping = 0.3 };
    var max_c: f32 = 0;
    var max_b: f32 = 0;
    for (0..120) |_| {
        _ = step(&crit, FRAME);
        _ = step(&bouncy, FRAME);
        max_c = @max(max_c, crit.x);
        max_b = @max(max_b, bouncy.x);
    }
    if (max_c > 100.01) return fail("減衰: damping = 1 なのに {d:.2} まで行き過ぎた。減衰の項 c = 2·ζ·ω を見直して", .{max_c});
    if (max_b < 110) return fail("減衰: damping = 0.3 なのに最大 {d:.2} しか行かない(弾まない)。減衰が強すぎる", .{max_b});
}

/// 3. 目標を途中で変えても、位置は跳ばず、速度は 0 に戻らない
pub fn velocityContinuous(step: StepFn) !void {
    var s = Spring{ .x = 0, .v = 0, .target = 100, .response = 0.3, .damping = 1.0 };
    for (0..9) |_| _ = step(&s, FRAME);
    const x0 = s.x;
    const v0 = s.v;
    if (v0 < 50) return fail("速度の連続: 動き出して 9 コマなのに速度が {d:.2}。そもそも動いていない", .{v0});
    s.target = -50; // 逆向きへ
    _ = step(&s, 0.0001); // ほんの少しだけ進める
    if (@abs(s.x - x0) > 1) return fail("速度の連続: 目標を変えた瞬間に位置が {d:.2} → {d:.2} へ跳んだ", .{ x0, s.x });
    if (@abs(s.v - v0) > 0.05 * @abs(v0)) return fail("速度の連続: 目標を変えた瞬間に速度が {d:.2} → {d:.2}。x と v は引き継ぐ(0 に戻さない)", .{ v0, s.v });
}

/// 4. 一時停止のあと(dt = 2 秒)でも壊れない(画面の外へ飛ばない・ワープしない)
pub fn hugeDt(step: StepFn) !void {
    var s = Spring{ .x = 0, .v = 0, .target = 100, .response = 0.3, .damping = 0.6 };
    _ = step(&s, FRAME);
    _ = step(&s, 2.0);
    if (!std.math.isFinite(s.x) or s.x > 150 or s.x < -50) return fail("巨大な dt: 2 秒止まったあと x = {d:.1}(目標 100)。画面の外へ飛んだ。1 回で大きく進めず、小さな刻みに分けて", .{s.x});
    if (s.x == 100 and s.v == 0) return fail("巨大な dt: 2 秒止まったあと、一気に目標へワープした(動きが見えない)。dt に上限を", .{});
}

/// 5. response <= 0 は「すぐ目標へ」
pub fn zeroResponse(step: StepFn) !void {
    var s = Spring{ .x = 3, .v = 7, .target = 42, .response = 0, .damping = 1 };
    if (step(&s, FRAME)) return fail("response = 0: まだ動いていると答えた。すぐ目標にして false を返す", .{});
    if (s.x != 42 or s.v != 0) return fail("response = 0: x = {d}, v = {d}(42 と 0 のはず)。0 で割らないよう先に処理して", .{ s.x, s.v });
}

pub fn all(step: StepFn) !void {
    try zeroResponse(step);
    try converges(step);
    try overshoot(step);
    try velocityContinuous(step);
    try hugeDt(step);
    std.debug.print("\n✓ ばねの不変条件 5 つ、すべて成り立ちました\n", .{});
}
