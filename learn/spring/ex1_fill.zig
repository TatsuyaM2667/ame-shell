// 演習 1: 穴埋め(穴は 4 つ)
//
// step の中の `hole1(…)`〜`hole4(…)` を、正しい式に書き換える(例: `hole1(omega)` → `omega * …`)。
// 穴の関数(このファイルの下)は 0 を返すだけの仮のもの。全部書き換えたら使われなくなる。
//
// 確かめる:  zig test learn/spring/ex1_fill.zig
// 全部通ると「✓ ばねの不変条件 5 つ、すべて成り立ちました」と出る。
// 通らないときは「✗ 〜」の行が、どの不変条件が壊れているかを教えてくれる。
const std = @import("std");
const spec = @import("spec.zig");
const Spring = spec.Spring;

const MAX_STEP: f32 = 0.001;
const EPS_X: f32 = 0.005;
const EPS_V: f32 = 0.01;

pub fn step(s: *Spring, dt: f32) bool {
    if (s.response <= 0) {
        s.x = s.target;
        s.v = 0;
        return false;
    }
    const omega: f32 = 6.2831853 / s.response; // ω = 2π / response

    const k = hole1(omega); // ばねの強さ。ω を使って
    const c = hole2(s.damping, omega); // ブレーキの強さ。減衰比 ζ と ω を使って

    var remaining = dt;
    if (remaining > 0.1) remaining = 0.1;
    while (remaining > 0) {
        var h = remaining;
        if (h > MAX_STEP) h = MAX_STEP;
        const a = hole3(s.x - s.target, s.v, k, c); // 加速度。「目標からのずれ」と「速度」を使って
        s.v += hole4(a, h); // 速度を a と h で進める(位置より先に)
        s.x += s.v * h;
        remaining -= h;
    }

    if (@abs(s.x - s.target) < EPS_X and @abs(s.v) < EPS_V) {
        s.x = s.target;
        s.v = 0;
        return false;
    }
    return true;
}

// ---- 仮の穴(書き換えたら使われなくなる。消してもよい) ----
fn hole1(omega: f32) f32 {
    _ = omega;
    return 0;
}
fn hole2(zeta: f32, omega: f32) f32 {
    _ = zeta;
    _ = omega;
    return 0;
}
fn hole3(dx: f32, v: f32, k: f32, c: f32) f32 {
    _ = dx;
    _ = v;
    _ = k;
    _ = c;
    return 0;
}
fn hole4(a: f32, h: f32) f32 {
    _ = a;
    _ = h;
    return 0;
}

test "演習 1: 穴埋め" {
    try spec.all(step);
}
