/*
Package settings is what leita remembers of how the person likes it between
runs: the language they chose, the theme, and what monitoring watches
(monitor.odin). It lives in one SQLite file of its own, settings.db beside the
history store, so preferences never mix with the scans kept and either file can
be deleted without touching the other. The window and the command line share it.

A setting is a key and a text value. Only what the person chose is kept: a key
never written reads as absent, and the window then follows its own default (the
system's language, the OS theme).

A Store is not thread-safe: one thread uses it.
*/
package leita_settings

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "jm:sqlite3"

import "../schema"

// BUSY_WAIT is how long a write waits for another connection's to finish before
// it gives up: two windows may be open at once.
BUSY_WAIT :: 2 * time.Second

// The keys the window keeps.
LANGUAGE :: "language" // a BCP 47 tag, as i18n.locale_tag gives it
THEME    :: "theme" // "light", "dark", or "auto"; absent follows the OS
// UPDATES is "on" when the person opted in to automatic release checks.
// Absent is off, including a store written before the key existed, so an
// upgrade does not start checking.
UPDATES :: "updates"
// UPDATE_DISMISSED is the release version whose notice was dismissed.
UPDATE_DISMISSED :: "update_dismissed"
// UPDATE_CHECKED is the Unix seconds of the last automatic check, shared by
// every window so two of them do not both ask.
UPDATE_CHECKED :: "update_checked"

Store :: struct {
	db: sqlite3.Db,
	read_only: bool, // existing saved data is readable, but this connection cannot save
	read_only_reason: string, // static explanation; reopen after storage recovers
	legacy: bool, // an unversioned read-only store uses historical column defaults
}

@(private)
SCHEMA :: `
	CREATE TABLE IF NOT EXISTS setting(
		key TEXT PRIMARY KEY,
		value TEXT NOT NULL) WITHOUT ROWID;`

// FILE is the store's name, in the folder that holds the history store
// (licence.path_beside).
FILE :: "settings.db"

// SCHEMA_VERSION is the on-disk schema this build writes, stored in SQLite's
// user_version. Zero means a store from before versions were stamped: it is
// this schema, and opening it stamps this version. A greater version was
// written by a newer build. open refuses it and does not migrate or use it.
@(private)
SCHEMA_VERSION :: 1

