#+build linux
package leita_files

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// fixture is a private directory under the temp dir, named with the process id.
@(private = "file")
fixture :: proc(t: ^testing.T, name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	root := strings.concatenate(
		{base, fmt.tprintf("/leita_files_%s_%d", name, os.get_pid())},
		context.temp_allocator,
	)
	os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	return root
}

@(private = "file")
join_path :: proc(dir, name: string) -> string {
	return strings.concatenate({dir, name}, context.temp_allocator)
}

@(private = "file")
write_file :: proc(path, text: string) -> bool {
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

/*
A directory swapped for a symlink must not redirect a delete onto the link's
target. via points at decoy, so the path reads as via/tree while the directory
that would be emptied is decoy/tree.
*/
@(test)
a_delete_refuses_a_symlink_ancestor :: proc(t: ^testing.T) {
	root := fixture(t, "symlink_delete")
	defer os.remove_all(root)
	real := join_path(root, "/real/tree")
	decoy := join_path(root, "/decoy/tree")
	testing.expect(t, os.make_directory_all(real) == nil)
	testing.expect(t, os.make_directory_all(decoy) == nil)
	testing.expect(t, write_file(join_path(real, "/secret"), "real"))
	testing.expect(t, write_file(join_path(decoy, "/keep"), "decoy"))
	testing.expect(t, os.symlink(join_path(root, "/decoy"), join_path(root, "/via")) == nil)

	_, _, err := delete_tree(join_path(root, "/via/tree"))
	testing.expect_value(t, err, Error.Not_Directory)
	testing.expect(t, os.exists(join_path(decoy, "/keep")), "the substituted tree is untouched")
	testing.expect(t, os.exists(join_path(real, "/secret")), "the other tree is untouched")

	failed, _, err2 := delete_tree(real)
	testing.expect_value(t, err2, Error.None)
	testing.expect_value(t, failed, 0)
	testing.expect(
		t,
		!os.exists(join_path(real, "/secret")),
		"a real directory chain still deletes",
	)
}

// Same substitution for a rename: the decoy's file must stay under its own name.
@(test)
a_rename_refuses_a_symlink_ancestor :: proc(t: ^testing.T) {
	root := fixture(t, "symlink_rename")
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(join_path(root, "/real")) == nil)
	testing.expect(t, os.make_directory_all(join_path(root, "/decoy")) == nil)
	testing.expect(t, write_file(join_path(root, "/real/item"), "real"))
	testing.expect(t, write_file(join_path(root, "/decoy/item"), "decoy"))
	testing.expect(t, os.symlink(join_path(root, "/decoy"), join_path(root, "/via")) == nil)

	_, err := rename(join_path(root, "/via/item"), "item-new", context.temp_allocator)
	testing.expect_value(t, err, Error.Not_Directory)
	testing.expect(t, os.exists(join_path(root, "/decoy/item")), "the decoy was not renamed")
	testing.expect(t, !os.exists(join_path(root, "/decoy/item-new")))
	testing.expect(t, os.exists(join_path(root, "/real/item")))

	to, err2 := rename(join_path(root, "/real/item"), "item-new", context.temp_allocator)
	testing.expect_value(t, err2, Error.None)
	testing.expect_value(t, to, join_path(root, "/real/item-new"))
	testing.expect(t, os.exists(to))
}

/*
A relative source has no directory in the string. The old join treated that as
the root and asked to rename the file to /<name>. child_path is what rename joins
with, and a file in the working directory is renamed there, not into the root.
Running as root is skipped: the old join would try to create /<name>.
*/
@(test)
a_relative_rename_stays_in_the_working_directory :: proc(t: ^testing.T) {
	root := fixture(t, "relative_rename")
	defer os.remove_all(root)
	testing.expect_value(t, child_path("", "item-new", context.temp_allocator), "item-new")
	testing.expect_value(t, child_path(".", "item-new", context.temp_allocator), "item-new")
	testing.expect_value(
		t,
		child_path(root, "item-new", context.temp_allocator),
		join_path(root, "/item-new"),
	)
	testing.expect_value(t, child_path("/", "item-new", context.temp_allocator), "/item-new")

	testing.expect(t, write_file(join_path(root, "/item"), "x"))
	to, err := rename(join_path(root, "/item"), "item-new", context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, to, join_path(root, "/item-new"))
	testing.expect(t, !os.exists("/item-new"))

	if posix.geteuid() == 0 {
		return
	}
	wd, werr := os.get_working_directory(context.temp_allocator)
	testing.expect(t, werr == nil)
	name := fmt.tprintf("leita-relative-636-%d", os.get_pid())
	renamed := fmt.tprintf("%s-new", name)
	full :=
		name if strings.has_suffix(wd, "/") else strings.concatenate({wd, "/", name}, context.temp_allocator)
	landed :=
		renamed if strings.has_suffix(wd, "/") else strings.concatenate({wd, "/", renamed}, context.temp_allocator)
	root_dest := strings.concatenate({"/", renamed}, context.temp_allocator)
	testing.expect(t, !os.exists(root_dest))
	defer os.remove(full)
	defer os.remove(landed)
	defer if os.exists(root_dest) {
		os.remove(root_dest)
	}
	testing.expect(t, write_file(full, "x"))
	rel, rerr := rename(name, renamed, context.temp_allocator)
	testing.expect_value(t, rerr, Error.None)
	testing.expect_value(t, rel, renamed)
	testing.expect(t, os.exists(landed), "the relative rename stayed in the working directory")
	testing.expect(t, !os.exists(root_dest), "nothing was renamed into the root")
}

