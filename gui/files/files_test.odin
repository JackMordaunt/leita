package leita_files

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
	root := strings.concatenate(
		{base, fmt.tprintf("/leita_files_delete_%d", os.get_pid())},
		context.temp_allocator,
	)
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
		symlink_directory(
			outside,
			strings.concatenate({root, "/tree/link"}, context.temp_allocator),
		),
	)
	testing.expect(
		t,
		symlink_directory(
			strings.concatenate({root, "/tree"}, context.temp_allocator),
			strings.concatenate({root, "/alias"}, context.temp_allocator),
		),
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
	_, _, refused := delete_tree(strings.concatenate({root, "/alias"}, context.temp_allocator))
	testing.expect_value(t, refused, Error.Not_Directory)
	testing.expect(
		t,
		os.exists(strings.concatenate({root, "/tree/locked/deep/f"}, context.temp_allocator)),
	)

	failed, _, err := delete_tree(strings.concatenate({root, "/tree"}, context.temp_allocator))
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
	dir := strings.concatenate(
		{tmp, fmt.tprintf("/leita_files_create_new_%d", os.get_pid())},
		context.temp_allocator,
	)
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
			fmt.tprintf("leita-report-%s-%s", c[1], minute),
		)
	}
}

// A path that is still there is a refusal whatever code the call returned, and
// nothing was deleted.
@(test)
a_path_still_there_is_never_a_success :: proc(t: ^testing.T) {
	testing.expect_value(t, trash_outcome(0, false, true), Error.None)
	testing.expect_value(t, trash_outcome(0, false, false), Error.Not_Recycled)
	testing.expect_value(t, trash_outcome(0, true, false), Error.Not_Recycled)
	testing.expect_value(t, trash_outcome(0x78, false, false), Error.Not_Recycled)
	testing.expect_value(t, trash_outcome(0x78, true, false), Error.Not_Recycled)
}

// A failure with the path gone says nothing about the bin, so it does not claim
// the file was kept.
@(test)
a_failure_with_the_path_gone_is_not_called_a_refusal :: proc(t: ^testing.T) {
	testing.expect_value(t, trash_outcome(0x78, false, true), Error.Other)
	testing.expect_value(t, trash_outcome(0, true, true), Error.Other)
}

@(test)
a_refusal_says_nothing_was_deleted :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(describe(.Not_Recycled), "nothing was deleted"))
}

// is_device_name matches the reserved names in any case and with any text after
// the first dot.
@(test)
windows_refuses_device_names :: proc(t: ^testing.T) {
	names := []string {
		"CON", "PRN", "AUX", "NUL", "COM1", "COM9", "LPT1", "LPT9", "con", "Nul", "cOm3",
		"lpt5", "CON.txt", "nul.tar.gz", "aux.", "COM1.log", "CON .txt", "prn  ",
	}
	for name in names {
		testing.expectf(
			t,
			windows_name_fault(name) != .None,
			"%q is a device or ends in a dot or space",
			name,
		)
	}
	for name in ([]string{"CON", "PRN", "AUX", "NUL", "COM1", "LPT9", "con.txt", "Nul"}) {
		testing.expect_value(t, windows_name_fault(name), Name_Fault.Device)
	}
}

// A name ending in a space or dot is refused, which Microsoft's naming page
// tells programs not to make.
@(test)
windows_refuses_a_trailing_space_or_dot :: proc(t: ^testing.T) {
	for name in ([]string{"notes.", "notes ", "notes. ", "a.b.", "README  ", "x. ."}) {
		testing.expect_value(t, windows_name_fault(name), Name_Fault.Trailing)
	}
}

// Names that only look like the reserved ones are fine, and so is the rest.
@(test)
windows_keeps_names_that_are_not_devices :: proc(t: ^testing.T) {
	names := []string {
		"readme.txt", "CONSOLE", "COM", "COM0", "COM10", "LPT", "LPT0", "AUXILIARY.txt",
		"my.CON", "a.nul", ".gitignore", "con-1", "NULL", "notes",
	}
	for name in names {
		testing.expect_value(t, windows_name_fault(name), Name_Fault.None)
	}
	testing.expect_value(t, windows_name_fault(`a:b`), Name_Fault.Reserved)
	testing.expect_value(t, windows_name_fault(`CON|`), Name_Fault.Reserved)
}

// name_fault applies the rules that hold everywhere and, on Windows, these.
@(test)
name_fault_refuses_what_no_system_keeps :: proc(t: ^testing.T) {
	testing.expect_value(t, name_fault(""), Name_Fault.Empty)
	testing.expect_value(t, name_fault(".."), Name_Fault.Dot)
	testing.expect_value(t, name_fault("a/b"), Name_Fault.Slash)
	testing.expect_value(t, name_fault("report.pdf"), Name_Fault.None)
	when ODIN_OS == .Windows {
		testing.expect_value(t, name_fault("CON"), Name_Fault.Device)
		testing.expect_value(t, name_fault("notes."), Name_Fault.Trailing)
	} else {
		// elsewhere both are ordinary names
		testing.expect_value(t, name_fault("CON"), Name_Fault.None)
		testing.expect_value(t, name_fault("notes."), Name_Fault.None)
	}
}
