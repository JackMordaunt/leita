package estoile_files

import "core:os"
import "core:strings"
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

	_, _, missing := space("/nonexistent/estoile")
	testing.expect(t, !missing, "a path that is not there has no filesystem")
}

// delete_tree takes a read-only tree, deletes a link inside as a link, leaving
// what it points at, and refuses a link given as the tree.
@(test)
delete_tree_is_careful_with_links_and_read_only_trees :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	root := strings.concatenate({base, "/estoile_files_delete"}, context.temp_allocator)
	outside := strings.concatenate({root, "-outside"}, context.temp_allocator)
	os.remove_all(root)
	os.remove_all(outside)
	defer os.remove_all(outside)

	testing.expect(
		t,
		os.make_directory_all(
			strings.concatenate({root, "/tree/locked/deep"}, context.temp_allocator),
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file(
			strings.concatenate({root, "/tree/locked/deep/f"}, context.temp_allocator),
			"x",
		) ==
		nil,
	)
	testing.expect(t, os.make_directory_all(outside) == nil)
	testing.expect(
		t,
		os.write_entire_file(
			strings.concatenate({outside, "/keep"}, context.temp_allocator),
			"x",
		) ==
		nil,
	)
	testing.expect(
		t,
		os.symlink(outside, strings.concatenate({root, "/tree/link"}, context.temp_allocator)) ==
		nil,
	)
	testing.expect(
		t,
		os.symlink(
			strings.concatenate({root, "/tree"}, context.temp_allocator),
			strings.concatenate({root, "/alias"}, context.temp_allocator),
		) ==
		nil,
	)
	// As Go leaves its module cache: no write permission anywhere.
	for dir in ([]string{"/tree/locked/deep", "/tree/locked"}) {
		testing.expect(
			t,
			os.change_mode(
				strings.concatenate({root, dir}, context.temp_allocator),
				{.Read_User, .Execute_User},
			) ==
			nil,
		)
	}

	// A link to the tree is refused, and the tree is untouched.
	_, refused := delete_tree(strings.concatenate({root, "/alias"}, context.temp_allocator))
	testing.expect_value(t, refused, Error.Not_Directory)
	testing.expect(
		t,
		os.exists(strings.concatenate({root, "/tree/locked/deep/f"}, context.temp_allocator)),
	)

	failed, err := delete_tree(strings.concatenate({root, "/tree"}, context.temp_allocator))
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, failed, 0)
	testing.expect(
		t,
		!os.exists(strings.concatenate({root, "/tree"}, context.temp_allocator)),
		"the tree is gone",
	)
	testing.expect(
		t,
		os.exists(strings.concatenate({outside, "/keep"}, context.temp_allocator)),
		"what the link pointed at is not",
	)
	os.remove(strings.concatenate({root, "/alias"}, context.temp_allocator))
	os.remove(root)
}
