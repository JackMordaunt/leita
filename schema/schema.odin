/*
Package schema reads the schema version stamped on a SQLite store. history and
settings each decide what a version means; this only reads the number.
*/
package schema

import "jm:sqlite3"

// user_version is PRAGMA user_version. Zero is a store that was never stamped.
user_version :: proc(
	db: sqlite3.Db,
	allocator := context.temp_allocator,
) -> (
	version: i64,
	err: sqlite3.Error,
) {
	rows := sqlite3.query(db, "PRAGMA user_version", allocator = allocator) or_return
	if sqlite3.next(&rows) {
		version = sqlite3.integer(rows, 0)
	}
	err = sqlite3.finish(&rows)
	return
}
