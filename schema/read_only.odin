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
// WAL database may still require writing its directory to create the wal
// index. When that write cannot be done, a headerless WAL left by the
// failed open holds no pages; the guarded memory image reads the main file.
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
	// The failed open may have created a zero-length WAL and a short -shm.
	// Those hold no committed pages. A WAL long enough for its header still
	// blocks the image, as does an empty sidecar passed straight to it.
	return memory_image(path, true)
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
// headerless_wal_ok is set only after SQLite's own read-only open has
// already failed for lack of storage. A direct caller must not set it: an
// empty sidecar, or a database busy with a writer, stays a refusal.
@(private)
memory_image :: proc(
	path: string,
	headerless_wal_ok := false,
) -> (
	db: sqlite3.Db,
	err: sqlite3.Error,
) {
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
	if image_blocked(canonical, headerless_wal_ok) {
		return {}, refuse_image("Saved data has a journal or WAL; it cannot be safely read without its live state.")
	}
	if file_moved(source) {
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
	if data == nil {
		return {}, refuse_image("Not enough memory to read saved data without writing storage.", .No_Mem)
	}
	transferred := false
	defer if !transferred {sqlite3.sqlite3_free(data)}
	for at: i64 = 0; at < n; {
		count := min(n - at, 1024 * 1024)
		if m.read(file, &data[at], c.int(count), at) != 0 {
			return {}, refuse_image("Saved database could not be read completely.")
		}
		at += count
	}
	for i in n ..< n + 20 {data[i] = 0}
	if string(data[:16]) != "SQLite format 3\x00" {
		return {}, refuse_image("file is not a database", .Not_A_Db)
	}
	after: i64
	if m.size(file, &after) != 0 || after != n || image_blocked(canonical, headerless_wal_ok) {
		return {}, refuse_image("Saved database changed while reading; no read-only snapshot was taken.")
	}
	if file_moved(source) {
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
	// Deserialized images cannot use WAL. No WAL frame was present, so the
	// main file is the checkpoint: change only this private copy's format
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

// image_blocked refuses every sidecar unless the caller has already shown
// that SQLite cannot open the store. In that case only a journal with bytes,
// or a WAL long enough to contain its 32-byte header, is live state. A
// headerless WAL is what a failed open leaves when the wal index cannot be
// sized, and SQLite itself then reads the main file alone.
@(private)
image_blocked :: proc(path: string, headerless_wal_ok: bool) -> bool {
	if !headerless_wal_ok {
		return !sidecar_free(path)
	}
	if sidecar_bytes(path, "-journal") > 0 {
		return true
	}
	return sidecar_bytes(path, "-wal") >= 32
}

// sidecar_bytes fails closed: an unreadable sidecar is treated as live.
@(private)
sidecar_bytes :: proc(path, suffix: string) -> i64 {
	full := strings.concatenate({path, suffix}, context.temp_allocator)
	size, missing, known := file_size(full)
	if missing {
		return 0
	}
	if !known {
		return max(i64)
	}
	return size
}

// file_moved asks SQLITE_FCNTL_HAS_MOVED (20). The Windows VFS does not
// implement it and returns SQLITE_NOTFOUND, leaving the output untouched.
// SQLite assumes the file stayed put in that case. Any other failure is
// treated as a move, so a VFS that tried and could not say still refuses.
@(private)
file_moved :: proc(db: sqlite3.Db) -> bool {
	moved: c.int
	rc := sqlite3.sqlite3_file_control(db.handle, "main", 20, &moved)
	if rc == c.int(sqlite3.Code.Not_Found) {
		return false
	}
	if rc != 0 {
		return true
	}
	return moved != 0
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
