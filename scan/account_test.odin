package scan

import "core:mem"
import "core:testing"

@(private = "file")
opened :: proc(t: ^testing.T) -> Tree {
	tree: Tree
	testing.expect_value(t, tree_init(&tree), Error.None)
	return tree
}

@(test)
test_account_common_record_is_24_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Account_Common), 24)
	testing.expect_value(t, size_of(Node), 24)
	// One million nodes that all carry a fact: 16 blocks, 24 bytes a slot.
	testing.expect_value(t, account_common_bytes(1_000_000), u64(16 * 65536 * 24))
	testing.expect_value(t, account_common_bytes(1_000_000), u64(25_165_824))
	testing.expect(t, account_common_bytes(1_000_000) / 1_000_000 <= 26)
	testing.expect_value(t, account_common_bytes(0), u64(0))
}

@(test)
test_account_set_allocates_one_block_not_one_object_per_node :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	tree := opened(t)
	defer tree_destroy(&tree)
	testing.expect_value(t, reserve(&tree, 1000), Error.None)

	before := len(track.allocation_map)
	for i in 0 ..< 1000 {
		ok := account_set(&tree, u32(i), Account{allocated = 4096, links = 1, known = {.Allocated, .Links}})
		testing.expect(t, ok)
	}
	// The tables, then the one block every account in this range shares.
	testing.expect_value(t, len(track.allocation_map) - before, 2)
	testing.expect(t, tree.facts.rares[0] == nil)

	a, ok := account_of(&tree, 999)
	testing.expect(t, ok)
	testing.expect_value(t, a.allocated, u64(4096))
	testing.expect_value(t, a.links, u32(1))
	testing.expect(t, a.known == {.Allocated, .Links})

	_, missing := account_of(&tree, 1000)
	testing.expect(t, !missing)
}

@(test)
test_account_rare_block_only_when_a_value_is_nonzero :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	tree := opened(t)
	defer tree_destroy(&tree)

	before := len(track.allocation_map)
	for i in 0 ..< 64 {
		ok := account_set(&tree, u32(i), Account{known = {.Reclaim, .Exclusive}})
		testing.expect(t, ok)
	}
	// The tables, then the one block every account in this range shares.
	testing.expect_value(t, len(track.allocation_map) - before, 2)
	testing.expect(t, tree.facts.rares[0] == nil)

	a, ok := account_of(&tree, 3)
	testing.expect(t, ok)
	testing.expect_value(t, a.reclaim, u64(0))
	testing.expect_value(t, a.exclusive, u64(0))
	testing.expect(t, a.known == {.Reclaim, .Exclusive})

	ok = account_set(&tree, 80, Account{reclaim = 128, known = {.Reclaim}})
	testing.expect(t, ok)
	// The tables, the common block, and now the rare block.
	testing.expect_value(t, len(track.allocation_map) - before, 3)
	for i in 81 ..< 100 {
		ok = account_set(&tree, u32(i), Account{exclusive = 7, known = {.Exclusive}})
		testing.expect(t, ok)
	}
	testing.expect_value(t, len(track.allocation_map) - before, 3)

	a, ok = account_of(&tree, 3)
	testing.expect(t, ok)
	testing.expect_value(t, a.reclaim, u64(0))
	a, ok = account_of(&tree, 80)
	testing.expect(t, ok)
	testing.expect_value(t, a.reclaim, u64(128))
	a, ok = account_of(&tree, 90)
	testing.expect(t, ok)
	testing.expect_value(t, a.exclusive, u64(7))
}

@(test)
test_account_and_retention_publish_once :: proc(t: ^testing.T) {
	tree := opened(t)
	defer tree_destroy(&tree)

	first := Account {
		logical = 10,
		allocated = 20,
		exclusive = 30,
		shared = 40,
		held = 50,
		reclaim = 60,
		links = 2,
		known = {.Logical, .Allocated, .Exclusive, .Shared, .Held, .Reclaim, .Links},
	}
	testing.expect(t, account_set(&tree, 1, first))
	second := first
	second.logical = 99
	second.allocated = 99
	second.reclaim = 1
	second.links = 9
	testing.expect(t, !account_set(&tree, 1, second))

	a, ok := account_of(&tree, 1)
	testing.expect(t, ok)
	testing.expect_value(t, a.logical, u64(10))
	testing.expect_value(t, a.allocated, u64(20))
	testing.expect_value(t, a.exclusive, u64(30))
	testing.expect_value(t, a.shared, u64(40))
	testing.expect_value(t, a.held, u64(50))
	testing.expect_value(t, a.reclaim, u64(60))
	testing.expect_value(t, a.links, u32(2))
	testing.expect(t, a.known == first.known)

	// An empty known set does not publish and does not erase the first record.
	testing.expect(t, account_set(&tree, 1, {}))
	a, ok = account_of(&tree, 1)
	testing.expect(t, ok && a.logical == 10 && a.links == 2)

	testing.expect(t, note_retention(&tree, {snapshots = .None, purgeable = 4, purgeable_known = true}))
	testing.expect(t, !note_retention(&tree, {snapshots = .Present, purgeable = 99, purgeable_known = true}))
	got := retention_of(&tree)
	testing.expect_value(t, got.snapshots, Snapshot_State.None)
	testing.expect_value(t, got.purgeable, u64(4))
	testing.expect(t, got.purgeable_known)
	f := freed_of(&tree, 1)
	testing.expect_value(t, f.basis, Basis.Exact)
	testing.expect_value(t, f.bytes, u64(0))
}

