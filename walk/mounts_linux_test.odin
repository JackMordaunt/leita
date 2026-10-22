#+build linux
package walk

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

import "../scan"

/*
A bind of a directory onto one below it is a mount, not read again: a walk of data
records data/sub/loop, a bind of data, as a mount, and so does a walk that starts
at data/sub, below what loop shows. A bind that shows a tree holding the walk's
start without being above it is entered, and stops at the start: view is a bind of
data/sub, and view/loop one of data, so a walk of view reads loop and stops at
loop/sub, which is view again.

Mounting needs root or a user namespace of its own: `just mount-test` runs this in
one. Anywhere else it is skipped, unless LEITA_MOUNT_TEST says it must run.
*/
@(test)
test_a_bind_of_an_ancestor_is_a_mount :: proc(t: ^testing.T) {
	base := bind_place(t, "ancestor")
	defer os.remove_all(base)
	at :: proc(base, name: string) -> string {
		return fmt.tprintf("%s/%s", base, name)
	}
	for dir in ([]string{"data/sub/loop", "view"}) {
		testing.expect(t, os.make_directory_all(at(base, dir)) == nil)
	}
	testing.expect(t, os.write_entire_file(at(base, "data/sub/f"), make([]byte, 4096, context.temp_allocator)) == nil)

	if !bind(t, at(base, "data"), at(base, "data/sub/loop")) {
		return
	}
	defer unmount(at(base, "data/sub/loop"))
	testing.expect(t, bind(t, at(base, "data/sub"), at(base, "view")))
	defer unmount(at(base, "view"))
	testing.expect(t, bind(t, at(base, "data"), at(base, "view/loop")))
	defer unmount(at(base, "view/loop"))

	for start in ([]string{"data", "data/sub"}) {
		tree := bind_walked(t, at(base, start))
		defer scan.tree_destroy(&tree)
		flags, _ := named_count(&tree, "loop")
		testing.expectf(t, .Mount in flags, "%s: loop is not a mount (%v)", start, flags)
		_, files := named_count(&tree, "f")
		testing.expectf(t, files == 1, "%s: f recorded %d times", start, files)
	}

	tree := bind_walked(t, at(base, "view"))
	defer scan.tree_destroy(&tree)
	loop, _ := named_count(&tree, "loop")
	testing.expectf(t, .Mount not_in loop, "view/loop shows data, not view: %v", loop)
	sub, _ := named_count(&tree, "sub")
	testing.expectf(t, .Mount in sub, "view/loop/sub is view again: %v", sub)
	_, files := named_count(&tree, "f")
	testing.expect_value(t, files, 1)
}

/*
A bind of a tree the walk reads anyway is a mount, so its files count once: var is
bound at mnt/var and mnt/again, and a walk of the base records both as mounts. A
walk of mnt alone does not reach var, so one of the two binds is walked, the one
mounted with the lower id, and the other is a mount.
*/
@(test)
//review:ignore skips-in-normal-conditions bind fails the test when LEITA_MOUNT_TEST is set; this assertion was verified with required real mounts, while unprivileged package runs may skip
test_a_bind_of_a_walked_tree_is_counted_once :: proc(t: ^testing.T) {
	base := bind_place(t, "sibling")
	defer os.remove_all(base)
	at :: proc(base, name: string) -> string {
		return fmt.tprintf("%s/%s", base, name)
	}
	for dir in ([]string{"var", "mnt/var", "mnt/again"}) {
		testing.expect(t, os.make_directory_all(at(base, dir)) == nil)
	}
	testing.expect(t, os.write_entire_file(at(base, "var/f"), make([]byte, 4096, context.temp_allocator)) == nil)

	if !bind(t, at(base, "var"), at(base, "mnt/var")) {
		return
	}
	defer unmount(at(base, "mnt/var"))
	testing.expect(t, bind(t, at(base, "var"), at(base, "mnt/again")))
	defer unmount(at(base, "mnt/again"))

	whole := bind_walked(t, base)
	defer scan.tree_destroy(&whole)
	_, files := named_count(&whole, "f")
	testing.expect_value(t, files, 1)
	mounts := 0
	for i in 0 ..< whole.count {
		if .Mount in scan.node_flags(scan.node(&whole, i)) {
			mounts += 1
		}
	}
	testing.expect_value(t, mounts, 2)

	alone := bind_walked(t, at(base, "mnt"))
	defer scan.tree_destroy(&alone)
	_, files = named_count(&alone, "f")
	testing.expect_value(t, files, 1)
	var, _ := named_count(&alone, "var")
	again, _ := named_count(&alone, "again")
	var_stat, again_stat: linux.Statx
	testing.expect_value(
		t,
		linux.statx(linux.AT_FDCWD, strings.clone_to_cstring(at(base, "mnt/var"), context.temp_allocator), {}, {.MNT_ID}, &var_stat),
		linux.Errno.NONE,
	)
	testing.expect_value(
		t,
		linux.statx(linux.AT_FDCWD, strings.clone_to_cstring(at(base, "mnt/again"), context.temp_allocator), {}, {.MNT_ID}, &again_stat),
		linux.Errno.NONE,
	)
	testing.expect(t, .MNT_ID in var_stat.mask && .MNT_ID in again_stat.mask)
	testing.expect(t, var_stat.mnt_id != again_stat.mnt_id)
	// Compare the actual mount ids; creation order is not the selection rule.
	testing.expect_value(t, .Mount in var, var_stat.mnt_id > again_stat.mnt_id)
	testing.expect_value(t, .Mount in again, again_stat.mnt_id > var_stat.mnt_id)
}

