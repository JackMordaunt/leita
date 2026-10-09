package estoile_files

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "jm:debug"
import "jm:timefmt"

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

// A new file never takes the name of one there: the second is -2, the third -3,
// and the first is left as it was.
@(test)
a_new_file_never_replaces_one :: proc(t: ^testing.T) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir := strings.concatenate({tmp, "/estoile_files_create_new"}, context.temp_allocator)
	os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	defer os.remove_all(dir)

	names: [3]string
	for &name, i in names {
		path, f, err := create_new(dir, "report", ".pdf", context.temp_allocator)
		testing.expect_value(t, err, Error.None)
		if f != nil {
			_, _ = os.write_string(f, "first" if i == 0 else "later")
			os.close(f)
		}
		name = path[len(dir) + 1:]
	}
	testing.expect_value(t, names, [3]string{"report.pdf", "report-2.pdf", "report-3.pdf"})
	first := strings.concatenate({dir, "/report.pdf"}, context.temp_allocator)
	data, _ := os.read_entire_file(first, context.temp_allocator)
	testing.expect_value(t, string(data), "first")

	missing := strings.concatenate({dir, "/missing"}, context.temp_allocator)
	_, _, err := create_new(missing, "report", ".pdf", context.temp_allocator)
	testing.expect_value(t, err, Error.Missing)
}

// A report is named for its target's last name, kept to letters, digits and
// a few marks, and the minute.
@(test)
a_report_is_named_for_its_target :: proc(t: ^testing.T) {
	now := time.unix(1791547200, 0)
	minute := timefmt.local(now, "%Y-%m-%d-%H%M", context.temp_allocator)
	cases := [][2]string {
		{"/home/jfm/Source", "Source"},
		{"/home/jfm/My Stuff: 2026?/", "My-Stuff-2026"},
		{"/", "root"},
		{`C:\`, "C"},
		{"/data/日本語", "日本語"},
	}
	for c in cases {
		testing.expect_value(
			t,
			report_stem(c[0], now),
			fmt.tprintf("estoile-report-%s-%s", c[1], minute),
		)
	}
}
