package argv

import "core:testing"

// The checking line contains U+2026. Its UTF-8 is three bytes, and the
// single byte 0x85 is a different string.
@(test)
test_command_arg_keeps_the_checking_ellipsis :: proc(t: ^testing.T) {
	wide := []u16 {
		'C', 'h', 'e', 'c', 'k', 'i', 'n', 'g', ' ', 'f', 'o', 'r', ' ',
		'u', 'p', 'd', 'a', 't', 'e', 's', 0x2026,
	}
	got := command_arg(wide)
	defer delete(got)
	testing.expect_value(t, got, "Checking for updates…")
	testing.expect(t, got != "Checking for updates\x85")
	bulb := command_arg([]u16{0xD83D, 0xDCA1})
	defer delete(bulb)
	testing.expect_value(t, bulb, "💡")
	testing.expect_value(t, command_arg(nil), "")
}
