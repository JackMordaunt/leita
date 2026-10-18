package human

import "core:fmt"
import "core:testing"

@(test)
sizes_read_in_decimal_units_and_step_up_where_the_decimal_would_round_over :: proc(
	t: ^testing.T,
) {
	testing.expect_value(t, bytes(0), "0 B")
	testing.expect_value(t, bytes(512), "512 B")
	testing.expect_value(t, bytes(999), "999 B")
	testing.expect_value(t, bytes(1000), "1.0 kB")
	testing.expect_value(t, bytes(1536), "1.5 kB")
	testing.expect_value(t, bytes(999_949), "999.9 kB")
	testing.expect_value(t, bytes(999_950), "1.0 MB")
	testing.expect_value(t, bytes(300_000), "300.0 kB")
	testing.expect_value(t, bytes(1_000_000_000), "1.0 GB")
	testing.expect_value(t, bytes(5 << 30), "5.4 GB")
	testing.expect_value(t, bytes(1_000_000_000_000), "1.0 TB")
	testing.expect_value(t, bytes(2_500_000_000_000_000), "2.5 PB")
	testing.expect_value(t, bytes(max(u64)), "18446.7 PB")
}

@(test)
counts_read_with_their_thousands_marked :: proc(t: ^testing.T) {
	testing.expect_value(t, count(7), "7")
	testing.expect_value(t, count(1000), "1,000")
	testing.expect_value(t, count(1234567), "1,234,567")
}

@(test)
parse_bytes_reads_a_size_a_flag_was_given_in_either_family :: proc(t: ^testing.T) {
	case_ok :: proc(t: ^testing.T, s: string, want: u64) {
		n, ok := parse_bytes(s)
		testing.expectf(t, ok, "%q did not parse", s)
		testing.expectf(t, n == want, "%q parsed to %d, want %d", s, n, want)
	}
	case_ok(t, "0", 0)
	case_ok(t, "512", 512)
	case_ok(t, "512B", 512)
	case_ok(t, "20GB", 20_000_000_000)
	case_ok(t, "20G", 20_000_000_000)
	case_ok(t, "20gb", 20_000_000_000)
	case_ok(t, "20 GB", 20_000_000_000)
	case_ok(t, "20GiB", 20 << 30)
	case_ok(t, "20gib", 20 << 30)
	case_ok(t, "20 GiB", 20 << 30)
	case_ok(t, "1.5TB", 1_500_000_000_000)
	case_ok(t, "1.5TiB", u64(1.5 * f64(1 << 40)))
	case_ok(t, " 5 MiB ", 5 << 20)
	case_ok(t, "5kB", 5000)
	case_ok(t, "5KiB", 5120)
	case_ok(t, "1PB", 1_000_000_000_000_000)
	case_ok(t, "1PiB", 1 << 50)

	// 10000PB is 10^19. It fits in a u64 and not in the i64 a size is kept as.
	bad := []string{"", "GiB", "abc", "-5GiB", "5XiB", "5 GiB extra", "5GiBB", "10000PB"}
	for s in bad {
		_, ok := parse_bytes(s)
		testing.expectf(t, !ok, "%q should not parse", s)
	}
}

// A name from a disk is shown without anything the terminal or a page would
// obey: C0 as pictures, and C1, bidi overrides and bad bytes as U+FFFD.
@(test)
a_name_is_shown_without_its_controls :: proc(t: ^testing.T) {
	testing.expect_value(t, shown("plain/ünï.txt"), "plain/ünï.txt")
	testing.expect_value(t, shown("\x1b[31mred\x1b[0m"), "\u241B[31mred\u241B[0m")
	testing.expect_value(t, shown("\x1b]52;c;AAAA\x07"), "\u241B]52;c;AAAA\u2407")
	testing.expect_value(t, shown("a\nb\rc\td"), "a\u240Ab\u240Dc\u2409d")
	testing.expect_value(t, shown("a\x7fb"), "a\u2421b")
	// The C1 controls, a one-byte CSI among them, are U+0080 to U+009F.
	testing.expect_value(t, shown("a\u009bb\u0080c\u009fd"), "a\uFFFDb\uFFFDc\uFFFDd")
	testing.expect_value(t, shown("a\xffb"), "a\uFFFDb")
	for r in ([?]rune{0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069}) {
		got := shown(fmt.tprintf("a%rb", r))
		testing.expectf(t, got == "a\uFFFDb", "U+%04X came back %q", r, got)
	}
	// Its neighbours are text.
	testing.expect_value(t, shown("a b c⁥d⁪e"), "a b c⁥d⁪e")
	// Markup and a leading = are not this package's to touch.
	testing.expect_value(t, shown("=1+1<img src=x>"), "=1+1<img src=x>")
}
