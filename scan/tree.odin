package scan

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:unicode/utf16"
import "core:unicode/utf8"

// A file or directory, in the form every reader reduces to.
Node :: struct {
	parent: u32, // index of the holding directory; a root points at itself
	name:   string, // UTF-8, owned by the tree
	size:   u64, // logical length
	disk:   u64, // bytes actually allocated
	flags:  Node_Flags,
}

Node_Flag :: enum u8 {
	Used, // written by a reader; an untouched slot has this clear
	// The parent link is final. A reader that learns of a child before its holding
	// directory leaves this clear until the parent turns up, because until then the
	// node cannot be told apart from one that has no parent at all.
	Settled,
	Directory,
	Reparse, // junction, symlink or cloud placeholder: its target is counted elsewhere
	Extra_Name, // another name for a node already counted, so rolling up must skip it
}
Node_Flags :: distinct bit_set[Node_Flag;u8]

// Nodes live in fixed blocks, so growing never moves one out from under a worker
// that is writing it. The outer array is sized once for the same reason.
@(private)
BLOCK_SHIFT :: 16
@(private)
BLOCK_NODES :: 1 << BLOCK_SHIFT
@(private)
MAX_BLOCKS :: 8192

@(private)
Block :: [BLOCK_NODES]Node

/*
What every reader writes into, and the only thing above this line reads.

A reader that knows its size up front calls `reserve` and indexes by its own
identifier. One that discovers as it goes calls `claim` for a run of slots. Either
way a slot belongs to one worker, so filling it needs no lock.
*/
Tree :: struct {
	blocks:    [MAX_BLOCKS]^Block,
	count:     u32, // slots handed out
	committed: u32, // slots backed by an allocated block
	mutex:     sync.Mutex, // guards block allocation only
	arenas:    []virtual.Arena, // one per writer; names live here for the tree's life
	root:      u32,
	// Polled by a UI rather than pushed to it, so sampling costs a reader nothing.
	nodes_done: u64,
	bytes_done: u64,
	cancel:     b32,
	allocator:  mem.Allocator,
}

// One writer per worker. Holding two in the same thread, or one in two, is the
// mistake this type exists to make visible.
Writer :: struct {
	tree:  ^Tree,
	arena: ^virtual.Arena,
}

tree_init :: proc(t: ^Tree, writers := 1, allocator := context.allocator) -> Error {
	t.allocator = allocator
	arenas, err := make([]virtual.Arena, max(writers, 1), allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	t.arenas = arenas
	for &a in t.arenas {
		if virtual.arena_init_growing(&a) != nil {
			tree_destroy(t)
			return .Out_Of_Memory
		}
	}
	return .None
}

tree_destroy :: proc(t: ^Tree) {
	for i in 0 ..< t.committed >> BLOCK_SHIFT {
		free(t.blocks[i], t.allocator)
	}
	for &a in t.arenas {
		virtual.arena_destroy(&a)
	}
	delete(t.arenas, t.allocator)
	t^ = {}
}

writer :: proc(t: ^Tree, index := 0) -> Writer {
	return {tree = t, arena = &t.arenas[index]}
}

// Make `n` slots addressable at once, for a reader that already knows how many it
// has and wants to index by its own numbering.
reserve :: proc(t: ^Tree, n: u32) -> Error {
	if !grow(t, n) {
		return .Out_Of_Memory
	}
	t.count = max(t.count, n)
	return .None
}

// Take the next `n` slots. They belong to this writer until the scan ends.
claim :: proc(w: ^Writer, n: u32) -> (first: u32, err: Error) {
	first = sync.atomic_add(&w.tree.count, n)
	if !grow(w.tree, first + n) {
		return 0, .Out_Of_Memory
	}
	return first, .None
}

node :: proc(t: ^Tree, i: u32) -> ^Node {
	return &t.blocks[i >> BLOCK_SHIFT][i & (BLOCK_NODES - 1)]
}

// Copy a name into this writer's arena, where it stays valid for the tree's life.
intern :: proc(w: ^Writer, name: string) -> string {
	buf, err := make([]byte, len(name), virtual.arena_allocator(w.arena))
	if err != nil {
		return ""
	}
	copy(buf, name)
	return string(buf)
}

// The same, for a name that arrives as UTF-16 as it does on Windows.
intern_utf16 :: proc(w: ^Writer, name: []u16) -> string {
	runes: [256]rune
	n := utf16.decode(runes[:], name)
	total := 0
	for r in runes[:n] {
		total += utf8.rune_size(r)
	}
	buf, err := make([]byte, total, virtual.arena_allocator(w.arena))
	if err != nil {
		return ""
	}
	off := 0
	for r in runes[:n] {
		enc, size := utf8.encode_rune(r)
		copy(buf[off:], enc[:size])
		off += size
	}
	return string(buf)
}

// Workers worth starting for `items` units of work, never more than `most`. A reader
// that discovers work in generations calls this per generation, since an early one
// may hold a single directory.
width_for :: proc(items, most: int) -> int {
	return max(min(items, most), 1)
}

// A reader checks this between units of work so a UI can call the scan off.
cancelled :: proc(t: ^Tree) -> bool {
	return bool(sync.atomic_load(&t.cancel))
}

cancel :: proc(t: ^Tree) {
	sync.atomic_store(&t.cancel, true)
}

progress :: proc(t: ^Tree, nodes, bytes: u64) {
	sync.atomic_add(&t.nodes_done, nodes)
	sync.atomic_add(&t.bytes_done, bytes)
}

@(private)
grow :: proc(t: ^Tree, needed: u32) -> bool {
	if needed <= sync.atomic_load(&t.committed) {
		return true
	}
	sync.guard(&t.mutex)
	for t.committed < needed {
		i := t.committed >> BLOCK_SHIFT
		if int(i) >= MAX_BLOCKS {
			return false
		}
		b, err := new(Block, t.allocator)
		if err != nil {
			return false
		}
		t.blocks[i] = b
		sync.atomic_store(&t.committed, t.committed + BLOCK_NODES)
	}
	return true
}

/*
Rebuild a node's path by following parents to a root.

A root points at itself, which is also how an orphan is marked: a node whose real
parent could not be resolved is rooted at itself and its path starts at its own name.
Depth is capped because a corrupt or racing source can produce a cycle.
*/
path :: proc(t: ^Tree, i: u32, allocator := context.allocator) -> string {
	chain: [64]u32
	depth := 0
	cur := i
	for depth < len(chain) {
		chain[depth] = cur
		depth += 1
		n := node(t, cur)
		if n.parent == cur || n.parent >= t.count {
			break
		}
		cur = n.parent
	}

	sb := strings.builder_make(allocator)
	for j := depth - 1; j >= 0; j -= 1 {
		name := node(t, chain[j]).name
		if name == "" {
			continue
		}
		// The root carries its own separator on Windows, so joining blindly would
		// double it.
		if strings.builder_len(sb) > 0 && !strings.has_suffix(strings.to_string(sb), `\`) {
			strings.write_byte(&sb, '\\')
		}
		strings.write_string(&sb, name)
	}
	if strings.builder_len(sb) == 0 {
		strings.write_byte(&sb, '\\')
	}
	return strings.to_string(sb)
}
