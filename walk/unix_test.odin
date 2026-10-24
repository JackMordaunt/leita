#+build linux, darwin
package walk

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:sys/posix"
import "core:testing"

import "../scan"

// Make `path` a symlink to the directory `target`, through core:os. Windows has its
// own in read_windows_test.odin.
@(private)
symlink_directory :: proc(target, path: string) -> bool {
	return os.symlink(target, path) == nil
}

/*
A hole costs nothing and has to be charged nothing.

This is the one answer that differs from the portable reader, which knows only the
length and rounds it up to a guessed block. A file of mostly hole would be charged
its whole length that way, which for a tool reporting what fills a disk is not a
rounding error but the wrong file.
*/
@(test)
test_a_sparse_file_is_charged_what_it_occupies :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_walk_sparse_%d", dir, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")

	// One megabyte of nothing at all.
	hole, hole_err := os.open(fmt.tprintf("%s/hole.bin", root), {.Write, .Create, .Trunc})
	testing.expect(t, hole_err == nil, "could not create the sparse file")
	testing.expect(t, os.truncate(hole, 1 << 20) == nil, "could not extend the sparse file")
	os.close(hole)

	// The same length, actually written.
	body := make([]byte, 1 << 20, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/solid.bin", root), body) == nil,
		"could not write",
	)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	saw_hole, saw_solid: bool
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		switch scan.name_of(&tree, i) {
		case "hole.bin":
			saw_hole = true
			testing.expectf(t, n.disk < 64 * 1024, "a hole was charged %d bytes", n.disk)
		case "solid.bin":
			saw_solid = true
			testing.expectf(t, n.disk >= 1 << 20, "a full megabyte was charged %d bytes", n.disk)
		}
	}
	testing.expect(t, saw_hole && saw_solid, "the walk did not reach both files")
}

// A path the kernel would refuse is refused here, rather than silently truncated to
// one that names a different directory.
@(test)
test_a_path_too_long_is_refused :: proc(t: ^testing.T) {
	buf: Path
	long := make([]byte, len(buf), context.temp_allocator)
	slice.fill(long, 'a')

	_, ok := terminate(string(long), &buf)
	testing.expect(t, !ok, "an over-long path was accepted")

	fits, fits_ok := terminate("/usr/share", &buf)
	testing.expect(t, fits_ok, "an ordinary path was refused")
	testing.expect_value(t, string(fits), "/usr/share")
}

/*
A file with many names is charged once, however many workers find its names at once.

Forty directories each hold a name for the same 100 KB file, alongside a file of its
own, and eight workers read them. Every name stays in the tree so the file can be found
at each path, but exactly one is charged, and the volume's total counts the shared
file once and each lone file once.
*/
@(test)
test_a_hard_linked_file_is_charged_once :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_walk_links_%d", dir, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")

	DIRS :: 40
	body := make([]byte, 100_000, context.temp_allocator)
	slice.fill(body, 'x')
	shared := fmt.tprintf("%s/shared", root)
	testing.expect(t, os.write_entire_file(shared, body) == nil, "could not write the file")
	for i in 0 ..< DIRS {
		sub := fmt.tprintf("%s/d%02d", root, i)
		testing.expect(t, os.make_directory(sub) == nil, "could not make a directory")
		testing.expect(t, os.link(shared, fmt.tprintf("%s/name", sub)) == nil, "could not link")
		lone := fmt.tprintf("%s/lone", sub)
		testing.expect(t, os.write_entire_file(lone, body) == nil, "could not write a lone file")
	}

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 8), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{workers = 8}), Error.None)

	names, charged, lone: int
	shared_disk, lone_disk: u64
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		switch scan.name_of(&tree, i) {
		case "shared", "name":
			names += 1
			if .Extra_Name not_in n.flags {
				charged += 1
				shared_disk = n.disk
			}
		case "lone":
			lone += 1
			testing.expectf(t, .Extra_Name not_in n.flags, "a file with one name was not charged")
			lone_disk = n.disk
		}
	}
	testing.expect_value(t, names, DIRS + 1)
	testing.expect_value(t, charged, 1)
	testing.expect_value(t, lone, DIRS)
	testing.expectf(
		t,
		shared_disk >= u64(len(body)) && lone_disk >= u64(len(body)),
		"a file was charged less than its length: %d and %d",
		shared_disk,
		lone_disk,
	)
	testing.expect_value(t, tree.bytes_done, shared_disk + DIRS * lone_disk)
}

