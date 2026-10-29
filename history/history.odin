/*
Package history is what leita remembers of the scans it has finished: for each,
when it was taken, its totals, the disk it was on and what of that was free, and
the size of every entry under its top that held at least KEPT_MIN, so a later scan of the same place can say what grew and what
shrank since. It lives in one SQLite file in the user's data folder (default_path).

An entry is named by its path under the top, its names joined by "/" whatever the
platform, "" for the top itself; the top is named whole. Entries smaller than
KEPT_MIN are not kept, so an entry missing from a snapshot was smaller than that
then, or not there at all: nothing smaller can have held something bigger, so a
directory kept is all the way down to its entries kept.

The store keeps the KEPT newest snapshots of each place and forgets older ones.

It also keeps the audit trail: every change leita made on disk at the person's
request, or tried to and could not, with when, what and why not. That is never
forgotten; the snapshots' pruning leaves it be.

A Store is not thread-safe: one thread uses it. The window and the command line
may each have the one file open at once.
*/
package leita_history

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

import "jm:sqlite3"

import "../gui/query"
import "../schema"

// KEPT_MIN is the least an entry holds to be kept in a snapshot, as the window
// is told it is.
KEPT_MIN :: query.KEPT_MIN

// KEPT is how many snapshots of one place are kept, newest first. Newest is the
// order they were kept in, here as everywhere in the store, not the order of
// their stamps: a clock set back stamps the newest scan earlier than the last,
// and ordering by the stamp listed it last and forgot it as the oldest.
KEPT :: 30

// BUSY_WAIT is how long a write waits for another connection's to finish before
// it gives up.
BUSY_WAIT :: 2 * time.Second

Store :: struct {
	db: sqlite3.Db,
	read_only: bool, // existing saved data is readable, but this connection cannot save
	read_only_reason: string, // static explanation; reopen after storage recovers
	legacy: bool, // an unversioned read-only store uses historical column defaults
}

// Snapshot is one finished scan as remembered: when it was taken, in Unix
// seconds, the totals of its top, and the disk it was on.
Snapshot :: struct {
	id:    i64,
	taken: i64,
	bytes: u64,
	items: u64,
	disk:  Disk,
}

// Disk is the size of the filesystem a scan was on and what of it was free to
// the user then. Both are zero when that was not known: a raw device or an
// image has no mounted filesystem to ask, and a snapshot kept before the disk
// was kept does not say.
Disk :: struct {
	total, free: u64,
}

// Action is one change leita made on disk, or tried to: taken in Unix seconds,
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
		items INTEGER NOT NULL,
		disk_total INTEGER NOT NULL DEFAULT 0,
		disk_free INTEGER NOT NULL DEFAULT 0);
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

// SCHEMA_VERSION is the on-disk schema this build writes, stored in SQLite's
// user_version. Zero means a store from before versions were stamped: it is
// this schema, and opening it stamps this version. A greater version was
// written by a newer build. open refuses it and does not migrate or use it.
@(private)
SCHEMA_VERSION :: 1

// open opens the store at path, making it and its folder if they are missing, and
// deletes the baselines beside it no scan has rewritten in BASELINE_KEPT.
// ":memory:" opens one that lasts as long as the connection. A store whose
// user_version is newer than SCHEMA_VERSION is refused and left as it was.
open :: proc(st: ^Store, path: string) -> sqlite3.Error {
	if path != ":memory:" {
		if dir := filepath.dir(path); dir != "" {
			_ = os.make_directory_all(dir)
		}

		// SQLite takes a file of one byte for an empty database and writes a
		// new one over it. A file that holds anything and does not begin with
		// SQLite's header is not a store, so it is refused and left as it was.
		if !empty_or_sqlite(path) {
			return sqlite3.Fault{code = .Not_A_Db, text = "file is not a database"}
		}
	}
	// The window and the command line may both write at once: one waits for the
	// other's write, a short transaction, rather than failing at once.
	db, err := sqlite3.open(path, {busy_timeout = BUSY_WAIT, on_open = "PRAGMA foreign_keys = ON"})
	if err == nil { err = adopt(db) }
	if err == nil {
		st.db = db
		if path != sqlite3.MEMORY { prune_baselines(path, time.now()) }
		return nil
	}
	sqlite3.close(&db)
	if path == sqlite3.MEMORY || !schema.can_read_only(err) { return err }
	result := open_read_only(st, path, err)
	delete(err.?.text) // the failed writable connection no longer owns its copied fault text
	return result
}

