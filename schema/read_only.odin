package schema

import "core:c"
import "core:strings"
import "core:time"
import "jm:sqlite3"

// Only storage/permission failures can justify a read-only fallback. In
// particular corruption, newer schemas and a busy writer must stay errors.
can_read_only :: proc(err: sqlite3.Error) -> bool {
	if err == nil {
		return false
	}
	f := err.? or_else {}
	return(
		f.code == .Full ||
		f.code == .Read_Only ||
		f.code == .Io ||
		f.code == .Cant_Open ||
		f.code == .Perm \
	)
}

read_only_reason :: proc(path: string, err: sqlite3.Error) -> string {
	full, readonly := volume_state(path)
	if full || (err != nil && err.?.code == .Full) {
		return(
			"Saved data is read-only because the disk is full. Free space and reopen Leita to save changes." \
		)
	}
	if readonly || (err != nil && err.?.code == .Read_Only) {
		return(
			"Saved data is read-only because storage cannot be written. Make it writable and reopen Leita to save changes." \
		)
	}
	return(
		"Saved data can be read but cannot be written. Check free space and write access, then reopen Leita to save changes." \
	)
}

// read_only first uses SQLite's WAL-aware read-only mode. A checkpointed
// WAL database without sidecars may still require writing its directory;
// only then try a sidecar-free, exclusively guarded memory image.
read_only :: proc(path: string, wait: time.Duration) -> (db: sqlite3.Db, err: sqlite3.Error) {
	db, err = sqlite3.open(path, {read_only = true, busy_timeout = wait})
	if err == nil {
		_, err = user_version(db, db.allocator)
		if err == nil {
			err = sqlite3.exec(db, "PRAGMA query_only = ON")
			if err != nil {
				sqlite3.close(&db)
			}
			return
		}
		sqlite3.close(&db)
	}
	if !can_read_only(err) {
		return
	}
	delete(err.?.text) // the WAL-aware attempt failed; the next result owns its own fault
	return memory_image(path)
}

// table_exists distinguishes a genuinely absent old table from a failed
// read. Legacy callers may treat an absent feature table as empty.
table_exists :: proc(db: sqlite3.Db, table: string) -> (found: bool, err: sqlite3.Error) {
	rows := sqlite3.query(
		db,
		"SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?",
		table,
		allocator = context.temp_allocator,
	) or_return
	found = sqlite3.next(&rows)
	err = sqlite3.finish(&rows)
	return
}

// select_columns names existing columns and uses only the caller's explicit
// historical defaults for ones added later. No schema is changed.
select_columns :: proc(
	db: sqlite3.Db,
	table: string,
	columns, defaults: []string,
) -> (
	out: string,
	err: sqlite3.Error,
) {
	rows := sqlite3.query(
		db,
		"SELECT name FROM pragma_table_info(?)",
		table,
		allocator = context.temp_allocator,
	) or_return
	has := make(map[string]bool, context.temp_allocator)
	for sqlite3.next(&rows) {
		has[sqlite3.text(rows, 0)] = true
	}
	sqlite3.finish(&rows) or_return
	parts := make([]string, len(columns), context.temp_allocator)
	for name, i in columns {
		parts[i] = name if has[name] || defaults[i] == "" else defaults[i]
	}
	return strings.join(parts, ", ", context.temp_allocator), nil
}

// The stable version-1 prefix of sqlite3_file/sqlite3_io_methods:
// https://sqlite.org/c3ref/io_methods.html . These methods keep SQLite's
// own in-process lock bookkeeping, unlike raw process-scoped fcntl locks.
@(private)
File :: struct {
	methods: ^Methods,
}
@(private)
Methods :: struct {
	version:  c.int,
	close:    proc "c" (_: ^File) -> c.int,
	read:     proc "c" (_: ^File, _: rawptr, _: c.int, _: i64) -> c.int,
	write:    proc "c" (_: ^File, _: rawptr, _: c.int, _: i64) -> c.int,
	truncate: proc "c" (_: ^File, _: i64) -> c.int,
	sync:     proc "c" (_: ^File, _: c.int) -> c.int,
	size:     proc "c" (_: ^File, _: ^i64) -> c.int,
	lock:     proc "c" (_: ^File, _: c.int) -> c.int,
	unlock:   proc "c" (_: ^File, _: c.int) -> c.int,
}

// Bound the exceptional in-memory fallback independently of malloc's
// overcommit behaviour. Larger stores must remain an explicit open failure.
MEMORY_IMAGE_LIMIT :: i64(128 * 1024 * 1024)

@(private)
refuse_image :: proc(text: string, code := sqlite3.Code.Read_Only) -> sqlite3.Error {
	return sqlite3.Fault{code = code, text = strings.clone(text, context.allocator)}
}

