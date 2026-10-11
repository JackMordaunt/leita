package leita_history

import "core:testing"

import "jm:sqlite3"

import "../scan"
import "../survey"

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

@(test)
actions_are_kept_in_the_audit_trail_as_recorded :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	testing.expect(t, record(&st, nil) == nil, "nothing to record is no error")
	done := []Action {
		{1000, .Trash, "/home/ann/old.iso", "", 4 << 30, false},
		{1001, .Rename, "/home/ann/photos", "pictures", 2 << 20, false},
		{1002, .Delete, "/home/ann/app/node_modules", "permission denied", 9 << 20, true},
		{1003, .Empty_Trash, "/home/ann/.Trash/ünï.txt", "", 12, false},
	}
	testing.expect(t, record(&st, done) == nil)

	rows, err := sqlite3.query(
		st.db,
		"SELECT taken, kind, path, detail, bytes, failed FROM action ORDER BY id",
		allocator = context.temp_allocator,
	)
	testing.expect(t, err == nil)
	got := 0
	for sqlite3.next(&rows) {
		want := done[got]
		testing.expect_value(t, sqlite3.integer(rows, 0), want.taken)
		testing.expect_value(t, sqlite3.text(rows, 1), ACTION_KINDS[want.kind])
		testing.expect_value(t, sqlite3.text(rows, 2), want.path)
		testing.expect_value(t, sqlite3.text(rows, 3), want.detail)
		testing.expect_value(t, u64(sqlite3.integer(rows, 4)), want.bytes)
		testing.expect_value(t, sqlite3.integer(rows, 5) != 0, want.failed)
		got += 1
	}
	testing.expect(t, sqlite3.finish(&rows) == nil)
	testing.expect_value(t, got, len(done))
}

// A made-up disk's scans are kept apart from the real disk's at the same path.
@(test)
a_made_up_disk_is_kept_apart :: proc(t: ^testing.T) {
	tree: scan.Tree
	testing.expect(t, scan.tree_init(&tree) == nil)
	defer scan.tree_destroy(&tree)
	w := scan.writer(&tree, 0)
	top, _ := scan.claim(&w, 1)
	n := scan.node(&tree, top)
	n.parent = top
	n.name = scan.intern(&w, "/")
	scan.node_publish(n, {.Used, .Settled, .Directory})
	testing.expect_value(t, place_of(&tree, top, .Walk), "/")
	testing.expect_value(t, place_of(&tree, top, .Synthetic), "synthetic:/")
}

/*
A scan kept holds its top and everything under it of at least KEPT_MIN, all the
way down, and nothing smaller:

	/top/                 3 MiB + 10 bytes
	/top/big/             3 MiB
	/top/big/a.bin        2 MiB
	/top/big/b.bin        1 MiB
	/top/small.txt        10 bytes
*/
@(test)
a_kept_scan_holds_what_is_at_least_kept_min :: proc(t: ^testing.T) {
	tree: scan.Tree
	testing.expect(t, scan.tree_init(&tree) == nil)
	defer scan.tree_destroy(&tree)
	w := scan.writer(&tree, 0)
	first, _ := scan.claim(&w, 5)
	add :: proc(w: ^scan.Writer, i, parent: u32, name: string, disk: u64, flags: scan.Node_Flags) {
		n := scan.node(w.tree, i)
		n.parent = parent
		n.disk = disk
		n.name = scan.intern(w, name)
		scan.node_publish(n, flags)
	}
	add(&w, first, first, "/top", 0, {.Used, .Settled, .Directory})
	add(&w, first + 1, first, "big", 0, {.Used, .Settled, .Directory})
	add(&w, first + 2, first + 1, "a.bin", 2 << 20, {.Used, .Settled})
	add(&w, first + 3, first + 1, "b.bin", 1 << 20, {.Used, .Settled})
	add(&w, first + 4, first, "small.txt", 10, {.Used, .Settled})
	roll := survey.Rollup {
		linked = true,
	}
	defer survey.rollup_destroy(&roll)
	survey.rollup_advance(&roll, &tree)

	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)
	id, err := keep(&st, "/top", &tree, &roll, first, 5)
	testing.expect(t, err == nil)

	got, _ := load(&st, id)
	defer forget(got)
	want := []Entry {
		{"", 3 << 20 + 10},
		{"big", 3 << 20},
		{"big/a.bin", 2 << 20},
		{"big/b.bin", 1 << 20},
	}
	testing.expect_value(t, len(got), len(want))
	for e in want {
		testing.expectf(t, got[e.path] == e.bytes, "%q came back as %v", e.path, got[e.path])
	}
	// A node is looked up by the name it was kept under.
	testing.expect_value(t, entry_path(&tree, first, first), "")
	testing.expect_value(t, entry_path(&tree, first, first + 1), "big")
	testing.expect_value(t, entry_path(&tree, first, first + 2), "big/a.bin")
	snap, found := latest(&st, "/top")
	testing.expect(t, found)
	testing.expect_value(t, snap.items, 5)
	_, other := latest(&st, "/top", id)
	testing.expect(t, !other, "no snapshot but the one kept")
}