/*
A place with a directory this user may not open:

	<root>/a.txt               100 bytes
	<root>/locked/big.bin      1 MiB, behind a mode 000 directory

Root opens anything, so the fixture cannot be built there and the caller skips.
*/
@(private = "file")
locked_place :: proc(t: ^testing.T, name: string) -> (root: string, ok: bool) {
	if posix.geteuid() == 0 {
		log.info("skipped: root can open any directory")
		return "", false
	}
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root = fmt.tprintf("%s/leita_walk_%s_%d", dir, name, os.get_pid())
	unlock(root)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	locked := fmt.tprintf("%s/locked", root)
	testing.expect(t, os.make_directory(locked) == nil, "could not make locked")
	body := make([]byte, 1 << 20, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/big.bin", locked), body) == nil,
		"no big",
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/a.txt", root), body[:100]) == nil,
		"no a",
	)
	testing.expect(t, os.chmod(locked, {}) == nil, "could not lock the directory")
	return root, true
}

// Give the locked directory back, so it can be read, and removed.
@(private = "file")
unlock :: proc(root: string) {
	os.chmod(fmt.tprintf("%s/locked", root), {.Read_User, .Write_User, .Execute_User})
}

@(private = "file")
flags_of :: proc(tree: ^scan.Tree, name: string) -> (flags: scan.Node_Flags, found: bool) {
	for i in 0 ..< tree.count {
		n := scan.node(tree, i)
		if .Used in scan.node_flags(n) && scan.name_of(tree, i) == name {
			return scan.node_flags(n), true
		}
	}
	return {}, false
}

// A directory that will not open stays in the tree, flagged, and is counted as
// refused for want of permission; what it holds is not charged, and the walk goes
// on to finish without error.
@(test)
test_a_directory_that_cannot_be_opened_is_counted :: proc(t: ^testing.T) {
	root, ok := locked_place(t, "locked")
	if !ok {
		return
	}
	defer os.remove_all(root)
	defer unlock(root)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	count, denied := scan.unread(&tree)
	testing.expect_value(t, count, 1)
	testing.expect(t, denied, "a mode 000 directory was not refused for permission")
	flags, found := flags_of(&tree, "locked")
	testing.expect(t, found, "the locked directory is not in the tree")
	testing.expect(
		t,
		.Unread in flags && .Directory in flags,
		"the locked directory is not flagged",
	)
	_, charged := flags_of(&tree, "big.bin")
	testing.expect(t, !charged, "a file behind a locked directory was recorded")
	testing.expectf(
		t,
		tree.bytes_done < 1 << 20,
		"charged %d bytes through a locked door",
		tree.bytes_done,
	)
}

// An update copies what the base has, but the base has nothing of a directory it
// could not open, so that one is walked: once the directory can be read, the
// update finds what it holds, and the count of unread directories falls to zero.
@(test)
test_an_update_walks_what_the_base_could_not_read :: proc(t: ^testing.T) {
	root, ok := locked_place(t, "relocked")
	if !ok {
		return
	}
	defer os.remove_all(root)
	defer unlock(root)

	base: scan.Tree
	testing.expect_value(t, scan.tree_init(&base, 1), scan.Error.None)
	defer scan.tree_destroy(&base)
	testing.expect_value(t, read(root, &base, Config{}), Error.None)
	was, _ := scan.unread(&base)
	testing.expect_value(t, was, 1)

	unlock(root)
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	u := Update {
		base = &base,
	}
	defer delete(u.marks)
	testing.expect_value(t, update(root, &u, &tree, Config{}), Error.None)

	count, denied := scan.unread(&tree)
	testing.expect_value(t, count, 0)
	testing.expect(t, !denied, "nothing was refused this time")
	flags, found := flags_of(&tree, "locked")
	testing.expect(t, found && .Unread not_in flags, "the directory read is still flagged")
	_, charged := flags_of(&tree, "big.bin")
	testing.expect(t, charged, "the update did not read the directory the base could not")
}

/*
Following links, a link back to a directory above it is a loop, and is left the
link it is: a and b, each with a link to the other, are read once each by name and
once through the link from the other, and no deeper. Before card 731 the macOS walk
went down a/to_b/to_a/... until the path grew past what open accepts (card 672's
fuzz harness, which timed out); Linux has ended such a loop since card 525.
*/
@(test)
test_a_loop_of_links_ends_when_followed :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_walk_link_loop_%d", dir, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)

	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	a, b := fmt.tprintf("%s/a", root), fmt.tprintf("%s/b", root)
	testing.expect(t, os.make_directory(a) == nil, "could not make a")
	testing.expect(t, os.make_directory(b) == nil, "could not make b")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/in_a.txt", a), []byte{'x'}) == nil, "could not write in_a.txt")
	testing.expect(t, symlink_directory(b, fmt.tprintf("%s/to_b", a)), "could not link a/to_b")
	testing.expect(t, symlink_directory(a, fmt.tprintf("%s/to_a", b)), "could not link b/to_a")
	testing.expect(t, symlink_directory(a, fmt.tprintf("%s/to_self", a)), "could not link a/to_self")

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)

	testing.expect_value(t, read(root, &tree, Config{follow = true}), Error.None)

	// a by name, and through b/to_a; a/to_b/to_a leads back into a, a loop.
	_, in_a := named(&tree, "in_a.txt")
	testing.expect_value(t, in_a, 2)
}
