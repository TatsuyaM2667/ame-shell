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

@(test)
test_format_dev :: proc(t: ^testing.T) {
	d: Dev
	d.name_len = copy(d.name[:], "alsa_output.x")
	d.desc_len = copy(d.desc[:], "Speaker")
	line, keep := format_dev(&d, "alsa_output.x")
	testing.expect(t, keep)
	testing.expect_value(t, line, "alsa_output.x\tSpeaker\t*")
	m: Dev
	m.name_len = copy(m.name[:], "alsa_output.x.monitor")
	_, keep2 := format_dev(&m, "")
	testing.expect(t, !keep2)
}
