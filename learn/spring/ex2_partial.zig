// 演習 2: 一部空白(関数の中身を、コメントの順に書く)
//
// 確かめる:  zig test learn/spring/ex2_partial.zig
const std = @import("std");
const spec = @import("spec.zig");
const Spring = spec.Spring;

const MAX_STEP: f32 = 0.001; // 1 回に進める時間の上限
const EPS_X: f32 = 0.005; // これより近ければ「着いた」
const EPS_V: f32 = 0.01; // これより遅ければ「止まった」

pub fn step(s: *Spring, dt: f32) bool {
    // 1. response が 0 以下なら、すぐ目標にして false
    // 2. ω・k・c を求める
    // 3. dt を 0.1 秒までに抑える
    // 4. 残り時間を 1 ミリ秒ずつ: 加速度 → 速度 → 位置
    // 5. 着いて止まっていれば、目標ちょうどにそろえて false。まだなら true
    _ = s;
    _ = dt;
    return false;
}

test "演習 2: 一部空白" {
    try spec.all(step);
}
