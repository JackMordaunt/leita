/*
Package settings is what leita remembers of how the person likes it between
runs: the language they chose, the theme, and what monitoring watches
(monitor.odin). It lives in one SQLite file of its own, settings.db beside the
history store, so preferences never mix with the scans kept and either file can
be deleted without touching the other. The window and the command line share it.

A setting is a key and a text value. Only what the person chose is kept: a key
never written reads as absent, and the window then follows its own default (the
system's language, the light theme).

A Store is not thread-safe: one thread uses it.
*/
package leita_settings

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "jm:sqlite3"

// BUSY_WAIT is how long a write waits for another connection's to finish before
// it gives up: two windows may be open at once.
BUSY_WAIT :: 2 * time.Second

// The keys the window keeps.
LANGUAGE :: "language" // a BCP 47 tag, as i18n.locale_tag gives it
THEME    :: "theme" // "light" or "dark"

Store :: struct {
	db: sqlite3.Db,
}

@(private)
SCHEMA :: `
	CREATE TABLE IF NOT EXISTS setting(
		key TEXT PRIMARY KEY,
		value TEXT NOT NULL) WITHOUT ROWID;`

// FILE is the store's name, in the folder that holds the history store
// (licence.path_beside).
FILE :: "settings.db"

// open opens the store at path, making it and its folder if they are missing.
// ":memory:" opens one that lasts as long as the connection.
open :: proc(st: ^Store, path: string) -> sqlite3.Error {
	if path != sqlite3.MEMORY {
		if dir := filepath.dir(path); dir != "" {
			_ = os.make_directory_all(dir)
		}
	}
	db := sqlite3.open(path, {wal = true, busy_timeout = BUSY_WAIT}, context.allocator) or_return
	for schema in ([]string{SCHEMA, MONITOR_SCHEMA, WEBHOOK_SCHEMA}) {
		if err := sqlite3.exec(db, schema); err != nil {
			sqlite3.close(&db)
			return err
		}
	}
	if err := migrate(db); err != nil {
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
	return sqlite3.exec_args(
		st.db,
		`INSERT INTO setting(key, value) VALUES (?, ?)
			ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		key,
		value,
	)
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
			allocator = context.temp_allocator,
		) or_return
		has := sqlite3.next(&rows)
		sqlite3.finish(&rows) or_return
		if !has {
			sqlite3.exec(db, column.add) or_return
		}
	}
	return nil
}
