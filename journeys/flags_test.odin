package journeys

import "core:fmt"
import "core:strings"
import "core:testing"

// A person tunes how leita reads: gentler, through the cache, with fewer
// readers, or whole. The answer is the made-up disk's either way. The volume
// reader's own flags (--workers, --chunk, --no-skip, --min-skip) are taken on
// any target and change nothing here. Drawn as it goes (--live), the summary
// ends the same, and a report, which needs a finished scan, is refused.
@(test)
the_read_flags_change_how_and_not_what :: proc(t: ^testing.T) {
	h := home(t, "flags")
	defer leave(h)

	runs := [][]string {
		{"--gentle"},
		{"--buffered"},
		{"--walk-workers", "2"},
		{"--whole"},
		{"--workers", "2", "--chunk", "1048576", "--no-skip", "--min-skip", "65536"},
	}
	for flags in runs {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "--no-history", "--report", "-", "--format", "json")
		append(&args, ..flags)
		append(&args, "/Users/alex")
		r := run(t, h, 0, ..args[:])
		if !expect_code(t, r, 0) {
			continue
		}
		totals := member(report(t, r.out), "totals")
		testing.expectf(
			t,
			whole(totals, "bytes") == 320838590464,
			"%v: the total is %d bytes",
			flags,
			whole(totals, "bytes"),
		)
	}

	r := run(t, h, 0, "--no-history", "--live", "/Users/alex")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "Docker.raw"), "--live ends on the largest file")
	r = run(t, h, 0, "--no-history", "--live", "--report", "-", "--format", "json", "/Users/alex")
	expect_code(t, r, 1)
	testing.expectf(
		t,
		strings.contains(r.err, "a report is written from a finished scan, not a live one"),
		"--live with a report says why not: %s",
		r.err,
	)
}

// A PDF is laid out on the paper asked for, whatever the locale's.
@(test)
a_pdf_is_laid_out_on_the_paper_asked_for :: proc(t: ^testing.T) {
	h := home(t, "paper")
	defer leave(h)

	// A4 is 595 x 842 points, US Letter 612 x 792.
	boxes := [2][2]string{{"a4", "/MediaBox [0 0 595"}, {"letter", "/MediaBox [0 0 612"}}
	for b in boxes {
		file := file_in(h, fmt.tprintf("%s.pdf", b[0]))
		r := run(t, h, 0, "--no-history", "--report", file, "--paper", b[0], "/Users/alex")
		expect_code(t, r, 0)
		pdf := read_file(file)
		testing.expectf(t, strings.contains(pdf, b[1]), "%s: no %q in the PDF", b[0], b[1])
	}
	r := run(
		t,
		h,
		0,
		"--no-history",
		"--report",
		file_in(h, "x.pdf"),
		"--paper",
		"a3",
		"/Users/alex",
	)
	expect_code(t, r, 1)
}

// --color always decorates a summary even in a pipe, as LEITA_COLOR does; never
// leaves it plain, whatever LEITA_COLOR says; --version says which leita this is.
@(test)
colour_and_version_are_as_asked :: proc(t: ^testing.T) {
	h := home(t, "colour")
	defer leave(h)

	r := run(t, h, 0, "--no-history", "--color", "always", "/Users/alex")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "\x1b["), "--color always is plain in a pipe")
	r = run(t, h, 0, "--no-history", "/Users/alex", extra = {"LEITA_COLOR=always"})
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "\x1b["), "LEITA_COLOR=always is plain in a pipe")
	// The flag outranks the environment.
	r = run(
		t,
		h,
		0,
		"--no-history",
		"--color",
		"never",
		"/Users/alex",
		extra = {"LEITA_COLOR=always"},
	)
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "Docker.raw"), "--color never says the summary")
	testing.expect(t, !strings.contains(r.out, "\x1b["), "--color never decorates")

	r = run(t, h, -1, "--version")
	expect_code(t, r, 0)
	testing.expectf(t, strings.has_prefix(r.out, "leita "), "--version says %q", r.out)
}