// adopt refuses a newer schema, then migrates and stamps a store this build
// understands. The journal mode is set after that, so a refusal leaves the
// file as it was.
@(private)
adopt :: proc(db: sqlite3.Db) -> sqlite3.Error {
	version := schema.user_version(db, db.allocator) or_return
	if version > SCHEMA_VERSION {
		return newer_schema(version)
	}
	sqlite3.exec(db, "BEGIN IMMEDIATE") or_return
	committed := false
	defer if !committed { _ = sqlite3.exec(db, "ROLLBACK") }
	sqlite3.exec(db, SCHEMA) or_return
	migrate(db) or_return
	if version < SCHEMA_VERSION {
		stamp_schema(db) or_return
	}
	sqlite3.exec(db, "COMMIT") or_return
	committed = true
	_ = sqlite3.exec(db, "PRAGMA journal_mode = WAL")
	return nil
}

// newer_schema is the refusal for a store a newer build wrote. The text names
// both versions. The caller closes the connection without migrating.
@(private)
newer_schema :: proc(version: i64) -> sqlite3.Error {
	return sqlite3.Fault {
		code = .Error,
		text = fmt.aprintf(
			"schema version %d is newer than schema version %d, which this build reads",
			version,
			SCHEMA_VERSION,
		),
	}
}

// stamp_schema records SCHEMA_VERSION. The caller skips a store already there.
@(private)
stamp_schema :: proc(db: sqlite3.Db) -> sqlite3.Error {
	return sqlite3.exec(db, fmt.tprintf("PRAGMA user_version = %d", SCHEMA_VERSION))
}

// SQLITE_HEADER is the first 16 bytes of every SQLite database file.
SQLITE_HEADER :: "SQLite format 3\x00"

// empty_or_sqlite is true when path is missing, is empty, or begins with
// SQLite's header: the files sqlite3.open may create or write to.
@(private)
empty_or_sqlite :: proc(path: string) -> bool {
	return schema.empty_or_sqlite(path)
}

// ADDED_COLUMNS is each column added to snapshot since the store was first made,
// and the statement that adds it. A store made before gains them when it is
// opened, keeping all it holds; its snapshots read as not knowing the disk.
@(private)
ADDED_COLUMNS := [?][2]string {
	{"disk_total", "ALTER TABLE snapshot ADD COLUMN disk_total INTEGER NOT NULL DEFAULT 0"},
	{"disk_free", "ALTER TABLE snapshot ADD COLUMN disk_free INTEGER NOT NULL DEFAULT 0"},
}

// migrate adds to snapshot each column in ADDED_COLUMNS that it does not have
// yet, so opening a store any number of times is the same as opening it once.
@(private)
migrate :: proc(db: sqlite3.Db) -> sqlite3.Error {
	rows := sqlite3.query(
		db,
		"SELECT name FROM pragma_table_info('snapshot')",
		allocator = db.allocator,
	) or_return
	has := make(map[string]bool, context.temp_allocator)
	defer for name in has { delete(name, db.allocator) }
	for sqlite3.next(&rows) {
		has[sqlite3.text(rows, 0)] = true
	}
	sqlite3.finish(&rows) or_return
	for column in ADDED_COLUMNS {
		if !has[column[0]] {
			sqlite3.exec(db, column[1]) or_return
		}
	}
	return nil
}

close :: proc(st: ^Store) {
	sqlite3.close(&st.db)
	st^ = {}
}

