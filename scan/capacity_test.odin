package scan

import "core:testing"

@(test)
freebsd_capacity_rejects_overflow_and_invalid_counts :: proc(t: ^testing.T) {
	for input in ([?][3]u64{{1, 0, 0}, {10, 11, 512}, {max(u64), 0, 512}}) {
		_, _, ok := freebsd_capacity(input[0], input[1], input[2])
		testing.expect(t, !ok, "invalid capacity was presented as known")
	}
	total, free, ok := freebsd_capacity(10, 0, 4096)
	testing.expect(t, ok, "a full disk is a known measurement")
	testing.expect_value(t, total, u64(40960))
	testing.expect_value(t, free, u64(0))
	total, free, ok = freebsd_capacity(1 << 40, 1 << 39, 4096)
	testing.expect(t, ok, "large volumes retain their 64-bit counts")
	testing.expect_value(t, total, u64(1 << 52))
	testing.expect_value(t, free, u64(1 << 51))
}
