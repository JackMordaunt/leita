#+build linux, darwin
package walk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"

import "../scan"

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
	root := fmt.tprintf("%s/estoile_walk_sparse", dir)
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
	root := fmt.tprintf("%s/estoile_walk_links", dir)
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
