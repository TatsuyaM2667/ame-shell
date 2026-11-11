// 障害ラボ: 一時停止のあと、窓が画面の外へ飛んでいく
//
// 報告: 「ノート PC を閉じて開いたら(またはデバッガで止めて再開したら)、開きかけの窓が画面の外へ消えた」
//
// 1. 再現する:      zig test learn/spring/lab_dt.zig
// 2. 症状を見る:    出力の「一時停止のあと x = …」(目標は 100)
// 3. 原因を探して、下の step を直す(本物の anim/anim.odin の spring_step と見比べてよい)
// 4. 直ったら、同じコマンドで試験が通る(再発防止の試験も一緒に通る)
const std = @import("std");
const spec = @import("spec.zig");
const Spring = spec.Spring;

const EPS_X: f32 = 0.005;
const EPS_V: f32 = 0.01;

/// 誰かが「すっきりさせた」版。どこかが足りない
pub fn step(s: *Spring, dt: f32) bool {
    if (s.response <= 0) {
        s.x = s.target;
        s.v = 0;
        return false;
    }
    const omega: f32 = 6.2831853 / s.response;
    const k = omega * omega;
    const c = 2 * s.damping * omega;

    const a = -k * (s.x - s.target) - c * s.v;
    s.v += a * dt;
    s.x += s.v * dt;

    if (@abs(s.x - s.target) < EPS_X and @abs(s.v) < EPS_V) {
        s.x = s.target;
        s.v = 0;
        return false;
    }
    return true;
}

test "再現: ふつうに 60fps で動かすと問題は見えない" {
    var s = Spring{ .x = 0, .v = 0, .target = 100, .response = 0.3, .damping = 0.6 };
    var n: usize = 0;
    while (step(&s, 1.0 / 60.0)) : (n += 1) if (n > 600) return error.DidNotSettle;
    std.debug.print("\n60fps では {d} コマで目標 {d} に着く(正常に見える)\n", .{ n, s.x });
}

test "再現: 一時停止(2 秒)のあと" {
    var s = Spring{ .x = 0, .v = 0, .target = 100, .response = 0.3, .damping = 0.6 };
    _ = step(&s, 1.0 / 60.0); // 1 コマ動いたところで
    _ = step(&s, 2.0); // 2 秒止まって、再開した最初のコマ
    std.debug.print("\n一時停止のあと x = {d:.1}(目標 100)\n", .{s.x});
    try spec.hugeDt(step);
}

test "再発防止: ばねの不変条件すべて" {
    try spec.all(step);
}
