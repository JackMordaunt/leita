#+build linux, darwin
package schema

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// Use a pipe gate, not a timing window: the separate SQLite process holds
// its live WAL transaction until the snapshot has refused it.
@(test)
an_external_wal_writer_is_not_copied :: proc(t: ^testing.T) {
	if !testing.expect(
		t,
		os.exists("/usr/bin/python3"),
		"external SQLite interop requires system Python3",
	) {return}
	path, dir := image_fixture(t)
	defer os.remove_all(dir)
	code :: `import sqlite3,sys
s=sqlite3.connect(sys.argv[1])
s.execute('BEGIN IMMEDIATE')
s.execute('INSERT INTO note VALUES(99)')
sys.stdout.buffer.write(b'R');sys.stdout.buffer.flush()
sys.stdin.buffer.read(1)
s.commit();s.close()
`
	argv := [5]cstring {
		"/usr/bin/python3",
		"-c",
		strings.clone_to_cstring(code, context.temp_allocator),
		strings.clone_to_cstring(path, context.temp_allocator),
		nil,
	}
	ready, gate: [2]posix.FD
	testing.expect_value(t, posix.pipe(&ready), posix.result.OK)
	testing.expect_value(t, posix.pipe(&gate), posix.result.OK)
	child := posix.fork()
	if child == 0 {
		// Only async-signal-safe calls between fork and exec.
		posix.close(ready[0]); posix.close(gate[1])
		posix.dup2(ready[1], 1); posix.dup2(gate[0], 0)
		posix.close(ready[1]); posix.close(gate[0])
		posix.execv(argv[0], raw_data(argv[:]))
		posix._exit(127)
	}
	posix.close(ready[1]); posix.close(gate[0])
	defer posix.close(ready[0])
	defer posix.close(gate[1])
	if !testing.expect(t, child > 0) {return}
	defer {
		byte: u8 = 1
		_ = posix.write(gate[1], &byte, 1)
		status: c.int
		testing.expect_value(t, posix.waitpid(child, &status, {}), child)
		testing.expect_value(t, status, 0)
	}
	byte: u8
	if !testing.expect_value(t, posix.read(ready[0], &byte, 1), 1) {return}
	testing.expect_value(t, byte, u8('R'))
	db, err := memory_image(path)
	testing.expect(t, err != nil)
	testing.expect(t, db.handle == nil)
	if err != nil {delete(err.?.text)}
}

@(test)
an_oversized_image_is_refused_before_allocating_it :: proc(t: ^testing.T) {
	path, dir := image_fixture(t)
	defer os.remove_all(dir)
	// Sparse growth exercises the byte budget without consuming that space.
	testing.expect_value(
		t,
		posix.truncate(
			strings.clone_to_cstring(path, context.temp_allocator),
			posix.off_t(MEMORY_IMAGE_LIMIT + 4096),
		),
		posix.result.OK,
	)
	db, err := memory_image(path)
	testing.expect(t, err != nil)
	testing.expect(t, db.handle == nil)
	if err !=
	   nil {testing.expect(t, strings.contains(err.?.text, "too large")); delete(err.?.text)}
}

@(test)
a_database_alias_cannot_hide_a_sidecar :: proc(t: ^testing.T) {
	path, dir := image_fixture(t)
	defer os.remove_all(dir)
	alias := strings.concatenate({dir, "/alias.db"}, context.temp_allocator)
	testing.expect_value(t, posix.symlink(strings.clone_to_cstring(path, context.temp_allocator), strings.clone_to_cstring(alias, context.temp_allocator)), posix.result.OK)
	testing.expect(t, os.write_entire_file(strings.concatenate({path, "-wal"}, context.temp_allocator), nil) == nil)
	db, err := memory_image(alias)
	testing.expect(t, err != nil && db.handle == nil)
	if err != nil { delete(err.?.text) }
}
