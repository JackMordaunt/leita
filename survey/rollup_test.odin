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
	testing.expect_value(t, r.totals[0], 100)
	testing.expect_value(t, r.totals[1], 100)

	// A restatement forgets the lists with the totals, and the next pass rebuilds
	// both rather than listing anything twice.
	rollup_restate(&r)
	testing.expect_value(t, len(list_children(&r, 0)), 0)
	rollup_advance(&r, &tree)
	testing.expect_value(t, len(list_children(&r, 0)), 1)
	testing.expect_value(t, len(list_children(&r, 1)), 1)
}