// This never opens a raw OS handle to the database: closing such a handle
// can drop another SQLite connection's process-scoped POSIX locks.
@(private)
memory_image :: proc(path: string) -> (db: sqlite3.Db, err: sqlite3.Error) {
	source, open_err := sqlite3.open(path, {no_create = true})
	if open_err != nil {
		delete(open_err.?.text)
		source, open_err = sqlite3.open(path, {read_only = true})
	}
	if open_err != nil {
		return {}, open_err
	}
	defer sqlite3.close(&source)
	file: ^File
	if sqlite3.sqlite3_file_control(source.handle, "main", 7, &file) != 0 ||
	   file == nil ||
	   file.methods == nil {
		return {}, refuse_image("Cannot safely access the saved database without writing storage.")
	}
	canonical := string(sqlite3.sqlite3_db_filename(source.handle, "main"))
	if canonical == "" {
		return {}, refuse_image("Saved database has no stable filename.")
	}
	m := file.methods
	if m.lock(file, 1) != 0 {
		return {}, refuse_image("Saved data is busy; no read-only snapshot was taken.")
	}
	defer m.unlock(file, 0)
	physical_readonly := false
	if m.lock(file, 4) != 0 {
		// A physically read-only mount cannot have a writer. A merely
		// permission-denied file on a writable mount does not qualify.
		_, readonly := volume_state(canonical)
		if !readonly {
			return {}, refuse_image("Saved data is busy or cannot be locked; no read-only snapshot was taken.")
		}
		physical_readonly = true
	}
	if !sidecar_free(canonical) {
		return {}, refuse_image("Saved data has a journal or WAL; it cannot be safely read without its live state.")
	}
	moved: c.int
	if sqlite3.sqlite3_file_control(source.handle, "main", 20, &moved) != 0 || moved != 0 {
		return {}, refuse_image("Saved data moved while opening; no read-only snapshot was taken.")
	}
	n: i64
	if m.size(file, &n) != 0 || n < 100 || n > i64(max(int)) - 20 {
		return {}, refuse_image("Saved database has no readable complete image.")
	}
	if n > MEMORY_IMAGE_LIMIT {
		return {}, refuse_image("Saved database is too large for the bounded read-only memory fallback.")
	}
	// SQLite recommends 20 bytes of padding even for a readonly image:
	// https://sqlite.org/c3ref/deserialize.html . SQLite owns this allocation.
	data := cast([^]u8)sqlite3.sqlite3_malloc64(u64(n + 20))
	if data ==
	   nil {
	   	return {}, refuse_image("Not enough memory to read saved data without writing storage.", .No_Mem)
	   }
	transferred := false
	defer if !transferred {sqlite3.sqlite3_free(data)}
	for at: i64 = 0; at < n; {
		count := min(n - at, 1024 * 1024)
		if m.read(file, &data[at], c.int(count), at) !=
		   0 {
		   	return {}, refuse_image("Saved database could not be read completely.")
		   }
		at += count
	}
	for i in n ..< n + 20 {data[i] = 0}
	if string(data[:16]) !=
	   "SQLite format 3\x00" {
	   	return {}, refuse_image("file is not a database", .Not_A_Db)
	   }
	after: i64
	if m.size(file, &after) != 0 || after != n || !sidecar_free(canonical) {
		return {}, refuse_image("Saved database changed while reading; no read-only snapshot was taken.")
	}
	if sqlite3.sqlite3_file_control(source.handle, "main", 20, &moved) != 0 || moved != 0 {
		return {}, refuse_image("Saved database moved while reading; no read-only snapshot was taken.")
	}
	if physical_readonly {
		_, still_readonly := volume_state(canonical)
		if !still_readonly {
			return {}, refuse_image("Saved storage became writable while reading; no snapshot was taken.")
		}
	}
	if (data[18] != 1 && data[18] != 2) || (data[19] != 1 && data[19] != 2) {
		return {}, refuse_image("Saved database uses an unsupported file format.", .Not_A_Db)
	}
	// A checked, sidecar-free database is checkpointed. Deserialized
	// images cannot use WAL: change only this private memory copy's format
	// bytes to rollback mode, as SQLite's deserialize documentation directs.
	data[18], data[19] = 1, 1
	db, err = sqlite3.open(sqlite3.MEMORY)
	if err != nil {
		return
	}
	// FREEONCLOSE | READONLY. SQLite also frees on deserialize failure.
	code := sqlite3.sqlite3_deserialize(db.handle, "main", data, n, n + 20, 1 | 4)
	transferred = true
	if code != 0 {
		sqlite3.close(&db)
		return {}, refuse_image("Saved database could not be opened as a read-only memory image.")
	}
	if err = sqlite3.exec(db, "PRAGMA query_only = ON"); err != nil {
		sqlite3.close(&db)
	}
	return
}

@(private)
sidecar_free :: proc(path: string) -> bool {
	for suffix in ([]string{"-wal", "-shm", "-journal"}) {
		if !path_missing(strings.concatenate({path, suffix}, context.temp_allocator)) {
			return false
		}
	}
	return true
}

// require_select validates a store's readable schema without running DDL.
require_select :: proc(db: sqlite3.Db, sql: string) -> sqlite3.Error {
	rows := sqlite3.query(db, sql, allocator = db.allocator) or_return
	return sqlite3.finish(&rows)
}

// Header preflight through SQLite's VFS, without a raw fd whose close could
// release a different connection's POSIX locks. Opening here executes no SQL
// and never creates a missing file or rewrites a non-database.
empty_or_sqlite :: proc(path: string) -> bool {
	// SQLite's Unix VFS deliberately reports a one-byte file as empty.
	// file_size uses native POSIX stat, not core:os.stat's open/close pair.
	size, missing, known := file_size(path)
	if missing { return true }
	if !known { return false }
	if size == 0 { return true }
	if size < 16 { return false }

	db, err := sqlite3.open(path, {read_only = true})
	if err != nil {
		delete(err.?.text)
		return path_missing(path)
	}
	defer sqlite3.close(&db)
	file: ^File
	if sqlite3.sqlite3_file_control(db.handle, "main", 7, &file) != 0 ||
	   file == nil ||
	   file.methods == nil {
	   	return false
	   }
	n: i64
	if file.methods.size(file, &n) != 0 {
		return false
	}
	if n < 16 {
		return false
	}
	head: [16]u8
	return(
		file.methods.read(file, raw_data(head[:]), 16, 0) == 0 &&
		string(head[:]) == "SQLite format 3\x00" \
	)
}
