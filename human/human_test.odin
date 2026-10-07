package human

import "core:testing"

@(test)
sizes_and_counts_read_as_a_person_says_them :: proc(t: ^testing.T) {
	testing.expect_value(t, bytes(512), "512 B")
	testing.expect_value(t, bytes(1536), "1.5 KiB")
	testing.expect_value(t, bytes(5 << 30), "5.0 GiB")
	testing.expect_value(t, count(7), "7")
	testing.expect_value(t, count(1000), "1,000")
	testing.expect_value(t, count(1234567), "1,234,567")
}
