package journeys

import "core:os"
import "core:strings"
import "core:testing"

// A person watches a folder, sees it listed with its limits, and stops watching it.
@(test)
a_place_is_watched_listed_and_forgotten :: proc(t: ^testing.T) {
	h := home(t, "monitor")
	defer leave(h)

	place := file_in(h, "watched")
	testing.expect(t, os.make_directory(place) == nil, "could not make the place to watch")

	r := run(t, h, -1, "monitor", "list")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "monitoring is off"), r.out)
	testing.expect(t, strings.contains(r.out, "no place is watched"), r.out)

	r = run(
		t,
		h,
		-1,
		"monitor",
		"add",
		place,
		"--every",
		"weekly",
		"--warn-used",
		"80",
		"--min-free",
		"20GB",
		"--growth",
	)
	expect_code(t, r, 0)
	testing.expectf(t, strings.contains(r.out, "weekly"), "%s", r.out)
	testing.expect(t, strings.contains(r.out, "monitoring is off"), r.out)

	r = run(t, h, -1, "monitor", "list")
	expect_code(t, r, 0)
	// The place is listed as the system names it: macOS says /private/var for /var.
	testing.expect(t, strings.contains(r.out, "watched  weekly"), r.out)
	testing.expect(t, strings.contains(r.out, "80% used"), r.out)
	testing.expect(t, strings.contains(r.out, "under 20.0 GB free"), r.out)
	testing.expect(t, strings.contains(r.out, "not scanned yet"), r.out)

	// Adding it again changes how it is watched, and does not watch it twice.
	r = run(t, h, -1, "monitor", "add", place)
	expect_code(t, r, 0)
	r = run(t, h, -1, "monitor", "list")
	testing.expect_value(t, strings.count(r.out, "watched  "), 1)
	testing.expect(t, strings.contains(r.out, "watched  daily"), r.out)

	r = run(t, h, -1, "monitor", "remove", place)
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "no longer watching"), r.out)
	r = run(t, h, -1, "monitor", "list")
	testing.expect(t, strings.contains(r.out, "no place is watched"), r.out)

	r = run(t, h, -1, "monitor", "remove", place)
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "is not watched"), r.out)
}

// What cannot be watched is refused with a reason and kept out of the list.
@(test)
a_place_that_cannot_be_watched_is_refused :: proc(t: ^testing.T) {
	h := home(t, "monitor_bad")
	defer leave(h)

	r := run(t, h, -1, "monitor", "add", file_in(h, "nowhere"))
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "is not there"), r.out)

	r = run(t, h, -1, "monitor", "add", h.dir, "--every", "sometimes")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "hourly, daily or weekly"), r.out)

	r = run(t, h, -1, "monitor", "add", h.dir, "--warn-used", "101")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "a percent"), r.out)

	r = run(t, h, -1, "monitor", "add", h.dir, "--min-free", "lots")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "cannot read --min-free"), r.out)

	r = run(t, h, -1, "monitor", "list")
	testing.expect(t, strings.contains(r.out, "no place is watched"), r.out)

	// Monitoring that is off scans nothing, whatever is watched.
	r = run(t, h, -1, "monitor", "run")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "monitoring is off: nothing to do"), r.out)
}
