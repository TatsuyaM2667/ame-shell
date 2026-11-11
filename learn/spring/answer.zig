// 答え(演習を終えるまで見ない)。anim/anim.odin の spring_step を Zig に写したもの。
// 本物と 1 コマも違わないことを measure_test.zig と check-real.sh で確かめている。
const std = @import("std");
const spec = @import("spec.zig");
const Spring = spec.Spring;

const MAX_STEP: f32 = 0.001; // 1 回に進める時間の上限(1 ミリ秒)
const EPS_X: f32 = 0.005; // これより近ければ「着いた」
const EPS_V: f32 = 0.01; // これより遅ければ「止まった」

pub fn step(s: *Spring, dt: f32) bool {
    if (s.response <= 0) {
        s.x = s.target;
        s.v = 0;
        return false;
    }
    const omega: f32 = 6.2831853 / s.response; // ω = 2π / response
    const k = omega * omega; // ばねの強さ
    const c = 2 * s.damping * omega; // ブレーキの強さ

    var remaining = dt;
    if (remaining > 0.1) remaining = 0.1; // 一時停止のあとでも 0.1 秒ぶんしか進めない
    while (remaining > 0) {
        var h = remaining;
        if (h > MAX_STEP) h = MAX_STEP; // 1 ミリ秒ずつに刻む
        const a = -k * (s.x - s.target) - c * s.v; // 加速度
        s.v += a * h; // 先に速度
        s.x += s.v * h; // 新しい速度で位置
        remaining -= h;
    }

    if (@abs(s.x - s.target) < EPS_X and @abs(s.v) < EPS_V) {
        s.x = s.target;
        s.v = 0;
        return false;
    }
    return true;
}

test "答えは不変条件をすべて満たす" {
    try spec.all(step);
}
