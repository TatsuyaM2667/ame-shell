// 本物の anim/anim.odin の ame_spring_step に、演習と同じ不変条件と本文の数値を当てる。
// 単独では動かない(anim.o が要る)。sh learn/check-real.sh から呼ぶ。
const std = @import("std");
const spec = @import("spec.zig");
const measure = @import("measure.zig");

// Odin の b32 は 4 バイトの真偽値
extern fn ame_spring_step(s: *spec.Spring, dt: f32) u32;

fn step(s: *spec.Spring, dt: f32) bool {
    return ame_spring_step(s, dt) != 0;
}

test "本物(Odin)も不変条件をすべて満たす" {
    try spec.all(step);
}

test "本物(Odin)で本文の数値" {
    try measure.checkTable(step);
}
