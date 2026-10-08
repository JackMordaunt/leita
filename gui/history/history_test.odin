package sonar_history

import "core:testing"

@(test)
a_snapshot_comes_back_as_it_was_saved :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	entries := []Entry{{"", 5 << 20}, {"a", 3 << 20}, {"a/big.bin", 2 << 20}, {"ünï/b", 1 << 20}}
	id, err := save(&st, "/home/ann", 1000, 5 << 20, 42, entries)
	testing.expect(t, err == nil)
	testing.expect(t, id > 0)

	got, lerr := load(&st, id)
	testing.expect(t, lerr == nil)
	defer forget(got)
	testing.expect_value(t, len(got), 4)
	for e in entries {
		testing.expectf(t, got[e.path] == e.bytes, "%q came back as %v", e.path, got[e.path])
	}

	snaps, _ := list(&st, "/home/ann")
	testing.expect_value(t, len(snaps), 1)
	testing.expect_value(t, snaps[0], Snapshot{id, 1000, 5 << 20, 42})
	other, _ := list(&st, "/home/bob")
	testing.expect_value(t, len(other), 0)
}

@(test)
only_the_newest_snapshots_of_a_place_are_kept :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	first, _ := save(&st, "/elsewhere", 1, 1, 1, []Entry{{"x", 1}})
	ids: [KEPT + 2]i64
	for i in 0 ..< len(ids) {
		ids[i], _ = save(&st, "/home/ann", i64(100 + i), u64(i), 1, []Entry{{"a", u64(i)}})
	}
	snaps, _ := list(&st, "/home/ann")
	testing.expect_value(t, len(snaps), KEPT)
	testing.expect_value(t, snaps[0].id, ids[len(ids) - 1])
	testing.expect_value(t, snaps[KEPT - 1].id, ids[2])

	// The forgotten take their entries with them; another place keeps its own.
	gone, _ := load(&st, ids[0])
	defer forget(gone)
	testing.expect_value(t, len(gone), 0)
	kept, _ := load(&st, first)
	defer forget(kept)
	testing.expect_value(t, len(kept), 1)
}