// open opens the store at path, making it and its folder if they are missing.
// ":memory:" opens one that lasts as long as the connection. A store whose
// user_version is newer than SCHEMA_VERSION is refused and left as it was.
open :: proc(st: ^Store, path: string) -> sqlite3.Error {
	if path != sqlite3.MEMORY {
		if dir := filepath.dir(path); dir != "" {
			_ = os.make_directory_all(dir)
		}
	}
	db, err := sqlite3.open(path, {busy_timeout = BUSY_WAIT})
	if err == nil { err = adopt(db) }
	if err == nil {
		st.db = db
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
	for sql in ([]string{SCHEMA, MONITOR_SCHEMA, WEBHOOK_SCHEMA}) {
		sqlite3.exec(db, sql) or_return
	}
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

close :: proc(st: ^Store) {
	sqlite3.close(&st.db)
	st^ = {}
}

// get is the value kept under key, in allocator, and whether there is one.
get :: proc(
	st: ^Store,
	key: string,
	allocator := context.allocator,
) -> (
	value: string,
	found: bool,
) {
	rows, err := sqlite3.query(
		st.db,
		"SELECT value FROM setting WHERE key = ?",
		key,
		allocator = context.temp_allocator,
	)
	if err != nil {
		return "", false
	}
	defer sqlite3.finish(&rows)
	if !sqlite3.next(&rows) {
		return "", false
	}
	// text reads into the statement's allocator, the temp one here.
	return strings.clone(sqlite3.text(rows, 0), allocator), true
}

// set keeps value under key in place of any before it.
set :: proc(st: ^Store, key, value: string) -> sqlite3.Error {
	write_allowed(st) or_return
	return sqlite3.exec_args(
		st.db,
		`INSERT INTO setting(key, value) VALUES (?, ?)
			ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		key,
		value,
	)
}

/*
replace_if writes value under key only when the stored value is still
previous. Absent matches previous "". The write is one transaction, so two
windows that both saw the same previous cannot both record a check: one
commits, the other finds the value changed and leaves it.
*/
replace_if :: proc(st: ^Store, key, previous, value: string) -> (won: bool, err: sqlite3.Error) {
	if blocked := write_allowed(st); blocked != nil { return {}, blocked }
	if err = sqlite3.exec(st.db, "BEGIN IMMEDIATE"); err != nil {
		return false, err
	}
	current, read_err := setting_value(st, key)
	if read_err != nil {
		_ = sqlite3.exec(st.db, "ROLLBACK")
		return false, read_err
	}
	if current != previous {
		_ = sqlite3.exec(st.db, "ROLLBACK")
		return false, nil
	}
	if err = set(st, key, value); err != nil {
		_ = sqlite3.exec(st.db, "ROLLBACK")
		return false, err
	}
	if err = sqlite3.exec(st.db, "COMMIT"); err != nil {
		_ = sqlite3.exec(st.db, "ROLLBACK")
		return false, err
	}
	return true, nil
}

// setting_value is the text under key, "" when the key is absent. The caller
// compares it inside this transaction, so the default allocator is temporary.
@(private)
setting_value :: proc(
	st: ^Store,
	key: string,
	allocator := context.temp_allocator,
) -> (
	value: string,
	err: sqlite3.Error,
) {
	rows, qerr := sqlite3.query(
		st.db,
		"SELECT value FROM setting WHERE key = ?",
		key,
		allocator = context.temp_allocator,
	)
	if qerr != nil {
		return "", qerr
	}
	defer sqlite3.finish(&rows)
	if !sqlite3.next(&rows) {
		return "", nil
	}
	return strings.clone(sqlite3.text(rows, 0), allocator), nil
}

// Column is a column added to a table after the table was first made, and the
// statement that adds it.
@(private)
Column :: struct {
	table, name, add: string,
}

/*
ADDED is every column added since its table was first made. A store made
before gains each it lacks when it is opened, keeping all it holds; a row from
before reads as the column's default. Asking first makes opening a store any
number of times the same as opening it once.
*/
@(private)
ADDED := [?]Column {
	{"run", "updated", "ALTER TABLE run ADD COLUMN updated INTEGER NOT NULL DEFAULT 0"},
	{"run", "why", "ALTER TABLE run ADD COLUMN why TEXT NOT NULL DEFAULT ''"},
	{"run", "reread", "ALTER TABLE run ADD COLUMN reread INTEGER NOT NULL DEFAULT 0"},
	{"run", "taken", "ALTER TABLE run ADD COLUMN taken INTEGER NOT NULL DEFAULT 0"},
	{"run", "firing", "ALTER TABLE run ADD COLUMN firing TEXT NOT NULL DEFAULT ''"},
	{"watch", "warn_used", "ALTER TABLE watch ADD COLUMN warn_used INTEGER NOT NULL DEFAULT 0"},
	{"watch", "fail_used", "ALTER TABLE watch ADD COLUMN fail_used INTEGER NOT NULL DEFAULT 0"},
	{"watch", "min_free", "ALTER TABLE watch ADD COLUMN min_free INTEGER NOT NULL DEFAULT 0"},
	{
		"watch",
		"full_within",
		"ALTER TABLE watch ADD COLUMN full_within INTEGER NOT NULL DEFAULT 0",
	},
	{"watch", "growth", "ALTER TABLE watch ADD COLUMN growth INTEGER NOT NULL DEFAULT 0"},
}

// migrate adds each column in ADDED its table does not have yet.
@(private)
migrate :: proc(db: sqlite3.Db) -> sqlite3.Error {
	for column in ADDED {
		rows := sqlite3.query(
			db,
			"SELECT 1 FROM pragma_table_info(?) WHERE name = ?",
			column.table,
			column.name,
			allocator = db.allocator,
		) or_return
		has := sqlite3.next(&rows)
		sqlite3.finish(&rows) or_return
		if !has {
			sqlite3.exec(db, column.add) or_return
		}
	}
	return nil
}