// An unsearchable directory is still emptied, and the chmod that opens it does
// not follow a symlink standing in for that directory.
@(test)
a_chmod_of_an_unsearchable_directory_does_not_follow_a_link :: proc(t: ^testing.T) {
	root := fixture(t, "chmod_nofollow")
	defer os.remove_all(root)
	locked := join_path(root, "/tree/locked")
	testing.expect(t, os.make_directory_all(locked) == nil)
	testing.expect(t, write_file(join_path(locked, "/f"), "x"))
	testing.expect(t, os.change_mode(locked, {}) == nil)

	failed, _, err := delete_tree(join_path(root, "/tree"))
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, failed, 0)
	testing.expect(t, !os.exists(locked), "the unsearchable directory was deleted")

	victim := join_path(root, "/victim")
	testing.expect(t, os.make_directory(victim) == nil)
	testing.expect(t, write_file(join_path(victim, "/secret"), "s"))
	kept := os.Permissions{.Read_User, .Write_User, .Execute_User}
	testing.expect(t, os.change_mode(victim, kept) == nil)
	holder := join_path(root, "/holder")
	testing.expect(t, os.make_directory(holder) == nil)
	testing.expect(t, os.symlink(victim, join_path(holder, "/link")) == nil)
	dir := posix.open(
		strings.clone_to_cstring(holder, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	testing.expect(t, dir != -1)
	defer posix.close(dir)
	followed := fchmod_nofollow(
		dir,
		strings.clone_to_cstring("link", context.temp_allocator),
		posix.S_IRWXU + posix.S_IRWXG + posix.S_IRWXO,
	)
	testing.expect(t, !followed, "a symlink is not chmod'd")
	info, serr := os.stat(victim, context.temp_allocator)
	testing.expect(t, serr == nil)
	testing.expect_value(t, info.mode & os.Permissions_All, kept)
}

/*
Trash resolves both the source and its own files directory without following a
symlink. XDG_DATA_HOME points the test at the fixture, never the home Trash.
*/
@(test)
a_trash_refuses_a_symlink_ancestor_and_a_linked_files_directory :: proc(t: ^testing.T) {
	root := fixture(t, "symlink_trash")
	defer os.remove_all(root)
	data := join_path(root, "/data")
	testing.expect(t, os.make_directory_all(join_path(root, "/real")) == nil)
	testing.expect(t, os.make_directory_all(join_path(root, "/decoy")) == nil)
	testing.expect(t, os.make_directory_all(join_path(root, "/public")) == nil)
	testing.expect(t, write_file(join_path(root, "/real/note"), "real"))
	testing.expect(t, write_file(join_path(root, "/decoy/note"), "decoy"))
	testing.expect(t, os.symlink(join_path(root, "/decoy"), join_path(root, "/via")) == nil)

	prev := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	testing.expect(t, os.set_env("XDG_DATA_HOME", data) == nil)
	defer {
		if prev == "" {
			os.unset_env("XDG_DATA_HOME")
		} else {
			os.set_env("XDG_DATA_HOME", prev)
		}
	}

	err := trash(join_path(root, "/via/note"))
	testing.expect_value(t, err, Error.Not_Directory)
	testing.expect(t, os.exists(join_path(root, "/decoy/note")), "the decoy was not trashed")
	testing.expect(t, !os.exists(join_path(data, "/Trash/files/note")))

	err = trash(join_path(root, "/real/note"))
	testing.expect_value(t, err, Error.None)
	testing.expect(t, !os.exists(join_path(root, "/real/note")))
	testing.expect(
		t,
		os.exists(join_path(data, "/Trash/files/note")),
		"a real path still reaches the Trash",
	)
	testing.expect(t, os.exists(join_path(data, "/Trash/info/note.trashinfo")))

	// The files directory itself is now a link to somewhere else on this disk.
	testing.expect(t, os.remove_all(join_path(data, "/Trash/files")) == nil)
	testing.expect(
		t,
		os.symlink(join_path(root, "/public"), join_path(data, "/Trash/files")) == nil,
	)
	testing.expect(t, write_file(join_path(root, "/real/second"), "second"))
	err = trash(join_path(root, "/real/second"))
	testing.expect_value(t, err, Error.Not_Directory)
	testing.expect(t, os.exists(join_path(root, "/real/second")), "the file stayed put")
	entries, _ := os.read_all_directory_by_path(join_path(root, "/public"), context.temp_allocator)
	testing.expect_value(t, len(entries), 0)
}