@(test)
test_account_index_is_stable_across_blocks :: proc(t: ^testing.T) {
	tree := opened(t)
	defer tree_destroy(&tree)
	testing.expect(t, account_set(&tree, 0, Account{logical = 1, known = {.Logical}}))
	testing.expect(t, account_set(&tree, BLOCK_NODES, Account{logical = 2, known = {.Logical}}))
	testing.expect(t, account_set(&tree, BLOCK_NODES - 1, Account{logical = 3, known = {.Logical}}))

	a, ok := account_of(&tree, 0)
	testing.expect(t, ok && a.logical == 1)
	a, ok = account_of(&tree, BLOCK_NODES - 1)
	testing.expect(t, ok && a.logical == 3)
	a, ok = account_of(&tree, BLOCK_NODES)
	testing.expect(t, ok && a.logical == 2)
	_, ok = account_of(&tree, BLOCK_NODES + 1)
	testing.expect(t, !ok)

	testing.expect(t, !account_set(&tree, MAX_BLOCKS * BLOCK_NODES, Account{known = {.Logical}}))
	testing.expect(t, account_set(&tree, 5, {}))
	_, ok = account_of(&tree, 5)
	testing.expect(t, !ok)
}

@(test)
test_freed_quantity_only_for_exact_proof :: proc(t: ^testing.T) {
	tree := opened(t)
	defer tree_destroy(&tree)
	testing.expect_value(t, reserve(&tree, 16), Error.None)

	// A copied disk figure, the baseline case, is not a frees quantity.
	node(&tree, 0).disk = 4096
	node_publish(node(&tree, 0), {.Used, .Settled})
	f := freed_of(&tree, 0)
	testing.expect_value(t, f.basis, Basis.Unknown)
	testing.expect_value(t, f.bytes, u64(0))

	node_publish(node(&tree, 1), {.Used, .Settled, .Extra_Name})
	node(&tree, 1).disk = 4096
	f = freed_of(&tree, 1)
	testing.expect_value(t, f.basis, Basis.Exact)
	testing.expect_value(t, f.bytes, u64(0))

	testing.expect(t, account_set(&tree, 2, Account{links = 3, allocated = 8192, known = {.Links, .Allocated}}))
	f = freed_of(&tree, 2)
	testing.expect_value(t, f.basis, Basis.Exact)
	testing.expect_value(t, f.bytes, u64(0))

	testing.expect(t, account_set(&tree, 3, Account{reclaim = 100, known = {.Reclaim}}))
	f = freed_of(&tree, 3)
	testing.expect_value(t, f.basis, Basis.Exact)
	testing.expect_value(t, f.bytes, u64(100))

	// Allocated, one link, snapshots proved absent, exclusive known: still no frees quantity.
	testing.expect(t, account_set(&tree, 4, Account{
		allocated = 4096,
		exclusive = 4096,
		links = 1,
		known = {.Allocated, .Exclusive, .Links},
	}))
	testing.expect(t, note_retention(&tree, {snapshots = .None}))
	f = freed_of(&tree, 4)
	testing.expect_value(t, f.basis, Basis.Charged)
	testing.expect_value(t, f.bytes, u64(0))
	a, ok := account_of(&tree, 4)
	testing.expect(t, ok && a.allocated == 4096 && a.exclusive == 4096)

	held := opened(t)
	defer tree_destroy(&held)
	testing.expect_value(t, reserve(&held, 4), Error.None)
	testing.expect(t, account_set(&held, 2, Account{links = 3, known = {.Links}}))
	testing.expect(t, account_set(&held, 4, Account{allocated = 4096, known = {.Allocated}}))
	testing.expect(t, note_retention(&held, {snapshots = .Present, purgeable = 10, purgeable_known = true}))
	f = freed_of(&held, 4)
	testing.expect_value(t, f.basis, Basis.Unknown)
	testing.expect_value(t, f.bytes, u64(0))
	got := retention_of(&held)
	testing.expect_value(t, got.snapshots, Snapshot_State.Present)
	testing.expect_value(t, got.purgeable, u64(10))
	testing.expect(t, got.purgeable_known)
	// Name-unlink stays Exact while snapshots are present.
	f = freed_of(&held, 2)
	testing.expect_value(t, f.basis, Basis.Exact)
	testing.expect_value(t, f.bytes, u64(0))
}

