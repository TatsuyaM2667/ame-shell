package main

import "core:testing"

@(test)
test_target :: proc(t: ^testing.T) {
	testing.expect_value(t, target("40", 10), 40)
	testing.expect_value(t, target("40%", 10), 40)
	testing.expect_value(t, target("+5", 10), 15)
	testing.expect_value(t, target("-5", 10), 5)
	// 0〜100 に収める・読めないものは -1
	testing.expect_value(t, target("-50", 10), 0)
	testing.expect_value(t, target("+50", 90), 100)
	testing.expect_value(t, target("150", 10), -1)
	testing.expect_value(t, target("abc", 10), -1)
}
