#+build linux, darwin, freebsd, openbsd, netbsd
package leita_monitor

import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"

import jm_path "jm:path"

// CLOEXEC releases a forked child's copy only once exec runs. A pipe keeps
// the child in that interval, so this tests ownership rather than how fast
// the scheduler happens to run exec on a busy machine.
@(test)
a_finished_run_releases_its_lock_before_a_forked_child_execs :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp("", "leita-lock-fork-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/%s", dir, LOCK_FILE)
	l, result := lock(path)
	if !testing.expect_value(t, result, Lock_Result.Taken) {
		return
	}
	defer unlock(&l)

	gate: [2]posix.FD
	if !testing.expect_value(t, posix.pipe(&gate), posix.result.OK) {
		return
	}
	child := posix.fork()
	if child == 0 {
		// After fork in a multithreaded test process, use only async-signal-
		// safe libc calls. Do not allocate, log, assert, or run Odin defers.
		posix.close(gate[1])
		byte: u8
		for posix.read(gate[0], &byte, 1) < 0 {
			if posix.errno() != .EINTR {
				posix._exit(1)
			}
		}
		posix._exit(0)
	}
	posix.close(gate[0])
	defer posix.close(gate[1])
	if !testing.expect(t, child > 0) {
		return
	}
	defer {
		byte: u8 = 1
		_ = posix.write(gate[1], &byte, 1)
		status: c.int
		testing.expect_value(t, posix.waitpid(child, &status, {}), child)
		testing.expect_value(t, status, 0)
	}

	// The child still holds the inherited open-file description. Releasing
	// this run must make the file available without waiting for that child.
	unlock(&l)
	l, result = lock(path)
	testing.expect_value(t, result, Lock_Result.Taken)
}
