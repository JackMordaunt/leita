#+build linux
package kstat

import "core:fmt"
import "core:io"
import "core:os"
import "core:testing"

@(private = "file")
scratch :: proc(t: ^testing.T, name: string) -> (dir: string, ok: bool) {
	base, base_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, base_err == nil, "no temp directory")
	dir = fmt.tprintf("%s/leita_kstat_%s_%d", base, name, os.get_pid())
	os.remove_all(dir)
	if os.make_directory(dir) != nil {
		testing.expect(t, false, "could not make the directory")
		return "", false
	}
	return dir, true
}

// stat and lstat answer as os.stat and os.lstat do for a file, a directory and a
// link, without asking statx.
@(test)
test_stat_answers_as_os_stat_does :: proc(t: ^testing.T) {
	dir, ok := scratch(t, "stat")
	if !ok {
		return
	}
	defer os.remove_all(dir)
	file := fmt.tprintf("%s/f", dir)
	link := fmt.tprintf("%s/l", dir)
	testing.expect(t, os.write_entire_file(file, []byte{'a', 'b', 'c'}) == nil, "could not write the file")
	testing.expect(t, os.symlink(file, link) == nil, "could not make the link")

	for path in ([]string{file, dir, link}) {
		want, want_err := os.stat(path, context.temp_allocator)
		got, got_err := stat(path, context.temp_allocator)
		testing.expect_value(t, got_err, os.Error(nil))
		if want_err != nil {
			// A kernel without statx (before Linux 4.11): os.stat is what this package
			// replaces, so there is nothing to compare with and the literals below carry it.
			continue
		}
		testing.expect_value(t, got.type, want.type)
		testing.expect_value(t, got.size, want.size)
		testing.expect_value(t, got.mode, want.mode)
		testing.expect_value(t, got.inode, want.inode)
		testing.expect_value(t, got.device, want.device)
		testing.expect_value(t, got.fullpath, want.fullpath)
		testing.expect_value(t, got.name, want.name)
		testing.expect_value(t, got.modification_time, want.modification_time)
	}
	for path in ([]string{file, link}) {
		want, want_err := os.lstat(path, context.temp_allocator)
		got, got_err := lstat(path, context.temp_allocator)
		testing.expect_value(t, got_err, os.Error(nil))
		if want_err != nil {
			continue
		}
		testing.expect_value(t, got.type, want.type)
		testing.expect_value(t, got.fullpath, want.fullpath)
	}
	link_info, _ := lstat(link, context.temp_allocator)
	testing.expect_value(t, link_info.type, os.File_Type.Symlink)
	followed, _ := stat(link, context.temp_allocator)
	testing.expect_value(t, followed.type, os.File_Type.Regular)
	testing.expect_value(t, followed.size, i64(3))
}

@(test)
test_stat_says_what_is_wrong_with_a_name :: proc(t: ^testing.T) {
	dir, ok := scratch(t, "errors")
	if !ok {
		return
	}
	defer os.remove_all(dir)
	_, err := stat(fmt.tprintf("%s/absent", dir), context.temp_allocator)
	testing.expect_value(t, err, os.Error(os.General_Error.Not_Exist))
	testing.expect(t, !is_file(dir) && is_dir(dir), "a directory is not a file")
	testing.expect(t, !is_file(fmt.tprintf("%s/absent", dir)), "a missing name was a file")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/f", dir), []byte{'x'}) == nil, "could not write")
	testing.expect(t, is_file(fmt.tprintf("%s/f", dir)) && !is_dir(fmt.tprintf("%s/f", dir)), "a file is not a directory")
	_, perm_err := stat("/proc/1/root/etc")
	testing.expect(t, perm_err == nil || perm_err == os.Error(io.Error.Permission_Denied), "an unexpected error")
}

@(test)
test_read_directory_lists_each_entry_as_lstat_does :: proc(t: ^testing.T) {
	dir, ok := scratch(t, "list")
	if !ok {
		return
	}
	defer os.remove_all(dir)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a", dir), []byte{'1'}) == nil, "could not write a")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/b", dir), []byte{'1', '2'}) == nil, "could not write b")
	testing.expect(t, os.make_directory(fmt.tprintf("%s/sub", dir)) == nil, "could not make sub")
	list, err := read_directory(dir, context.temp_allocator)
	testing.expect_value(t, err == nil, true)
	testing.expect_value(t, len(list), 3)
	seen: [3]bool
	for info in list {
		switch info.name {
		case "a":
			seen[0] = info.type == .Regular && info.size == 1
		case "b":
			seen[1] = info.type == .Regular && info.size == 2
		case "sub":
			seen[2] = info.type == .Directory
		}
		testing.expect_value(t, info.fullpath, fmt.tprintf("%s/%s", dir, info.name))
	}
	testing.expect_value(t, seen, [3]bool{true, true, true})
	_, absent := read_directory(fmt.tprintf("%s/absent", dir), context.temp_allocator)
	testing.expect_value(t, absent, os.Error(os.General_Error.Not_Exist))
}

// A bare program name is found on PATH without statx, and a name with a slash or
// one that is nowhere is left as it was.
@(test)
test_resolve_command_finds_a_program_on_path :: proc(t: ^testing.T) {
	found := resolve_command({"sh", "-c", "true"})
	testing.expect_value(t, len(found), 3)
	testing.expect(t, len(found[0]) > len("sh") && is_file(found[0]), "sh was not resolved to a file")
	testing.expect_value(t, found[1], "-c")
	kept := resolve_command({"/bin/sh"})
	testing.expect_value(t, kept[0], "/bin/sh")
	nowhere := resolve_command({"leita-no-such-program"})
	testing.expect_value(t, nowhere[0], "leita-no-such-program")
}
