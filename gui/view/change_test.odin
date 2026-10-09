package estoile_view

import "core:testing"

@(test)
a_change_is_classed_by_how_far_it_went :: proc(t: ^testing.T) {
	MiB  :: u64(1 << 20)
	Case :: struct {
		bytes:    u64,
		was:      i64,
		compared: bool,
		want:     Change,
	}
	cases := []Case {
		{10 * MiB, i64(10 * MiB), true, .Same},
		{10 * MiB + 32 << 10, i64(10 * MiB), true, .Same}, // under CHANGE_SAME
		{102 * MiB, i64(100 * MiB), true, .Same}, // 2% of what it held
		{103 * MiB, i64(100 * MiB), true, .Grew},
		{150 * MiB, i64(100 * MiB), true, .Grew_Much}, // by half again
		{97 * MiB, i64(100 * MiB), true, .Shrank},
		{50 * MiB, i64(100 * MiB), true, .Shrank_Much},
		{0, i64(100 * MiB), true, .Shrank_Much},
		{2 * MiB, -1, true, .Grew_Much}, // not kept then, kept now: new
		{512 << 10, -1, true, .Same}, // too small to say
		{2 * MiB, i64(MiB), false, .Same}, // nothing compared
	}
	for c in cases {
		got := change_of(c.bytes, c.was, c.compared)
		testing.expectf(t, got == c.want, "%v from %v: %v, want %v", c.bytes, c.was, got, c.want)
	}
}

@(test)
a_change_reads_as_a_signed_size :: proc(t: ^testing.T) {
	MiB :: u64(1 << 20)
	testing.expect_value(t, delta_text(3 * MiB, i64(MiB), true), "+2.0 MiB")
	testing.expect_value(t, delta_text(MiB, i64(3 * MiB), true), "−2.0 MiB")
	testing.expect_value(t, delta_text(MiB, i64(MiB), true), "")
	testing.expect_value(t, delta_text(2 * MiB, -1, true), "new")
	testing.expect_value(t, delta_text(1024, -1, true), "")
	testing.expect_value(t, delta_text(3 * MiB, i64(MiB), false), "")
}
