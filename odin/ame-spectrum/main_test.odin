package main

import "core:testing"

@(test)
test_bars :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_bars({}), 48)
	testing.expect_value(t, parse_bars({"-b", "32"}), 32)
	testing.expect_value(t, parse_bars({"-b", "0"}), 0)
	testing.expect_value(t, parse_bars({"-b", "999"}), 0)
	testing.expect_value(t, parse_bars({"-x"}), 0)
}

@(test)
test_edges :: proc(t: ^testing.T) {
	// 区切りは増えていき、FFT の半分を超えない
	e: [49]i32
	edges(e[:], 48)
	for i in 1 ..< len(e) do testing.expect(t, e[i] > e[i - 1] || e[i] == FFT_N / 2 - 1)
	testing.expect(t, e[48] <= FFT_N / 2 - 1)
}

@(test)
test_shape :: proc(t: ^testing.T) {
	// 無音なら 0 のまま。大きな山は 1 近くまで上がる
	bands := [4]f32{0, 0, 0, 0}
	values: [4]f32
	peak: f32 = -30
	shape(bands[:], values[:], &peak)
	for v in values do testing.expect_value(t, v, 0)
	bands = {1, 1e-6, 1e-6, 1e-6}
	shape(bands[:], values[:], &peak)
	testing.expect(t, values[0] > 0.9)
	testing.expect(t, values[1] < 0.1)
}
