#+build linux
package leita_files

import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:testing"

/*
A delete never goes through a mount. Inside the tree, a tmpfs stands for another
disk mounted there, and a bind of a folder outside for one of the same filesystem,
which keeps the device and is told apart only by its mount: both are counted as
left, with what is on them untouched, and the folder holding the bind has its mode
back. A tree that is itself a mount point is refused whole.

Mounting needs root or a user namespace of its own: `just mount-test` runs this
in one. Anywhere else it is skipped, unless LEITA_MOUNT_TEST says it must run.
*/
@(test)
a_delete_never_crosses_a_mount :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	root := strings.concatenate({base, "/leita_files_mounts"}, context.temp_allocator)
	at :: proc(dir, name: string) -> string {
		return strings.concatenate({dir, name}, context.temp_allocator)
	}
	tree, outside, other := at(root, "/tree"), at(root, "/outside"), at(root, "/other")
	os.remove_all(root)
	defer os.remove_all(root)
	for dir in ([]string{at(tree, "/disk"), at(tree, "/held/bind"), outside, other}) {
		testing.expect(t, os.make_directory_all(dir) == nil)
	}
	write :: proc(path: string) -> bool {
		return os.write_entire_file(path, make([]byte, 4096, context.temp_allocator)) == nil
	}
	testing.expect(t, write(at(tree, "/a")))
	testing.expect(t, write(at(outside, "/keep")))

	if err := mount_at("tmpfs", at(tree, "/disk"), "tmpfs", {}); err != .NONE {
		if os.get_env("LEITA_MOUNT_TEST", context.temp_allocator) != "" {
			testing.fail_now(t, "LEITA_MOUNT_TEST is set, but a tmpfs would not mount")
		}
		log.warnf("skipped: cannot mount here (%v); just mount-test runs this", err)
		return
	}
	defer unmount(at(tree, "/disk"))
	testing.expect(t, mount_at(outside, at(tree, "/held/bind"), "", {.BIND}) == .NONE)
	defer unmount(at(tree, "/held/bind"))
	testing.expect(t, mount_at("tmpfs", other, "tmpfs", {}) == .NONE)
	defer unmount(other)
	testing.expect(t, write(at(tree, "/disk/on_disk")))
	testing.expect(t, write(at(other, "/x")))
	read_only := os.Permissions{.Read_User, .Execute_User}
	testing.expect(t, os.change_mode(at(tree, "/held"), read_only) == nil)
	defer os.change_mode(at(tree, "/held"), os.Permissions_Default_Directory)

	// The bind keeps the device, so the mount table names it as well as its mount id.
	bind, _ := look_at(at(tree, "/held/bind"))
	testing.expect(
		t,
		[2]u64{bind.device, bind.inode} in mount_points(tree),
		"the table has the bind",
	)
	file, _ := look_at(at(tree, "/a"))
	want := held_alone(file)

	failed, freed, err := delete_tree(tree)
	testing.expect_value(t, err, Error.Partly)
	testing.expect_value(t, failed, 2)
	testing.expect_value(t, freed, want)
	testing.expect(t, !os.exists(at(tree, "/a")), "what is the tree's own went")
	testing.expect(t, os.exists(at(tree, "/disk/on_disk")), "the other disk is untouched")
	testing.expect(t, os.exists(at(tree, "/held/bind/keep")), "so is the bind")
	testing.expect(t, os.exists(at(outside, "/keep")), "and what it binds")
	info, _ := os.stat_do_not_follow_links(at(tree, "/held"), context.temp_allocator)
	testing.expect_value(t, info.mode & os.Permissions_All, read_only)

	failed, freed, err = delete_tree(other)
	testing.expect_value(t, err, Error.Mount_Point)
	testing.expect_value(t, failed, 0)
	testing.expect(t, os.exists(at(other, "/x")), "a mounted tree is refused whole")
}

@(private = "file")
mount_at :: proc(source, target, fstype: string, flags: linux.Mount_Flags) -> linux.Errno {
	c :: proc(s: string) -> cstring {return strings.clone_to_cstring(s, context.temp_allocator)}
	return linux.mount(c(source), c(target), c(fstype) if fstype != "" else nil, flags, nil)
}

@(private = "file")
unmount :: proc(target: string) {
	linux.umount2(strings.clone_to_cstring(target, context.temp_allocator), {.MNT_DETACH})
}

// look_at is what look says of the entry at path, asked through its folder.
@(private = "file")
look_at :: proc(path: string) -> (Look, posix.Errno) {
	dir, _ := open_dir_at(posix.AT_FDCWD, strings.clone_to_cstring(os.dir(path), context.temp_allocator), true)
	defer posix.close(dir)
	return look(dir, strings.clone_to_cstring(os.base(path), context.temp_allocator))
}
