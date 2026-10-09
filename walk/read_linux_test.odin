#+build linux
package walk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
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
	root := fmt.tprintf("%s/sonar_walk_sparse", dir)
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

	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		switch n.name {
		case "hole.bin":
			testing.expectf(t, n.disk < 64 * 1024, "a hole was charged %d bytes", n.disk)
		case "solid.bin":
			testing.expectf(t, n.disk >= 1 << 20, "a full megabyte was charged %d bytes", n.disk)
		}
	}
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
A directory's entries are asked about in inode order, whatever order the
directory lists them in, so a cold read goes through the inode table once rather
than seeking for each. The tree records them in the order they are asked about.

The test only tells the orders apart where the filesystem lists entries in some
other order. tmpfs, where the temp directory usually is, lists the newest first.
*/
@(test)
test_entries_are_read_in_inode_order :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/sonar_walk_inodes", dir)
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	for i in 0 ..< 40 {
		path := fmt.tprintf("%s/f%02d", root, (i * 7) % 40)
		testing.expectf(
			t,
			os.write_entire_file(path, []byte{'x'}) == nil,
			"could not write %s",
			path,
		)
	}

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	last: u64
	count := 0
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i == tree.root || .Used not_in n.flags {
			continue
		}
		path := strings.clone_to_cstring(
			fmt.tprintf("%s/%s", root, n.name),
			context.temp_allocator,
		)
		st: linux.Statx
		testing.expect(t, linux.statx(linux.AT_FDCWD, path, {}, {.INO}, &st) == .NONE)
		testing.expectf(
			t,
			u64(st.ino) > last,
			"%s (inode %d) was read after inode %d",
			n.name,
			st.ino,
			last,
		)
		last = u64(st.ino)
		count += 1
	}
	testing.expect_value(t, count, 40)
}
