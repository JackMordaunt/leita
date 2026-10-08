package sonar_files

import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"

import "jm:debug"

// received is what the job saw, copied out: the job frees its path once it returns.
@(private = "file")
received: struct {
	buf:  [64]u8,
	len:  int,
	done: sync.Sema,
}

@(private = "file")
record :: proc(path: string) {
	received.len = copy(received.buf[:], path)
	sync.sema_post(&received.done)
}

// The background thread frees its copy of the path through the allocator that
// made it. Under jm's debug allocator, as the window runs in a debug build, a
// pointer is not where the system heap put its block, so a thread that frees
// through the heap instead aborts with "free(): invalid pointer", as Locate did in c4d8b1e.
@(test)
a_background_job_frees_its_path_with_the_callers_allocator :: proc(t: ^testing.T) {
	da: debug.Allocator
	debug.init(&da, context.allocator)
	defer debug.destroy(&da)
	context.allocator = debug.allocator(&da)

	before := debug.snapshot(&da)
	th := run_in_background("/somewhere/photos", record, detach = false)
	testing.expect(t, th != nil, "the thread started")
	if th == nil {
		return
	}
	sync.sema_wait(&received.done)
	testing.expect_value(t, string(received.buf[:received.len]), "/somewhere/photos")
	thread.join(th)
	thread.destroy(th)

	// The job's copy of the path and the job itself went back to the allocator
	// that made them, each once.
	testing.expect(t, debug.expect_released(&da, before), "the job freed what it was given")
	testing.expect_value(t, debug.issue_count(&da), 0)
}

@(test)
the_space_of_a_mounted_directory_is_its_filesystems :: proc(t: ^testing.T) {
	dir, err := os.temp_directory(context.temp_allocator)
	testing.expect(t, err == nil)
	total, free, ok := space(dir)
	testing.expect(t, ok, "the platform answered")
	testing.expect(t, total > 0, "a filesystem has a size")
	testing.expect(t, free <= total, "no more is free than there is")

	_, _, missing := space("/nonexistent/sonar")
	testing.expect(t, !missing, "a path that is not there has no filesystem")
}
