package survey

import "core:testing"

import "../scan"

/*
A root holding a directory holding a file, written child first: the order
scan.Node_Flag.Settled allows for, a child learned of before its holding directory.
The file is settled before its directory exists, so it can be neither charged nor
listed until the directory turns up.

	0  root/
	1  root/dir/
	2  root/dir/file    100 bytes
*/
@(private = "file")
place :: proc(t: ^scan.Tree, i, parent: u32, disk: u64, flags: scan.Node_Flags) {
	n := scan.node(t, i)
	n.parent = parent
	n.disk = disk
	scan.node_publish(n, flags)
}

@(private = "file")
list_children :: proc(r: ^Rollup, dir: u32) -> (out: [dynamic]u32) {
	out = make([dynamic]u32, context.temp_allocator)
	it := children(r, dir)
	for c in next_child(&it) {
		append(&out, c)
	}
	return
}

@(test)
a_child_is_listed_once_its_chain_is_charged :: proc(t: ^testing.T) {
	tree: scan.Tree
	testing.expect(t, scan.tree_init(&tree) == nil)
	defer scan.tree_destroy(&tree)
	testing.expect(t, scan.reserve(&tree, 3) == nil)

	r := Rollup {
		linked = true,
	}
	defer rollup_destroy(&r)

	place(&tree, 0, 0, 0, {.Used, .Settled, .Directory})
	place(&tree, 2, 1, 100, {.Used, .Settled})
	rollup_advance(&r, &tree)
	testing.expect_value(t, len(list_children(&r, 1)), 0)
	testing.expect_value(t, r.pending, 1)

	place(&tree, 1, 0, 0, {.Used, .Settled, .Directory})
	rollup_advance(&r, &tree)
	under_root := list_children(&r, 0)
	under_dir := list_children(&r, 1)
	testing.expect_value(t, len(under_root), 1)
	testing.expect_value(t, len(under_dir), 1)
	if len(under_root) == 1 && len(under_dir) == 1 {
		testing.expect_value(t, under_root[0], 1)
		testing.expect_value(t, under_dir[0], 2)
	}
	testing.expect_value(t, total(&r, 0), 100)
	testing.expect_value(t, total(&r, 1), 100)

	// A restatement forgets the lists with the totals, and the next pass rebuilds
	// both rather than listing anything twice.
	rollup_restate(&r)
	testing.expect_value(t, len(list_children(&r, 0)), 0)
	rollup_advance(&r, &tree)
	testing.expect_value(t, len(list_children(&r, 0)), 1)
	testing.expect_value(t, len(list_children(&r, 1)), 1)
}

@(test)
a_forgotten_directory_leaves_the_totals_and_its_list :: proc(t: ^testing.T) {
	tree: scan.Tree
	testing.expect(t, scan.tree_init(&tree) == nil)
	defer scan.tree_destroy(&tree)
	testing.expect(t, scan.reserve(&tree, 4) == nil)

	r := Rollup {
		linked = true,
	}
	defer rollup_destroy(&r)

	// root/ holding dir/ (with file, 100 bytes) and keep (30 bytes).
	place(&tree, 0, 0, 0, {.Used, .Settled, .Directory})
	place(&tree, 1, 0, 0, {.Used, .Settled, .Directory})
	place(&tree, 2, 1, 100, {.Used, .Settled})
	place(&tree, 3, 0, 30, {.Used, .Settled})
	rollup_advance(&r, &tree)
	testing.expect_value(t, total(&r, 0), 130)

	forget(&r, &tree, 1)
	testing.expect_value(t, total(&r, 0), 30)
	under_root := list_children(&r, 0)
	testing.expect_value(t, len(under_root), 1)
	if len(under_root) == 1 {
		testing.expect_value(t, under_root[0], 3)
	}
	testing.expect(t, removed(&r, &tree, 2), "what was under it is gone too")
	testing.expect(t, !removed(&r, &tree, 3))

	// A restatement charges everything again but what was forgotten.
	rollup_restate(&r)
	rollup_advance(&r, &tree)
	testing.expect_value(t, total(&r, 0), 30)
	testing.expect_value(t, len(list_children(&r, 0)), 1)
}

@(test)
only_directories_take_a_total :: proc(t: ^testing.T) {
	tree: scan.Tree
	testing.expect(t, scan.tree_init(&tree) == nil)
	defer scan.tree_destroy(&tree)
	testing.expect(t, scan.reserve(&tree, 6) == nil)

	r: Rollup
	defer rollup_destroy(&r)

	// root/ holding three files, an empty directory, and a directory at a higher
	// index than the file it holds, as NTFS numbers them.
	//   0  root/
	//   1  root/late/hold    40 bytes
	//   2  root/a            10 bytes
	//   3  root/b            20 bytes
	//   4  root/empty/
	//   5  root/late/
	place(&tree, 0, 0, 0, {.Used, .Settled, .Directory})
	place(&tree, 1, 5, 40, {.Used, .Settled})
	place(&tree, 2, 0, 10, {.Used, .Settled})
	place(&tree, 3, 0, 20, {.Used, .Settled})
	place(&tree, 4, 0, 0, {.Used, .Settled, .Directory})
	place(&tree, 5, 0, 0, {.Used, .Settled, .Directory})
	rollup_advance(&r, &tree)

	testing.expect_value(t, len(r.dir_totals), 3)
	testing.expect_value(t, total(&r, 0), 70)
	testing.expect_value(t, total(&r, 5), 40)
	testing.expect_value(t, total(&r, 4), 0)
	testing.expect_value(t, total(&r, 2), 0) // a file's bytes are its own disk
	testing.expect_value(t, total(&r, 6), 0) // past what the rollup has seen
}
