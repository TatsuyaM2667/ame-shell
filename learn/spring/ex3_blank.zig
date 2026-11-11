// 演習 3: 白紙(何も見ずに書く)
//
// 確かめる:  zig test learn/spring/ex3_blank.zig
// 決まっていること: Spring の形(spec.zig)と、step の形 `fn (*Spring, f32) bool`(まだ動いていれば true)。
const std = @import("std");
const spec = @import("spec.zig");
const Spring = spec.Spring;

pub fn step(s: *Spring, dt: f32) bool {
    _ = s;
    _ = dt;
    return false;
}

test "演習 3: 白紙" {
    try spec.all(step);
}
