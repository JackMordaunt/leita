package leita_history

import "core:testing"

/*
The clock a scan is stamped by moves: corrected forward after a dead battery,
set back by hand, wrong by a year. History is the order things happened on this
machine, so the scan kept last is the newest whatever its stamp says: the one
the next scan is compared with, the first one listed, and never the one the
store forgets to keep KEPT.
*/

@(test)
the_scan_kept_last_is_the_newest_whatever_the_clock_said :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)
	top :: "/home/ann"
	entries := []Entry{{"", 1}}

	DAY :: 86_400
	at := i64(1_800_000_000)
	first, _ := save(&st, top, at, 1, 1, entries)
	// A year ahead, as a clock set by hand to the wrong year reads.
	ahead, _ := save(&st, top, at + 365 * DAY, 2, 1, entries)
	// Corrected: back a year and a day, earlier than the first.
	back, _ := save(&st, top, at - DAY, 3, 1, entries)

	snaps, err := list(&st, top)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(snaps), 3)
	if len(snaps) == 3 {
		testing.expect_value(t, snaps[0].id, back)
		testing.expect_value(t, snaps[1].id, ahead)
		testing.expect_value(t, snaps[2].id, first)
		// The stamps are as they were taken; only the order is the machine's.
		testing.expect_value(t, snaps[0].taken, at - DAY)
	}
	latest_snap, found := latest(&st, top)
	testing.expect(t, found)
	testing.expect_value(t, latest_snap.id, back)
	before, found_before := latest(&st, top, except = back)
	testing.expect(t, found_before)
	testing.expect_value(t, before.id, ahead)
}

// A store full to KEPT, the clock then set back: the scan just kept stays, and
// the oldest kept goes, not the newest because its stamp is the earliest.
@(test)
a_scan_kept_after_the_clock_went_back_is_not_forgotten :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)
	top :: "/srv"
	entries := []Entry{{"", 1}}

	at := i64(1_800_000_000)
	ids: [KEPT]i64
	for i in 0 ..< KEPT {
		ids[i], _ = save(&st, top, at + i64(i) * 3600, u64(i), 1, entries)
	}
	back, err := save(&st, top, at - 10 * 365 * 86_400, 99, 1, entries)
	testing.expect(t, err == nil)

	snaps, _ := list(&st, top)
	testing.expect_value(t, len(snaps), KEPT)
	kept := false
	for s in snaps {
		kept ||= s.id == back
		testing.expectf(t, s.id != ids[0], "the oldest kept, %d, stayed", ids[0])
	}
	testing.expect(t, kept, "the scan just kept was forgotten")
	got, lerr := load(&st, back)
	testing.expect(t, lerr == nil)
	defer forget(got)
	testing.expect_value(t, len(got), 1)
}

// The record of what leita did is newest first by the order it was done, the
// same way.
@(test)
the_record_is_in_the_order_it_was_made :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)
	at := i64(1_800_000_000)
	testing.expect(t, record(&st, {{taken = at, kind = .Trash, path = "/a"}}) == nil)
	testing.expect(t, record(&st, {{taken = at + 86_400, kind = .Trash, path = "/b"}}) == nil)
	testing.expect(t, record(&st, {{taken = at - 86_400, kind = .Trash, path = "/c"}}) == nil)
	done, err := actions(&st)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(done), 3)
	if len(done) == 3 {
		testing.expect_value(t, done[0].path, "/c")
		testing.expect_value(t, done[1].path, "/b")
		testing.expect_value(t, done[2].path, "/a")
	}
}
