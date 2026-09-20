#+build linux
package walk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"

import shared "../scan"

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

	tree: shared.Tree
	testing.expect_value(t, shared.tree_init(&tree, 1), shared.Error.None)
	defer shared.tree_destroy(&tree)
	testing.expect_value(t, scan(root, &tree, Config{}), Error.None)

	for i in 0 ..< tree.count {
		n := shared.node(&tree, i)
		switch n.name {
		case "hole.bin":
			testing.expect_value(t, n.size, u64(1 << 20))
			testing.expectf(t, n.disk < 64 * 1024, "a hole was charged %d bytes", n.disk)
		case "solid.bin":
			testing.expect_value(t, n.size, u64(1 << 20))
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
