/*
Package history is what estoile remembers of the scans it has finished: for each,
when it was taken, its totals, and the size of every entry under its top that held
at least KEPT_MIN, so a later scan of the same place can say what grew and what
shrank since. It lives in one SQLite file in the user's data folder (default_path).

An entry is named by its path under the top, its names joined by "/" whatever the
platform, "" for the top itself; the top is named whole. Entries smaller than
KEPT_MIN are not kept, so an entry missing from a snapshot was smaller than that
then, or not there at all: nothing smaller can have held something bigger, so a
directory kept is all the way down to its entries kept.

The store keeps the KEPT newest snapshots of each place and forgets older ones.

It also keeps the audit trail: every change estoile made on disk at the person's
request, or tried to and could not, with when, what and why not. That is never
forgotten; the snapshots' pruning leaves it be.

A Store is not thread-safe: one thread uses it. The window and the command line
may each have the one file open at once.
*/
package estoile_history

import "core:os"
import "core:path/filepath"
import "core:time"

import "jm:sqlite3"

// KEPT_MIN is the least an entry holds to be kept in a snapshot: one that holds
// less now may not have been, so its absence from a snapshot says nothing about it.
KEPT_MIN :: 1 << 20

// KEPT is how many snapshots of one place are kept, newest first.
KEPT :: 30

// BUSY_WAIT is how long a write waits for another connection's to finish before
// it gives up.
BUSY_WAIT :: 2 * time.Second

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

// Action is one change estoile made on disk, or tried to: taken in Unix seconds,
// the path it was made to, and what that path held. detail is the new name of a
// rename, or why a failed action failed.
Action :: struct {
	taken:  i64,
	kind:   Action_Kind,
	path:   string,
	detail: string,
	bytes:  u64,
	failed: bool,
}

// Action_Kind is what was done: moved to the Trash, renamed, deleted for good by
// Reclaim, or deleted for good from the Trash as it was emptied.
Action_Kind :: enum u8 {
	Trash,
	Rename,
	Delete,
	Empty_Trash,
}

// ACTION_KINDS are the names the action table keeps the kinds by.
ACTION_KINDS := [Action_Kind]string {
	.Trash       = "trash",
	.Rename      = "rename",
	.Delete      = "delete",
	.Empty_Trash = "empty-trash",
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
		PRIMARY KEY(snapshot, path)) WITHOUT ROWID;
	CREATE TABLE IF NOT EXISTS action(
		id INTEGER PRIMARY KEY,
		taken INTEGER NOT NULL,
		kind TEXT NOT NULL,
		path TEXT NOT NULL,
		detail TEXT NOT NULL,
		bytes INTEGER NOT NULL,
		failed INTEGER NOT NULL);
	CREATE INDEX IF NOT EXISTS action_taken ON action(taken);`

// open opens the store at path, making it and its folder if they are missing.
// ":memory:" opens one that lasts as long as the connection.
open :: proc(st: ^Store, path: string) -> sqlite3.Error {
	if path != ":memory:" {
		if dir := filepath.dir(path); dir != "" {
			_ = os.make_directory_all(dir)
		}
	}
	// The window and the command line may both write at once: one waits for the
	// other's write, a short transaction, rather than failing at once.
	db := sqlite3.open(
		path,
		{wal = true, busy_timeout = BUSY_WAIT, on_open = "PRAGMA foreign_keys = ON"},
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
caller has already cut to those holding at least KEPT_MIN. It forgets the oldest
snapshots of top past KEPT, and returns the new one's id.
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

// record adds actions to the audit trail, all or none.
record :: proc(st: ^Store, actions: []Action) -> sqlite3.Error {
	if len(actions) == 0 {
		return nil
	}
	actions := actions
	body :: proc(db: sqlite3.Db, user: rawptr) -> sqlite3.Error {
		actions := (^[]Action)(user)^
		stmt := sqlite3.prepare(
			db,
			`INSERT INTO action(taken, kind, path, detail, bytes, failed)
				VALUES (?, ?, ?, ?, ?, ?)`,
			context.temp_allocator,
		) or_return
		defer sqlite3.finish(&stmt)
		for a in actions {
			sqlite3.bind(
				&stmt,
				a.taken,
				ACTION_KINDS[a.kind],
				a.path,
				a.detail,
				i64(a.bytes),
				a.failed,
			) or_return
			for sqlite3.next(&stmt) {}
			if stmt.err != nil {
				return stmt.err
			}
			sqlite3.reset(&stmt) or_return
		}
		return nil
	}
	return sqlite3.transact(st.db, body, &actions)
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