// describe says what err, from this store or another SQLite one, says went
// wrong, in the temp allocator.
describe :: proc(err: sqlite3.Error) -> string {
	f := err.? or_else {}
	return f.text if f.text != "" else fmt.tprint(f.code)
}

/*
save remembers a scan of top taken at taken: its totals, the disk it was on, and
its entries, which the caller has already cut to those holding at least KEPT_MIN.
It forgets the oldest snapshots of top past KEPT, and returns the new one's id.
*/
save :: proc(
	st: ^Store,
	top: string,
	taken: i64,
	bytes, items: u64,
	entries: []Entry,
	disk := Disk{},
) -> (
	id: i64,
	err: sqlite3.Error,
) {
	if blocked := write_allowed(st); blocked != nil { return {}, blocked }
	Save :: struct {
		top:          string,
		taken:        i64,
		bytes, items: u64,
		entries:      []Entry,
		disk:         Disk,
		id:           i64,
	}
	s := Save{top, taken, bytes, items, entries, disk, 0}
	body :: proc(db: sqlite3.Db, user: rawptr) -> sqlite3.Error {
		s := (^Save)(user)
		sqlite3.exec_args(
			db,
			`INSERT INTO snapshot(top, taken, bytes, items, disk_total, disk_free)
				VALUES (?, ?, ?, ?, ?, ?)`,
			s.top,
			s.taken,
			i64(s.bytes),
			i64(s.items),
			i64(s.disk.total),
			i64(s.disk.free),
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
				(SELECT id FROM snapshot WHERE top = ? ORDER BY id DESC LIMIT ?)`,
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
	write_allowed(st) or_return
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

/*
actions is the audit trail, newest first: the actions taken at or after since, in
Unix seconds, 0 for all of them, and at most limit of them, 0 for no limit. Its
strings are in allocator.
*/
actions :: proc(
	st: ^Store,
	since: i64 = 0,
	limit := 0,
	allocator := context.temp_allocator,
) -> (
	out: []Action,
	err: sqlite3.Error,
) {
	if st.read_only && st.legacy {
		exists := schema.table_exists(st.db, "action") or_return
		if !exists { return nil, nil }
	}

	rows := sqlite3.query(
		st.db,
		`SELECT taken, kind, path, detail, bytes, failed FROM action
			WHERE taken >= ? ORDER BY id DESC LIMIT ?`,
		since,
		i64(limit) if limit > 0 else -1,
		allocator = allocator,
	) or_return
	found := make([dynamic]Action, allocator)
	for sqlite3.next(&rows) {
		kind := sqlite3.text(rows, 1)
		append(
			&found,
			Action {
				taken = sqlite3.integer(rows, 0),
				kind = kind_named(kind),
				path = sqlite3.text(rows, 2),
				detail = sqlite3.text(rows, 3),
				bytes = u64(sqlite3.integer(rows, 4)),
				failed = sqlite3.boolean(rows, 5),
			},
		)
		delete(kind, allocator)
	}
	if err = sqlite3.finish(&rows); err != nil {
		delete(found)
		return nil, err
	}
	return found[:], nil
}

// kind_named is the Action_Kind the action table keeps as name; a name this
// leita does not know, written by a newer one, reads as a Trash.
@(private)
kind_named :: proc(name: string) -> Action_Kind {
	for text, kind in ACTION_KINDS {
		if text == name {
			return kind
		}
	}
	return .Trash
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
	read_sql := `SELECT id, taken, bytes, items, disk_total, disk_free FROM snapshot
			WHERE top = ? ORDER BY id DESC`
	if st.read_only && st.legacy {
		selected := schema.select_columns(st.db, "snapshot", {"id", "taken", "bytes", "items", "disk_total", "disk_free"}, {"", "", "", "", "0", "0"}) or_return
		read_sql = fmt.tprintf("SELECT %s FROM snapshot WHERE top = ? ORDER BY id DESC", selected)
	}

	rows := sqlite3.query(
		st.db,
		read_sql,
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
				disk = {u64(sqlite3.integer(rows, 4)), u64(sqlite3.integer(rows, 5))},
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
