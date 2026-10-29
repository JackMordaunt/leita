#+build linux, darwin, freebsd, openbsd, netbsd
package leita_history

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "jm:sqlite3"
import jm_path "jm:path"

@(private = "file")
Reserved_Probe :: enum { Failed, Taken, Held }

// Probe SQLite's RESERVED byte from another process. POSIX record locks
// are not inherited by fork. The child uses only async-signal-safe syscalls,
// never the inherited SQLite connection or any Odin allocator/runtime work.
@(private = "file")
reserved_from_another_process :: proc(t: ^testing.T, path: string) -> Reserved_Probe {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	child := posix.fork()
	if child == 0 {
		fd := posix.open(name, {.RDWR, .CLOEXEC})
		if fd < 0 { posix._exit(2) }
		range := posix.flock{l_start = 0x40000001, l_len = 1, l_type = .WRLCK, l_whence = 0}
		if posix.fcntl(fd, .SETLK, &range) == 0 {
			posix.close(fd)
			posix._exit(0)
		}
		err := posix.errno()
		posix.close(fd)
		if err == .EACCES || err == .EAGAIN { posix._exit(1) }
		posix._exit(2)
	}
	if !testing.expect(t, child > 0, "could not fork the external lock probe") { return .Failed }
	status: c.int
	for {
		waited := posix.waitpid(child, &status, {})
		if waited == child { break }
		if waited < 0 && posix.errno() == .EINTR { continue }
		testing.expect(t, false, "could not wait for the external lock probe")
		return .Failed
	}
	if !testing.expect(t, posix.WIFEXITED(status), "external lock probe did not exit normally") { return .Failed }
	switch posix.WEXITSTATUS(status) {
	case 0: return .Taken
	case 1: return .Held
	case: return .Failed
	}
}

@(private = "file")
rollback_writer :: proc(t: ^testing.T) -> (writer: sqlite3.Db, path, dir: string) {
	made, err := jm_path.make_directory_temp("", "leita-history-posix-lock-*", context.temp_allocator)
	if !testing.expect(t, err == nil) { return }
	dir = made
	path = fmt.tprintf("%s/history.db", dir)
	st: Store
	if !testing.expect(t, open(&st, path) == nil) { return }
	close(&st)
	db_error: sqlite3.Error
	writer, db_error = sqlite3.open(path)
	if !testing.expect(t, db_error == nil) { return }
	// Rollback-mode writers own a lock on the database inode itself,
	// unlike WAL write locks on the separate shared-memory file.
	testing.expect(t, sqlite3.exec(writer, "PRAGMA journal_mode=DELETE; BEGIN IMMEDIATE") == nil)
	return
}

@(test)
a_public_history_open_keeps_an_existing_writers_kernel_lock :: proc(t: ^testing.T) {
	writer, path, dir := rollback_writer(t)
	defer os.remove_all(dir)
	defer sqlite3.close(&writer)
	if writer.handle == nil { return }
	testing.expect_value(t, reserved_from_another_process(t, path), Reserved_Probe.Held)
	st: Store
	problem := open(&st, path)
	if problem == nil { close(&st) }
	testing.expect(t, problem != nil, "a second writer must not open while the first holds its transaction")
	if problem != nil { delete(problem.?.text) }
	// This is the essential assertion: a successful COMMIT alone does not
	// show whether a raw preflight close silently released the OS lock.
	testing.expect_value(t, reserved_from_another_process(t, path), Reserved_Probe.Held)
	testing.expect(t, sqlite3.exec(writer, "ROLLBACK") == nil)
	testing.expect_value(t, reserved_from_another_process(t, path), Reserved_Probe.Taken)
}

// Control for the regression above: the historical raw preflight close
// really does lose a live connection's lock, on a disposable database only.
@(test)
a_raw_database_fd_close_drops_a_same_process_sqlite_lock :: proc(t: ^testing.T) {
	writer, path, dir := rollback_writer(t)
	defer os.remove_all(dir)
	defer sqlite3.close(&writer)
	if writer.handle == nil { return }
	testing.expect_value(t, reserved_from_another_process(t, path), Reserved_Probe.Held)
	file, err := os.open(path)
	if !testing.expect(t, err == nil) { return }
	os.close(file)
	testing.expect_value(t, reserved_from_another_process(t, path), Reserved_Probe.Taken)
	testing.expect(t, sqlite3.exec(writer, "ROLLBACK") == nil)
}
