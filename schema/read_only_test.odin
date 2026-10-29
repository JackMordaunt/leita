package schema

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import jm_path "jm:path"
import "jm:sqlite3"

@(private)
image_fixture :: proc(t: ^testing.T) -> (path, dir: string) {
	made, err := jm_path.make_directory_temp("", "leita-memory-image-*", context.temp_allocator)
	testing.expect(t, err == nil)
	dir = made
	path = fmt.tprintf("%s/store.db", dir)
	db, db_err := sqlite3.open(path)
	testing.expect(t, db_err == nil)
	testing.expect(
		t,
		sqlite3.exec(
			db,
			"PRAGMA journal_mode=WAL; CREATE TABLE note(value INTEGER); INSERT INTO note VALUES(42)",
		) ==
		nil,
	)
	sqlite3.close(&db)
	return
}

@(test)
a_checkpointed_image_is_readable_without_writing_its_source :: proc(t: ^testing.T) {
	path, dir := image_fixture(t)
	defer os.remove_all(dir)
	before, _ := os.read_entire_file(path, context.temp_allocator)
	db, err := memory_image(path)
	if !testing.expectf(t, err == nil, "memory image: %v", err) {return}
	defer sqlite3.close(&db)
	rows, qerr := sqlite3.query(db, "SELECT value FROM note", allocator = context.temp_allocator)
	testing.expect(t, qerr == nil)
	testing.expect(t, sqlite3.next(&rows))
	testing.expect_value(t, sqlite3.integer(rows, 0), i64(42))
	sqlite3.finish(&rows)
	fault := sqlite3.exec(db, "INSERT INTO note VALUES(99)")
	testing.expect(t, fault != nil)
	if fault !=
	   nil {testing.expect_value(t, fault.?.code, sqlite3.Code.Read_Only); delete(fault.?.text)}
	after, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, slice.equal(before, after))
	testing.expect(t, sidecar_free(path))
}

@(test)
a_same_process_wal_writer_is_not_copied_or_unlocked :: proc(t: ^testing.T) {
	path, dir := image_fixture(t)
	defer os.remove_all(dir)
	writer, err := sqlite3.open(path)
	testing.expect(t, err == nil)
	defer sqlite3.close(&writer)
	testing.expect(t, sqlite3.exec(writer, "BEGIN IMMEDIATE; INSERT INTO note VALUES(99)") == nil)
	copy, copy_err := memory_image(path)
	testing.expect(t, copy_err != nil)
	testing.expect(t, copy.handle == nil)
	if copy_err != nil {delete(copy_err.?.text)}
	// The failed snapshot did not drop or invalidate the writer's locks.
	testing.expect(t, sqlite3.exec(writer, "COMMIT") == nil)
	rows, qerr := sqlite3.query(
		writer,
		"SELECT sum(value) FROM note",
		allocator = context.temp_allocator,
	)
	testing.expect(t, qerr == nil)
	testing.expect(t, sqlite3.next(&rows))
	testing.expect_value(t, sqlite3.integer(rows, 0), i64(141))
	sqlite3.finish(&rows)
}

@(test)
a_sidecar_blocks_an_image_even_if_it_is_empty :: proc(t: ^testing.T) {
	path, dir := image_fixture(t)
	defer os.remove_all(dir)
	for suffix in ([]string{"-wal", "-shm", "-journal"}) {
		side := fmt.tprintf("%s%s", path, suffix)
		testing.expect(t, os.write_entire_file(side, nil) == nil)
		db, err := memory_image(path)
		testing.expect(t, err != nil)
		testing.expect(t, db.handle == nil)
		if err != nil {delete(err.?.text)}
		testing.expect(t, os.remove(side) == nil)
	}
}
