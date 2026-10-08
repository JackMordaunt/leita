package sonar_history

import "core:os"
import "core:path/filepath"
import "core:testing"

import "jm:sqlite3"

// A store made before snapshots knew their disk gains the columns when opened,
// keeps what it held, reads its old snapshots as not knowing the disk, and saves
// and reads the disk of new ones.
@(test)
a_store_from_before_the_disk_was_kept_is_brought_up_to_date :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "sonar-history-migrate-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "history.db"}, context.temp_allocator)

	old, oerr := sqlite3.open(path)
	testing.expect(t, oerr == nil)
	testing.expect(
		t,
		sqlite3.exec(
			old,
			`CREATE TABLE snapshot(
				id INTEGER PRIMARY KEY,
				top TEXT NOT NULL,
				taken INTEGER NOT NULL,
				bytes INTEGER NOT NULL,
				items INTEGER NOT NULL);
			CREATE INDEX snapshot_top ON snapshot(top, taken);
			CREATE TABLE entry(
				snapshot INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
				path TEXT NOT NULL,
				bytes INTEGER NOT NULL,
				PRIMARY KEY(snapshot, path)) WITHOUT ROWID;
			INSERT INTO snapshot(id, top, taken, bytes, items) VALUES (7, '/srv', 100, 9, 3);
			INSERT INTO entry(snapshot, path, bytes) VALUES (7, '', 9);`,
		) ==
		nil,
	)
	sqlite3.close(&old)

	st: Store
	testing.expect(t, open(&st, path) == nil, "an old store opens")
	id, err := save(&st, "/srv", 200, 10, 4, []Entry{{"", 10}}, {1000, 250})
	testing.expect(t, err == nil)
	snaps, _ := list(&st, "/srv")
	if testing.expect_value(t, len(snaps), 2) {
		testing.expect_value(t, snaps[0], Snapshot{id, 200, 10, 4, {1000, 250}})
		testing.expect_value(t, snaps[1], Snapshot{7, 100, 9, 3, {}})
	}
	kept, _ := load(&st, 7)
	defer forget(kept)
	testing.expect_value(t, kept[""], 9)
	close(&st)

	// Opening it again finds the columns there and adds nothing.
	testing.expect(t, open(&st, path) == nil, "a migrated store opens again")
	again, _ := list(&st, "/srv")
	if testing.expect_value(t, len(again), 2) {
		testing.expect_value(t, again[0], Snapshot{id, 200, 10, 4, {1000, 250}})
		testing.expect_value(t, again[1], Snapshot{7, 100, 9, 3, {}})
	}
	close(&st)
}

@(test)
a_snapshot_comes_back_as_it_was_saved :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	entries := []Entry{{"", 5 << 20}, {"a", 3 << 20}, {"a/big.bin", 2 << 20}, {"ünï/b", 1 << 20}}
	id, err := save(&st, "/home/ann", 1000, 5 << 20, 42, entries, {500 << 30, 120 << 30})
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
	testing.expect_value(t, snaps[0], Snapshot{id, 1000, 5 << 20, 42, {500 << 30, 120 << 30}})
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
