package journeys

import "core:strings"
import "core:testing"

// The first thing a person does: scan, and read what is biggest.
@(test)
a_first_scan_names_the_biggest_files_and_folders :: proc(t: ^testing.T) {
	h := home(t, "scan")
	defer leave(h)

	r := run(t, h, 0, "/Users/alex")
	expect_code(t, r, 0)
	testing.expect(
		t,
		strings.contains(r.out, "This is a made-up disk"),
		"the summary does not say the disk is made up",
	)
	testing.expect(t, strings.contains(r.out, "read whole"), "a first scan reads the disk whole")

	biggest := line_after(r.out, "largest files")
	testing.expectf(t, strings.contains(biggest, "Docker.raw"), "the biggest file is %q", biggest)
	folder := line_after(r.out, "largest directories")
	testing.expectf(
		t,
		strings.has_suffix(slashes(folder), "/Users"),
		"the biggest folder is %q",
		folder,
	)
	testing.expect(
		t,
		!strings.contains(r.out, "\x1b["),
		"a summary piped to a file carries colour",
	)
}

// A limit crossed is an exit code, so a script can act on it.
@(test)
a_limit_crossed_is_an_exit_code :: proc(t: ^testing.T) {
	h := home(t, "limits")
	defer leave(h)

	// The made-up volume is 69 percent used, with 151 GB free of 494 GB.
	Case :: struct {
		flag, value: string,
		code:        int,
	}
	cases := []Case {
		{"--warn-used", "99", 0},
		{"--warn-used", "50", 2},
		{"--fail-used", "50", 3},
		{"--min-free", "100GB", 0},
		{"--min-free", "400GB", 3},
		{"--warn-used", "lots", 1},
	}
	for c in cases {
		r := run(t, h, 0, "--no-history", c.flag, c.value, "/Users/alex")
		testing.expectf(
			t,
			r.code == c.code,
			"%s %s exited %d, want %d",
			c.flag,
			c.value,
			r.code,
			c.code,
		)
	}
}