/*
A loop of links ends when links are followed: a/to_b leads to b and b/to_a back to
a, and a/up to the start. Each link is followed until it would lead to a
directory already on the way down, which it then stays: a/to_b is read, and
a/to_b/to_a is not, since a is above it.

	a/f  a/up  a/to_b  a/to_b/g  a/to_b/to_a
	b/g  b/to_a  b/to_a/f  b/to_a/up  b/to_a/to_b
*/
@(test)
test_a_symlink_loop_is_followed_once :: proc(t: ^testing.T) {
	base := bind_place(t, "links")
	defer os.remove_all(base)
	at :: proc(base, name: string) -> string {
		return fmt.tprintf("%s/%s", base, name)
	}
	for dir in ([]string{"a", "b"}) {
		testing.expect(t, os.make_directory(at(base, dir)) == nil)
	}
	testing.expect(t, os.write_entire_file(at(base, "a/f"), []byte{'x'}) == nil)
	testing.expect(t, os.write_entire_file(at(base, "b/g"), []byte{'x'}) == nil)
	testing.expect(t, symlink_directory("../b", at(base, "a/to_b")))
	testing.expect(t, symlink_directory("../a", at(base, "b/to_a")))
	testing.expect(t, symlink_directory("..", at(base, "a/up")))

	tree := bind_walked(t, base, Config{follow = true})
	defer scan.tree_destroy(&tree)
	// The start, a and b, and the ten entries above.
	testing.expect_value(t, tree.count, u32(13))
	_, f := named_count(&tree, "f")
	_, g := named_count(&tree, "g")
	testing.expect_value(t, f, 2)
	testing.expect_value(t, g, 2)
}

// An empty directory for one test, under the temp directory.
@(private = "file")
bind_place :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	base := fmt.tprintf("%s/leita_walk_binds_%s_%d", dir, name, os.get_pid())
	os.remove_all(base)
	testing.expect(t, os.make_directory(base) == nil, "could not make the base")
	return base
}

/*
Bind source at target. False, logged, where this process cannot mount, which fails
the test only when LEITA_MOUNT_TEST says the mounts must be made.
*/
@(private = "file")
bind :: proc(t: ^testing.T, source, target: string) -> bool {
	c :: proc(s: string) -> cstring {return strings.clone_to_cstring(s, context.temp_allocator)}
	// Without mount ids (statx before Linux 5.8) the walk cannot tell a bind from a
	// directory, so what these tests expect of one is not this kernel's to give.
	if !kernel_gives_mount_ids() {
		log.warnf("skipped: this kernel gives no mount ids (Linux 5.8); a bind is walked as a directory")
		return false
	}
	err := linux.mount(c(source), c(target), nil, {.BIND}, nil)
	if err == .NONE {
		return true
	}
	if os.get_env("LEITA_MOUNT_TEST", context.temp_allocator) != "" {
		testing.fail_now(t, "LEITA_MOUNT_TEST is set, but a bind would not mount")
	}
	log.warnf("skipped: cannot mount here (%v); just mount-test runs this", err)
	return false
}

@(private = "file")
unmount :: proc(target: string) {
	linux.umount2(strings.clone_to_cstring(target, context.temp_allocator), {.MNT_DETACH})
}

@(private = "file")
bind_walked :: proc(t: ^testing.T, root: string, cfg := Config{}) -> scan.Tree {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	testing.expect_value(t, read(root, &tree, cfg), Error.None)
	return tree
}

// How many nodes are called `name`, and the flags of the last of them.
@(private = "file")
named_count :: proc(tree: ^scan.Tree, name: string) -> (flags: scan.Node_Flags, count: int) {
	for i in 0 ..< tree.count {
		n := scan.node(tree, i)
		if .Used in scan.node_flags(n) && scan.name_of(tree, i) == name {
			flags = scan.node_flags(n)
			count += 1
		}
	}
	return
}
