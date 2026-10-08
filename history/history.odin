/*
Package history is what sonar remembers of the scans it has finished: for each,
when it was taken, its totals, and the size of every entry under its top that held
at least KEPT_MIN, so a later scan of the same place can say what grew and what
shrank since. It lives in one SQLite file in the user's data folder (default_path),
which the window and the command line share.

An entry is named by its path under the top, its names joined by "/" whatever the
platform, "" for the top itself; the top is named whole. Entries smaller than
KEPT_MIN are not kept, so an entry missing from a snapshot was smaller than that
then, or not there at all: nothing smaller can have held something bigger, so a
directory kept is all the way down to its entries kept.

The store keeps the KEPT newest snapshots of each place and forgets older ones.
It is not thread-safe: one thread uses it.
*/
package sonar_history

import "core:os"
import "core:path/filepath"

import "jm:sqlite3"

// KEPT_MIN is the least an entry holds to be kept in a snapshot. The window's
// query.KEPT_MIN tells the view the same, since the view cannot import this
// package; a test in gui/app holds the two equal.
KEPT_MIN :: 1 << 20

// KEPT is how many snapshots of one place are kept, newest first.
KEPT :: 30

Store :: struct {
	db: sqlite3.Db,
}

// Snapshot is one finished scan as remembered: when it was taken, in Unix
// seconds, and the totals of its top.
Snapshot :: struct {
	id:    i64,
	taken: i64,
	bytes: u64,
	items: u64,
}

// Entry is one entry of a snapshot: its path under the top, and what it held.
Entry :: struct {
	path:  string,
	bytes: u64,
}

@(private)
SCHEMA :: `
	CREATE TABLE IF NOT EXISTS snapshot(
		id INTEGER PRIMARY KEY,
		top TEXT NOT NULL,
		taken INTEGER NOT NULL,
		bytes INTEGER NOT NULL,
		items INTEGER NOT NULL);
	CREATE INDEX IF NOT EXISTS snapshot_top ON snapshot(top, taken);
	CREATE TABLE IF NOT EXISTS entry(
		snapshot INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
		path TEXT NOT NULL,
		bytes INTEGER NOT NULL,
		PRIMARY KEY(snapshot, path)) WITHOUT ROWID;`

// open opens the store at path, making it and its folder if they are missing.
// ":memory:" opens one that lasts as long as the connection.
open :: proc(st: ^Store, path: string) -> sqlite3.Error {
	if path != ":memory:" {
		if dir := filepath.dir(path); dir != "" {
			_ = os.make_directory_all(dir)
		}
	}
	db := sqlite3.open(
		path,
		{wal = true, busy_timeout = 1000, on_open = "PRAGMA foreign_keys = ON"},
		context.allocator,
	) or_return
	if err := sqlite3.exec(db, SCHEMA); err != nil {
		sqlite3.close(&db)
		return err
	}
	st.db = db
	return nil
}

close :: proc(st: ^Store) {
	sqlite3.close(&st.db)
	st^ = {}
}

/*
save remembers a scan of top taken at taken: its totals and entries, which the
caller has already cut to those holding at least KEPT_MIN, as collect does. It
forgets the oldest snapshots of top past KEPT, and returns the new one's id.
*/
save :: proc(
	st: ^Store,
	top: string,
	taken: i64,
	bytes, items: u64,
	entries: []Entry,
) -> (
	id: i64,
	err: sqlite3.Error,
) {
	Save :: struct {
		top:          string,
		taken:        i64,
		bytes, items: u64,
		entries:      []Entry,
		id:           i64,
	}
	s := Save{top, taken, bytes, items, entries, 0}
	body :: proc(db: sqlite3.Db, user: rawptr) -> sqlite3.Error {
		s := (^Save)(user)
		sqlite3.exec_args(
			db,
			"INSERT INTO snapshot(top, taken, bytes, items) VALUES (?, ?, ?, ?)",
			s.top,
			s.taken,
			i64(s.bytes),
			i64(s.items),
		) or_return
		s.id = sqlite3.last_id(db)
		stmt := sqlite3.prepare(
			db,
			"INSERT INTO entry(snapshot, path, bytes) VALUES (?, ?, ?)",
			context.temp_allocator,
		) or_return
		defer sqlite3.finish(&stmt)
		for e in s.entries {
			sqlite3.bind(&stmt, s.id, e.path, i64(e.bytes)) or_return
			for sqlite3.next(&stmt) {}
			if stmt.err != nil {
				return stmt.err
			}
			sqlite3.reset(&stmt) or_return
		}
		return sqlite3.exec_args(
			db,
			`DELETE FROM snapshot WHERE top = ? AND id NOT IN
				(SELECT id FROM snapshot WHERE top = ? ORDER BY taken DESC, id DESC LIMIT ?)`,
			s.top,
			s.top,
			i64(KEPT),
		)
	}
	sqlite3.transact(st.db, body, &s) or_return
	return s.id, nil
}

// list is the snapshots of top, newest first, in allocator.
list :: proc(
	st: ^Store,
	top: string,
	allocator := context.temp_allocator,
) -> (
	out: []Snapshot,
	err: sqlite3.Error,
) {
	rows := sqlite3.query(
		st.db,
		"SELECT id, taken, bytes, items FROM snapshot WHERE top = ? ORDER BY taken DESC, id DESC",
		top,
		allocator = context.temp_allocator,
	) or_return
	found := make([dynamic]Snapshot, allocator)
	for sqlite3.next(&rows) {
		append(
			&found,
			Snapshot {
				id = sqlite3.integer(rows, 0),
				taken = sqlite3.integer(rows, 1),
				bytes = u64(sqlite3.integer(rows, 2)),
				items = u64(sqlite3.integer(rows, 3)),
			},
		)
	}
	if err = sqlite3.finish(&rows); err != nil {
		delete(found)
		return nil, err
	}
	return found[:], nil
}

// load is the entries of snapshot id, by path, in allocator: the map and its
// keys both.
load :: proc(
	st: ^Store,
	id: i64,
	allocator := context.allocator,
) -> (
	out: map[string]u64,
	err: sqlite3.Error,
) {
	rows := sqlite3.query(
		st.db,
		"SELECT path, bytes FROM entry WHERE snapshot = ?",
		id,
		allocator = allocator,
	) or_return
	out = make(map[string]u64, allocator)
	for sqlite3.next(&rows) {
		out[sqlite3.text(rows, 0)] = u64(sqlite3.integer(rows, 1))
	}
	if err = sqlite3.finish(&rows); err != nil {
		forget(out)
		return nil, err
	}
	return out, nil
}

// forget frees what load returned.
forget :: proc(m: map[string]u64) {
	for k in m {
		delete(k, m.allocator)
	}
	delete(m)
}
