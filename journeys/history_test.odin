package journeys

import "core:strings"
import "core:testing"

// A person scans a place again after a while and is told what changed.
@(test)
a_rescan_is_compared_with_the_scan_before :: proc(t: ^testing.T) {
	h := home(t, "history")
	defer leave(h)

	r := run(t, h, 0, "/Users/alex")
	expect_code(t, r, 0)
	testing.expect(
		t,
		strings.contains(r.out, "history    the first scan of this place kept"),
		r.out,
	)

	r = run(t, h, 0, "/Users/alex")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "history    unchanged since "), r.out)

	// Six days on the disk has grown, and the comparison says by how much.
	r = run(t, h, 6, "--report", "-", "--format", "json", "/Users/alex")
	expect_code(t, r, 0)
	doc := report(t, r.out)
	compared := member(doc, "compared")
	testing.expect_value(t, whole(compared, "bytes"), 320838590464)
	grown := whole(member(doc, "totals"), "bytes") - whole(compared, "bytes")
	testing.expectf(t, grown > 0, "the disk of day 6 did not grow: %d", grown)

	r = run(t, h, 6, "/Users/alex")
	expect_code(t, r, 0)
	testing.expectf(t, strings.contains(r.out, "history    unchanged since "), "%s", r.out)

	// A place never scanned has nothing to compare with.
	r = run(t, h, 6, "/Users/alex/Users")
	testing.expect(
		t,
		strings.contains(r.out, "history    the first scan of this place kept"),
		r.out,
	)

	// --no-history neither compares nor keeps.
	r = run(t, h, 9, "--no-history", "/Users/alex")
	testing.expect(t, !strings.contains(r.out, "\nhistory "), r.out)
	r = run(t, h, 9, "--report", "-", "--format", "json", "/Users/alex")
	testing.expect_value(
		t,
		whole(member(report(t, r.out), "compared"), "bytes"),
		whole(member(doc, "totals"), "bytes"),
	)

	// leita history lists what was deleted or changed at a request, and no scan was.
	r = run(t, h, 0, "history")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "nothing recorded"), r.out)
}
