package leita_history

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "jm:sqlite3"

import "../scan"
import "../survey"
import "../testtmp"

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
	testing.expect_value(t, snaps[0], Snapshot{id, 1000, 5 << 20, 42, {}})
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

// Each place's baseline is a file of its own beside the store, and the same place
// always finds the same one.
@(test)
test_a_baseline_lives_beside_the_store :: proc(t: ^testing.T) {
	store := filepath.join({"data", "leita", "history.db"}, context.temp_allocator) or_else ""
	home := baseline_path(store, "/home/me", context.temp_allocator)
	testing.expect_value(
		t,
		filepath.dir(home),
		filepath.join({"data", "leita", "baselines"}, context.temp_allocator) or_else "",
	)
	testing.expect_value(t, baseline_path(store, "/home/me", context.temp_allocator), home)
	testing.expect(
		t,
		baseline_path(store, "/home/you", context.temp_allocator) != home,
		"two places share a baseline",
	)
	testing.expect_value(t, baseline_path("", "/home/me", context.temp_allocator), "")
}

// A file of one byte that is not SQLite's is refused and left as it was. SQLite
// itself takes it for an empty database and writes a new one over it; the
// history fuzz suite's store property found this.
@(test)
a_one_byte_file_is_refused_not_rewritten :: proc(t: ^testing.T) {
	dir, dir_err := testtmp.make_dir("", "leita-onebyte-*", context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	defer os.remove_all(dir)

	store := filepath.join({dir, "history.db"}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(store, []u8{'e'}) == nil)
	st: Store
	err := open(&st, store)
	if err == nil {
		close(&st)
	}
	fault, _ := err.(sqlite3.Fault)
	testing.expect_value(t, fault.code, sqlite3.Code.Not_A_Db)
	after, read_err := os.read_entire_file(store, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(after), "e")
}

// Opening the store deletes the baselines beside it no scan has rewritten in
// BASELINE_KEPT, a stopped save's temporary file among them, and keeps the rest.
@(test)
test_opening_the_store_prunes_old_baselines :: proc(t: ^testing.T) {
	dir, dir_err := testtmp.make_dir("", "leita-prune-*", context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	defer os.remove_all(dir)
	store := filepath.join({dir, "history.db"}, context.temp_allocator) or_else ""
	recent := baseline_path(store, "/home/me", context.temp_allocator)
	old := baseline_path(store, "/home/gone", context.temp_allocator)
	stopped := fmt.tprintf("%s.7-0.new", old)
	testing.expect(t, os.make_directory_all(filepath.dir(recent)) == nil)
	for path in ([]string{recent, old, stopped}) {
		testing.expectf(t, os.write_entire_file(path, []u8{1}) == nil, "could not write %s", path)
	}
	now := time.now()
	month := time.time_add(now, -(BASELINE_KEPT + time.Hour))
	nearly := time.time_add(now, -(BASELINE_KEPT - time.Hour))
	testing.expect(t, os.change_times(old, month, month) == nil)
	testing.expect(t, os.change_times(stopped, month, month) == nil)
	testing.expect(t, os.change_times(recent, nearly, nearly) == nil)

	st: Store
	testing.expect(t, open(&st, store) == nil)
	close(&st)
	testing.expect(t, os.exists(recent), "a baseline younger than BASELINE_KEPT was deleted")
	testing.expect(t, !os.exists(old), "a baseline older than BASELINE_KEPT was kept")
	testing.expect(t, !os.exists(stopped), "a stopped save's temporary file was kept")
}

// A snapshot keeps the disk it was on; a store made before the disk was kept
// gains the columns when opened, its snapshots reading as not knowing the disk,
// and opening it again changes nothing.
@(test)
a_snapshot_keeps_its_disk_and_an_older_store_gains_it :: proc(t: ^testing.T) {
	dir, derr := testtmp.make_dir("", "leita-history-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "history.db"}, context.temp_allocator)
	{
		db, err := sqlite3.open(path, {}, context.temp_allocator)
		testing.expect(t, err == nil)
		testing.expect(
			t,
			sqlite3.exec(
				db,
				`CREATE TABLE snapshot(id INTEGER PRIMARY KEY, top TEXT NOT NULL,
					taken INTEGER NOT NULL, bytes INTEGER NOT NULL, items INTEGER NOT NULL);
				INSERT INTO snapshot(top, taken, bytes, items) VALUES ('/srv', 10, 7, 1);`,
			) ==
			nil,
		)
		sqlite3.close(&db)
	}
	for _ in 0 ..< 2 {
		st: Store
		testing.expect(t, open(&st, path) == nil)
		snaps, _ := list(&st, "/srv")
		testing.expect_value(t, len(snaps), 1)
		testing.expect_value(t, snaps[0].disk, Disk{})
		close(&st)
	}
	st: Store
	testing.expect(t, open(&st, path) == nil)
	defer close(&st)
	_, err := save(&st, "/srv", 20, 9, 1, {{"", 9}}, Disk{100 << 30, 40 << 30})
	testing.expect(t, err == nil)
	snaps, _ := list(&st, "/srv")
	testing.expect_value(t, snaps[0].disk, Disk{100 << 30, 40 << 30})
	testing.expect_value(t, snaps[1].taken, 10)
}

// A baseline last written more than BASELINE_KEPT ago is deleted, a recent one and a
// folder are not: the folder is listed without statx, so on Linux 4.9 as on 7.x.
@(test)
old_baselines_are_pruned_and_recent_ones_kept :: proc(t: ^testing.T) {
	base, base_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, base_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_history_prune_%d", base, os.get_pid())
	os.remove_all(root)
	baselines := fmt.tprintf("%s/baselines", root)
	testing.expect(t, os.make_directory_all(baselines) == nil || os.exists(baselines), "could not make the folder")
	defer os.remove_all(root)
	old := fmt.tprintf("%s/old.tree", baselines)
	recent := fmt.tprintf("%s/recent.tree", baselines)
	testing.expect(t, os.write_entire_file(old, []byte{'o'}) == nil, "could not write old")
	testing.expect(t, os.write_entire_file(recent, []byte{'r'}) == nil, "could not write recent")
	long_ago := time.time_add(time.now(), -2 * BASELINE_KEPT)
	testing.expect(t, os.change_times(old, long_ago, long_ago) == nil, "could not age old")

	prune_baselines(fmt.tprintf("%s/store.db", root), time.now())
	testing.expect(t, !os.exists(old), "an old baseline was kept")
	testing.expect(t, os.exists(recent), "a recent baseline was deleted")
}

// A temporary file a stopped baseline save left is deleted once it is older than
// STAGE_KEPT, not kept as long as a baseline; one a save may still be writing stays.
@(test)
a_stopped_saves_temporary_file_is_pruned_within_the_hour :: proc(t: ^testing.T) {
	base, base_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, base_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_history_stage_%d", base, os.get_pid())
	os.remove_all(root)
	baselines := fmt.tprintf("%s/baselines", root)
	testing.expect(t, os.make_directory_all(baselines) == nil || os.exists(baselines), "could not make the folder")
	defer os.remove_all(root)

	stopped := fmt.tprintf("%s/0123456789abcdef.tree.41-1.new", baselines)
	writing := fmt.tprintf("%s/0123456789abcdef.tree.42-1.new", baselines)
	kept := fmt.tprintf("%s/0123456789abcdef.tree", baselines)
	for path in ([]string{stopped, writing, kept}) {
		testing.expect(t, os.write_entire_file(path, []byte{'x'}) == nil, "could not write a file")
	}
	ago := time.time_add(time.now(), -2 * STAGE_KEPT)
	testing.expect(t, os.change_times(stopped, ago, ago) == nil, "could not age the stopped save's file")
	testing.expect(t, os.change_times(kept, ago, ago) == nil, "could not age the baseline")

	prune_baselines(fmt.tprintf("%s/store.db", root), time.now())
	testing.expect(t, !os.exists(stopped), "a stopped save's temporary file was kept")
	testing.expect(t, os.exists(writing), "a save's fresh temporary file was deleted")
	testing.expect(t, os.exists(kept), "a baseline younger than BASELINE_KEPT was deleted")
}
