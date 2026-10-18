package scan

import "core:mem/virtual"
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

	node(&tree, 0).disk = 11
	node(&tree, BLOCK_NODES - 1).disk = 22
	node(&tree, BLOCK_NODES).disk = 33
	node(&tree, BLOCK_NODES + 15).disk = 44

	testing.expect_value(t, node(&tree, 0).disk, u64(11))
	testing.expect_value(t, node(&tree, BLOCK_NODES - 1).disk, u64(22))
	testing.expect_value(t, node(&tree, BLOCK_NODES).disk, u64(33))
	testing.expect_value(t, node(&tree, BLOCK_NODES + 15).disk, u64(44))
}

@(test)
test_reserve_makes_every_slot_addressable :: proc(t: ^testing.T) {
	// A reader that indexes by its own numbering needs the whole range at once.
	tree := fresh(t)
	defer tree_destroy(&tree)
	testing.expect_value(t, reserve(&tree, 100_000), Error.None)
	testing.expect_value(t, tree.count, u32(100_000))
	node(&tree, 99_999).disk = 7
	testing.expect_value(t, node(&tree, 99_999).disk, u64(7))
}

@(test)
test_interned_names_outlive_the_source :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)

	claim(&w, 1)
	buf := [8]byte{'r', 'e', 'p', 'o', 'r', 't', 0, 0}
	node(&tree, 0).name = intern(&w, string(buf[:6]))
	buf = {'x', 'x', 'x', 'x', 'x', 'x', 0, 0} // the source is reused, as a read buffer is
	testing.expect_value(t, name_of(&tree, 0), "report")
}

@(test)
test_each_writer_names_into_a_pool_of_its_own :: proc(t: ^testing.T) {
	tree: Tree
	testing.expect_value(t, tree_init(&tree, 2), Error.None)
	defer tree_destroy(&tree)
	testing.expect_value(t, writers(&tree), 2)
	a, b := writer(&tree, 0), writer(&tree, 1)
	claim(&a, 2)
	node(&tree, 0).name = intern(&a, "left")
	node(&tree, 1).name = intern(&b, "right")
	testing.expect(t, node(&tree, 0).name.pool != node(&tree, 1).name.pool, "writers share a pool")
	testing.expect_value(t, name_of(&tree, 0), "left")
	testing.expect_value(t, name_of(&tree, 1), "right")
}

@(test)
test_a_span_keeps_every_name_after_the_source_is_reused :: proc(t: ^testing.T) {
	// A directory's names are copied once, then the scratch buffer is reused for the
	// next directory. Each name has to outlive that.
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)
	claim(&w, 2)

	buf := [8]byte{'o', 'n', 'e', 0, 't', 'w', 'o', 0}
	span, ok := intern_span(&w, buf[:])
	testing.expect(t, ok, "the span was not stored")
	node(&tree, 0).name = name_at(span, 0, 3)
	node(&tree, 1).name = name_at(span, 4, 3)
	buf = {}
	testing.expect_value(t, name_of(&tree, 0), "one")
	testing.expect_value(t, name_of(&tree, 1), "two")
}

@(test)
test_a_span_name_too_long_for_a_handle_comes_back_empty :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)
	buf := make([]byte, int(max(u16)) + 1, context.temp_allocator)
	for &b in buf {
		b = 'x'
	}
	span, ok := intern_span(&w, buf)
	testing.expect(t, ok, "the span was not stored")
	testing.expect_value(t, name_at(span, 0, len(buf)), Name{})
	claim(&w, 1)
	node(&tree, 0).name = name_at(span, 0, int(max(u16)))
	testing.expect_value(t, len(name_of(&tree, 0)), int(max(u16)))
}

@(test)
test_an_empty_span_names_nothing :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)
	span, ok := intern_span(&w, {})
	testing.expect(t, ok, "an empty span failed")
	testing.expect_value(t, span, Name_Span{})
	testing.expect_value(t, name_at(span, 0, 0), Name{})
}

@(test)
test_writer_arenas_do_not_share_a_cache_line :: proc(t: ^testing.T) {
	tree := fresh(t, 3)
	defer tree_destroy(&tree)
	line :: uintptr(64)
	prev: uintptr
	for i in 0 ..< writers(&tree) {
		at := uintptr(writer(&tree, i).arena)
		testing.expect_value(t, at % line, uintptr(0))
		if i > 0 {
			testing.expect(t, at / line != prev / line, "two writers share a cache line")
		}
		prev = at
	}
}

@(test)
test_a_name_too_long_for_a_handle_comes_back_empty :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)
	claim(&w, 2)
	long := strings.repeat("x", int(max(u16)) + 1, context.temp_allocator)
	node(&tree, 0).name = intern(&w, long)
	node(&tree, 1).name = intern(&w, long[:max(u16)])
	testing.expect_value(t, name_of(&tree, 0), "")
	testing.expect_value(t, len(name_of(&tree, 1)), int(max(u16)))
}

@(test)
test_a_name_given_later_is_copied :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)
	claim(&w, 1)
	node(&tree, 0).name = intern(&w, "before")
	given := [5]byte{'a', 'f', 't', 'e', 'r'}
	node(&tree, 0).name = name_copy(&tree, string(given[:]))
	given[0] = 'X' // the source is the caller's, and may change after
	testing.expect_value(t, name_of(&tree, 0), "after")
}

@(test)
test_a_lent_arena_names_nodes_without_a_copy :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	w := writer(&tree)
	claim(&w, 1)

	lent: virtual.Arena
	testing.expect_value(t, virtual.arena_init_static(&lent, 1 << 20), nil)
	defer virtual.arena_destroy(&lent)
	testing.expect_value(t, lend(&tree, &lent), Error.None)
	text := strings.clone("borrowed", virtual.arena_allocator(&lent))

	name, ok := name_in(&tree, text)
	testing.expect(t, ok, "a name in a lent arena was not found")
	node(&tree, 0).name = name
	testing.expect_value(t, raw_data(name_of(&tree, 0)), raw_data(text))
	testing.expect_value(t, name_of(&tree, 0), "borrowed")

	elsewhere := strings.clone("elsewhere", context.temp_allocator)
	_, found := name_in(&tree, elsewhere)
	testing.expect(t, !found, "a name outside every pool was found")
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
		name   = intern(&w, "C:"),
		flags  = {.Used, .Directory},
	}
	node(&tree, 1)^ = Node {
		parent = 0,
		name   = intern(&w, "Windows"),
		flags  = {.Used, .Directory},
	}
	node(&tree, 2)^ = Node {
		parent = 1,
		name   = intern(&w, "notepad.exe"),
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
		name   = intern(&w, "a"),
		flags  = {.Used, .Directory},
	}
	node(&tree, 1)^ = Node {
		parent = 0,
		name   = intern(&w, "b"),
		flags  = {.Used, .Directory},
	}

	p := path(&tree, 0, context.temp_allocator)
	testing.expect(t, len(p) > 0, "a cycle produced no path at all")
}

@(test)
test_a_node_past_the_last_block_is_refused :: proc(t: ^testing.T) {
	tree := fresh(t)
	defer tree_destroy(&tree)
	testing.expect_value(t, reserve(&tree, 1), Error.None)
	testing.expect(t, node(&tree, 0) != nil, "a reserved node was not addressed")
	testing.expect(
		t,
		node(&tree, u32(MAX_BLOCKS) << BLOCK_SHIFT) == nil,
		"a block past the array was addressed",
	)
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