@(test)
test_freed_does_not_invent_exact_from_missing_facts :: proc(t: ^testing.T) {
	tree := opened(t)
	defer tree_destroy(&tree)
	testing.expect_value(t, reserve(&tree, 8), Error.None)

	testing.expect(t, account_set(&tree, 0, Account{allocated = 512, known = {.Allocated}}))
	f := freed_of(&tree, 0)
	testing.expect_value(t, f.basis, Basis.Charged)
	testing.expect_value(t, f.bytes, u64(0))

	testing.expect(t, account_set(&tree, 1, Account{allocated = 512, exclusive = 512, held = 512, known = {.Allocated, .Exclusive, .Held}}))
	f = freed_of(&tree, 1)
	testing.expect_value(t, f.basis, Basis.Charged)
	testing.expect_value(t, f.bytes, u64(0))

	testing.expect(t, account_set(&tree, 2, Account{allocated = 512, shared = 512, known = {.Allocated, .Shared}}))
	f = freed_of(&tree, 2)
	testing.expect_value(t, f.basis, Basis.Unknown)
	testing.expect_value(t, f.bytes, u64(0))

	node_publish(node(&tree, 3), {.Used, .Settled, .Shared})
	node(&tree, 3).disk = 100
	f = freed_of(&tree, 3)
	testing.expect_value(t, f.basis, Basis.Unknown)
	testing.expect_value(t, f.bytes, u64(0))

	mark_logical(&tree)
	f = freed_of(&tree, 0)
	testing.expect_value(t, f.basis, Basis.Unknown)
	testing.expect_value(t, f.bytes, u64(0))

	tree2 := opened(t)
	defer tree_destroy(&tree2)
	testing.expect_value(t, reserve(&tree2, 2), Error.None)
	testing.expect(t, account_set(&tree2, 0, Account{allocated = 64, known = {.Allocated, .Scan_Order}}))
	f = freed_of(&tree2, 0)
	testing.expect_value(t, f.basis, Basis.Unknown)
	mark_scan_order(&tree2)
	testing.expect(t, is_scan_order(&tree2))
	testing.expect(t, account_set(&tree2, 1, Account{links = 2, known = {.Links}}))
	f = freed_of(&tree2, 1)
	testing.expect_value(t, f.basis, Basis.Exact)
	testing.expect_value(t, f.bytes, u64(0))
}

@(test)
test_account_blocks_are_freed_with_the_tree :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	tree := opened(t)
	testing.expect(t, account_set(&tree, 0, Account{allocated = 1, known = {.Allocated}}))
	testing.expect(t, account_set(&tree, 1, Account{reclaim = 1, known = {.Reclaim}}))
	tree_destroy(&tree)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_exact_frees_is_null_unless_exact_and_keeps_exact_zero :: proc(t: ^testing.T) {
	_, ok := exact_frees({})
	testing.expect(t, !ok)
	_, ok = exact_frees({basis = .Charged})
	testing.expect(t, !ok)
	bytes, ok2 := exact_frees({basis = .Exact})
	testing.expect(t, ok2)
	testing.expect_value(t, bytes, u64(0))
	bytes, ok2 = exact_frees({bytes = 12, basis = .Exact})
	testing.expect(t, ok2)
	testing.expect_value(t, bytes, u64(12))
}

@(test)
test_delete_line_names_a_quantity_only_when_exact_differs :: proc(t: ^testing.T) {
	tree := opened(t)
	defer tree_destroy(&tree)
	testing.expect_value(t, reserve(&tree, 4), Error.None)

	// Exact 0 against a charged share: say so. Exact 0 against a charged 0: say nothing.
	testing.expect(t, account_set(&tree, 0, Account{links = 2, known = {.Links}}))
	line := delete_line(&tree, 0, 4096)
	testing.expect(t, line.has_frees && line.frees == 0 && !line.unknown)
	line = delete_line(&tree, 0, 0)
	testing.expect(t, !line.has_frees && !line.unknown)

	// Charged, length different from the charge: a phrase, not a quantity.
	testing.expect(t, account_set(&tree, 1, Account{logical = 100, allocated = 4096, links = 1, known = {.Logical, .Allocated, .Links}}))
	testing.expect_value(t, freed_of(&tree, 1).basis, Basis.Charged)
	line = delete_line(&tree, 1, 4096)
	testing.expect(t, !line.has_frees && line.unknown)

	// Length equal to the charge, or unknown: no extra line.
	testing.expect(t, account_set(&tree, 2, Account{logical = 4096, allocated = 4096, links = 1, known = {.Logical, .Allocated, .Links}}))
	line = delete_line(&tree, 2, 4096)
	testing.expect(t, !line.has_frees && !line.unknown)
	line = delete_line(&tree, 3, 4096)
	testing.expect(t, !line.has_frees && !line.unknown)
}
