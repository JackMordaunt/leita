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

// An empty directory for one bind test, under the temp directory.
@(private = "file")
bind_place :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	base := fmt.tprintf("%s/leita_walk_binds_%s", dir, name)
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
