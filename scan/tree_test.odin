package scan

import "core:strings"
import "core:testing"

@(private = "file")
fresh :: proc(t: ^testing.T, writers := 1) -> Tree {
	tree: Tree
	testing.expect_value(t, tree_init(&tree, writers), Error.None)
	return tree
}

@(test)
test_claim_hands_out_distinct_slots :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)

	a, a_err := claim(&w, 3)
	b, b_err := claim(&w, 2)
	testing.expect_value(t, a_err, Error.None)
	testing.expect_value(t, b_err, Error.None)
	testing.expect_value(t, a, u32(0))
	testing.expect_value(t, b, u32(3))
	testing.expect_value(t, tree.count, u32(5))
}

@(test)
test_claim_grows_across_blocks :: proc(t: ^testing.T) {
	// Crossing a block boundary is where a growable store goes wrong, so write a
	// marker either side of one and read both back.
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)

	first, err := claim(&w, BLOCK_NODES + 16)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, first, u32(0))

	node(&tree, 0).size = 11
	node(&tree, BLOCK_NODES - 1).size = 22
	node(&tree, BLOCK_NODES).size = 33
	node(&tree, BLOCK_NODES + 15).size = 44

	testing.expect_value(t, node(&tree, 0).size, u64(11))
	testing.expect_value(t, node(&tree, BLOCK_NODES - 1).size, u64(22))
	testing.expect_value(t, node(&tree, BLOCK_NODES).size, u64(33))
	testing.expect_value(t, node(&tree, BLOCK_NODES + 15).size, u64(44))
}

@(test)
test_reserve_makes_every_slot_addressable :: proc(t: ^testing.T) {
	// A reader that indexes by its own numbering needs the whole range at once.
	tree := fresh(t)
	defer tree_destroy(&tree)
	testing.expect_value(t, reserve(&tree, 100_000), Error.None)
	testing.expect_value(t, tree.count, u32(100_000))
	node(&tree, 99_999).size = 7
	testing.expect_value(t, node(&tree, 99_999).size, u64(7))
}

@(test)
test_interned_names_outlive_the_source :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)

	buf := [8]byte{'r', 'e', 'p', 'o', 'r', 't', 0, 0}
	name := intern(&w, string(buf[:6]))
	buf = {'x', 'x', 'x', 'x', 'x', 'x', 0, 0} // the source is reused, as a read buffer is
	testing.expect_value(t, name, "report")
}

@(test)
test_path_walks_to_a_root :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)
	first, _ := claim(&w, 3)
	testing.expect_value(t, first, u32(0))

	node(&tree, 0)^ = Node {
		parent = 0,
		name   = "C:",
		flags  = {.Used, .Directory},
	}
	node(&tree, 1)^ = Node {
		parent = 0,
		name   = "Windows",
		flags  = {.Used, .Directory},
	}
	node(&tree, 2)^ = Node {
		parent = 1,
		name   = "notepad.exe",
		flags  = {.Used},
	}

	// Written with the separator of the machine showing the path, not the one the
	// names came from, so this is built rather than spelled.
	want := strings.concatenate(
		{"C:", SEPARATOR, "Windows", SEPARATOR, "notepad.exe"},
		context.temp_allocator,
	)
	testing.expect_value(t, path(&tree, 2, context.temp_allocator), want)
	testing.expect_value(t, path(&tree, 0, context.temp_allocator), "C:")
}

@(test)
test_path_stops_at_a_cycle :: proc(t: ^testing.T) {
	// A corrupt source can name a parent that leads back round. The walk must end
	// rather than run forever.
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)
	claim(&w, 2)
	node(&tree, 0)^ = Node {
		parent = 1,
		name   = "a",
		flags  = {.Used, .Directory},
	}
	node(&tree, 1)^ = Node {
		parent = 0,
		name   = "b",
		flags  = {.Used, .Directory},
	}

	p := path(&tree, 0, context.temp_allocator)
	testing.expect(t, len(p) > 0, "a cycle produced no path at all")
}

@(test)
test_cancel_is_visible_to_a_reader :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	testing.expect(t, !cancelled(&tree))
	cancel(&tree)
	testing.expect(t, cancelled(&tree))
}

@(test)
test_progress_accumulates :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	progress(&tree, 3, 300)
	progress(&tree, 4, 400)
	testing.expect_value(t, tree.nodes_done, u64(7))
	testing.expect_value(t, tree.bytes_done, u64(700))
}
