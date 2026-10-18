package scan

import "core:testing"

@(test)
snapshot_names_are_owned_by_the_finished_tree :: proc(t: ^testing.T) {
	tree: Tree
	testing.expect_value(t, tree_init(&tree), Error.None)
	defer tree_destroy(&tree)
	backing := [?]u8{'s', 'n', 'a', 'p'}
	source := []string{string(backing[:])}
	testing.expect(t, note_snapshot_names(&tree, source))
	backing[0] = 'x'
	testing.expect_value(t, snapshot_names_of(&tree)[0], "snap")
	// A repeated enumeration cannot silently replace names readers might hold.
	testing.expect(t, !note_snapshot_names(&tree, source))
}
