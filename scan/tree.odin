package scan

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"

// A file or directory, in the form every reader reduces to. The name is a handle
// rather than a string, and sits with the flags and directory number beside the
// parent, so all four share the space a string alone would take.
Node :: struct {
	parent: u32, // index of the holding directory; a root points at itself
	name:   Name, // read with `name_of`
	flags:  Node_Flags,
	// A directory's number plus one, given by whatever rolls the tree up so it can keep
	// totals by directory rather than by node. 0 until then. No reader writes it.
	dir:    u32,
	disk:   u64, // bytes actually allocated
}
// Every node in a scan pays this, so growing it is a decision, never an accident.
#assert(size_of(Node) == 24)

// Where a node's name is kept: `length` bytes of UTF-8 at `offset` in one of the
// tree's pools. The zero value is the empty name.
Name :: struct #packed {
	offset: u32,
	length: u16,
	pool:   u8,
}

// What a pool may hold, which is as far as a Name's offset reaches. Only what is used
// is committed, so this costs address space rather than memory.
POOL_RESERVE :: 4 * mem.Gigabyte

// A Name's pool is a byte.
@(private)
MAX_POOLS :: 256

// A region names are kept in, contiguous so an offset alone can find one.
@(private)
Pool :: struct {
	base: [^]byte,
	size: uint,
}

Node_Flag  :: enum u8 {
	Used, // written by a reader; an untouched slot has this clear
	// The parent link is final. A reader that learns of a child before its holding
	// directory leaves this clear until the parent turns up, because until then the
	// node cannot be told apart from one that has no parent at all.
	Settled,
	Directory,
	Reparse, // junction, symlink or cloud placeholder: its target is counted elsewhere
	Extra_Name, // another name for a node already counted, so rolling up must skip it
	// A directory another volume is mounted on, recorded but not read: what is under
	// it belongs to that volume, so an update of this tree never reads it either.
	Mount,
	// A file some of whose extents another file had already been charged for: a
	// reflinked copy or a snapshot's, on btrfs, when the walk could read extents. Its
	// disk is only what it holds alone.
	Shared,
	// A directory the reader could not open or list, or holding an entry it could
	// not ask the size or type of, so some of what is under it is not in the tree.
	// An update of this tree reads it again rather than copying it.
	Unread,
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
	blocks:     [MAX_BLOCKS]^Block,
	count:      u32, // slots handed out
	committed:  u32, // slots backed by an allocated block
	mutex:      sync.Mutex, // guards block allocation and lending a pool
	// One per writer, then one for names given outside any writer. Names live here
	// for the tree's life. Each arena sits on a cache line of its own: packed
	// together, one's mutex shares a line with the next writer's header, and a
	// ~/Source walk spent 18% of its samples on that line (2026-10-12).
	arenas:     []Arena_Slot,
	// Every arena above, then any a reader has lent. A slot is filled before any node
	// names it, so whoever has seen the node's flags may read its pool.
	pools:      [MAX_POOLS]Pool,
	pool_count: int,
	naming:     sync.Mutex, // guards the last arena, which any thread may name into
	root:       u32,
	// Polled by a UI rather than pushed to it, so sampling costs a reader nothing.
	nodes_done: u64,
	bytes_done: u64,
	cancel:     b32,
	restated:   b32,
	// Some of the tree's btrfs files are charged their st_blocks, which on btrfs is
	// the logical size: a compressed file at its uncompressed size, an extent shared
	// by reflinks or snapshots once for every file. Set by a walk that could not read
	// the extents themselves, which takes root.
	logical:    b32,
	// Directories a reader could not read whole (Node_Flag.Unread), and whether
	// any of them refused for want of permission rather than for another reason.
	// Added by a walk once it has finished.
	unread:     u64,
	denied:     b32,
	allocator:  mem.Allocator,
	// A walk that folded totals as directories finished. Nil for every other reader,
	// and for a walk that was told not to. Freed with the tree.
	folded:     ^Folded,
	// The name each file with more than one was charged under, as the walk found
	// them; empty for a reader that keeps no file ids. Freed with the tree.
	linked:     [dynamic]Link,
}

// Where a file's data lives, the same for every name it has. `upper` is the high half
// of a 128-bit file id, which the Windows reader takes from FILE_ID_EXTD_DIR_INFO's
// FileId (read_windows.odin), and 0 where a reader's ids are 64 bits.
File_Id :: struct {
	device: u64,
	inode:  u64,
	upper:  u64,
}

/*
A name a file with more than one was charged under, and that file. The tree keeps
no file ids otherwise, and an update needs them: before it reads anything it marks
each of these files charged, so a name of one that it reads, through a directory
read again or linked since, is not charged a second time beside a name it copies
(walk.update).
*/
Link :: struct {
	node: u32,
	id:   File_Id,
}

// One writer per worker. Holding two in the same thread, or one in two, is the
// mistake this type exists to make visible.
Writer :: struct {
	tree:  ^Tree,
	arena: ^virtual.Arena,
	pool:  u8,
}

// One arena, aligned so the next one starts on the following cache line. The
// heap aligns a plain slice to 16 bytes and virtual.Arena ends in its mutex, so
// without this a worker's lock word shares a line with its neighbour's header.
@(private)
Arena_Slot :: struct #align (64) {
	arena: virtual.Arena,
}

#assert(align_of(Arena_Slot) == 64)
#assert(size_of(Arena_Slot) % 64 == 0)

tree_init :: proc(t: ^Tree, writers := 1, allocator := context.allocator) -> Error {
	t.allocator = allocator
	if max(writers, 1) + 1 > MAX_POOLS {
		return .Out_Of_Memory
	}
	arenas, err := make([]Arena_Slot, max(writers, 1) + 1, allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	t.arenas = arenas
	for &a in t.arenas {
		if virtual.arena_init_static(&a.arena, POOL_RESERVE) != nil {
			tree_destroy(t)
			return .Out_Of_Memory
		}
		t.pools[t.pool_count] = {a.arena.curr_block.base, a.arena.curr_block.reserved}
		t.pool_count += 1
	}
	return .None
}

tree_destroy :: proc(t: ^Tree) {
	folded_destroy(t.folded, t.allocator)
	delete(t.linked)
	for i in 0 ..< t.committed >> BLOCK_SHIFT {
		free(t.blocks[i], t.allocator)
	}
	for &a in t.arenas {
		if a.arena.curr_block != nil {
			virtual.arena_destroy(&a.arena)
		}
	}
	delete(t.arenas, t.allocator)
	t^ = {}
}

// The writer for worker `index`. The tree's last arena is not one of them.
writer :: proc(t: ^Tree, index := 0) -> Writer {
	assert(index < writers(t), "a writer past the tree's count")
	return {tree = t, arena = &t.arenas[index].arena, pool = u8(index)}
}

// How many workers can write at once, each with a writer of its own.
writers :: proc(t: ^Tree) -> int {
	return len(t.arenas) - 1
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

// The node at i. Nil when i addresses a block the array does not have: one
// compare, so a count or a parent taken from a file cannot be followed off its end.
node :: proc(t: ^Tree, i: u32) -> ^Node {
	if i >> BLOCK_SHIFT >= MAX_BLOCKS {
		return nil
	}
	return &t.blocks[i >> BLOCK_SHIFT][i & (BLOCK_NODES - 1)]
}

/*
Finish a node, once everything else about it is written.

Flags go last and atomically, so a reader that sees them is looking at a node whose
name, sizes and parent are already in place. Without that order a watcher could charge
a node for a size that had not been stored yet.
*/
node_publish :: proc(n: ^Node, flags: Node_Flags) {
	sync.atomic_store((^u8)(&n.flags), transmute(u8)flags)
}

// Add `flags` to a node already published, atomically, so a watcher reading the
// flags at the same time sees the old set or the new, never a torn one.
node_mark :: proc(n: ^Node, flags: Node_Flags) {
	sync.atomic_or((^u8)(&n.flags), transmute(u8)flags)
}

// A node's flags, read as a watcher must. Pairs with `node_publish`: an untouched slot
// reads back empty, and a written one reads back whole.
node_flags :: proc(n: ^Node) -> Node_Flags {
	return transmute(Node_Flags)sync.atomic_load((^u8)(&n.flags))
}

// The text of node `i`'s name, valid for the tree's life.
name_of :: proc(t: ^Tree, i: u32) -> string {
	n := node(t, i).name
	return string(t.pools[n.pool].base[n.offset:][:n.length])
}

// Copy a name into this writer's arena. A name too long for a Name, or one the arena
// has no room left for, comes back empty.
intern :: proc(w: ^Writer, name: string) -> Name {
	return copy_into(w.arena, w.pool, name)
}

// Where a run of names was stored. `name_at` turns a position in that run into a Name.
Name_Span :: struct {
	offset: u32,
	pool:   u8,
}

/*
Copy a directory's names in one allocation.

`buf` is copied whole, including whatever separators the caller kept between names,
so a name that lay at `at` for `n` bytes still lies there in the copy. One directory
then takes one arena lock instead of one per entry. An empty buffer succeeds and
names nothing. Failure stores nothing.
*/
intern_span :: proc(w: ^Writer, buf: []byte) -> (span: Name_Span, ok: bool) {
	if len(buf) == 0 {
		return {}, true
	}
	data, err := virtual.arena_alloc(w.arena, uint(len(buf)), 1)
	if err != nil {
		return {}, false
	}
	copy(data, buf)
	// The same subtraction `copy_into` uses, so a Name built from this span is read
	// back by `name_of` like any other. A pool is no larger than a Name's offset.
	at := uintptr(raw_data(data)) - uintptr(w.arena.curr_block.base)
	assert(at <= uintptr(max(u32)), "a name past what an offset can name")
	return Name_Span{offset = u32(at), pool = w.pool}, true
}

// The Name for `n` bytes at `at` inside `span`. Too long for a Name, or empty, is the
// empty name, as `intern` returns for a name a Name cannot hold.
name_at :: proc(span: Name_Span, at, n: int) -> Name {
	if n <= 0 || n > int(max(u16)) {
		return {}
	}
	return {offset = span.offset + u32(at), length = u16(n), pool = span.pool}
}

/*
Copy a name given outside any writer: a rename, or a root named after the scan.

Serialised, so any thread may call it, and a name given this way is kept for the tree's
life even if another replaces it, so call it once per name rather than once per frame.
*/
name_copy :: proc(t: ^Tree, name: string) -> Name {
	sync.guard(&t.naming)
	last := len(t.arenas) - 1
	return copy_into(&t.arenas[last].arena, u8(last), name)
}

/*
Let the tree read names out of `a`, an arena some reader keeps its own names in, so
its nodes can borrow them without a copy. `a` must be static, so it never moves, and
must outlive the tree.
*/
lend :: proc(t: ^Tree, a: ^virtual.Arena) -> Error {
	assert(a.kind == .Static, "a pool that can move")
	sync.guard(&t.mutex)
	if t.pool_count == MAX_POOLS {
		return .Out_Of_Memory
	}
	t.pools[t.pool_count] = {a.curr_block.base, a.curr_block.reserved}
	t.pool_count += 1
	return .None
}

// The Name for `s`, which must sit in one of the tree's pools, its own or a lent one.
name_in :: proc(t: ^Tree, s: string) -> (n: Name, ok: bool) {
	if len(s) == 0 {
		return {}, true
	}
	if len(s) > int(max(u16)) {
		return {}, false
	}
	at := uintptr(raw_data(s))
	for i in 0 ..< t.pool_count {
		base := uintptr(t.pools[i].base)
		if at >= base && uint(at - base) + uint(len(s)) <= t.pools[i].size {
			return {offset = u32(at - base), length = u16(len(s)), pool = u8(i)}, true
		}
	}
	return {}, false
}

@(private)
copy_into :: proc(a: ^virtual.Arena, pool: u8, name: string) -> Name {
	if len(name) > int(max(u16)) {
		return {}
	}
	buf, err := virtual.arena_alloc(a, uint(len(name)), 1)
	if err != nil {
		return {}
	}
	copy(buf, name)
	at := uintptr(raw_data(buf)) - uintptr(a.curr_block.base)
	return {offset = u32(at), length = u16(len(name)), pool = pool}
}

// Workers worth starting for `items` units of work, never more than `most`. A reader
// that discovers work in generations calls this per generation, since an early one
// may hold a single directory.
width_for :: proc(items, most: int) -> int {
	return max(min(items, most), 1)
}

/*
Slots that can be addressed right now.

`claim` takes its range before allocating the block that backs it, so the count alone
runs ahead of what exists. Whichever is smaller is the part a watcher may look at; a
slot claimed but not yet written reads back with no flags set and is simply skipped.
*/
slots :: proc(t: ^Tree) -> u32 {
	return min(sync.atomic_load(&t.count), sync.atomic_load(&t.committed))
}

// A reader checks this between units of work so a UI can call the scan off.
cancelled :: proc(t: ^Tree) -> bool {
	return bool(sync.atomic_load(&t.cancel))
}

cancel :: proc(t: ^Tree) {
	sync.atomic_store(&t.cancel, true)
}

/*
Say that what was read out of this tree before may be wrong.

A reader that can only learn a node's final size late has to write some of them twice,
and anything derived from the first writing has to be thrown away rather than added
to. Set once the restatement is complete, so whoever acts on it sees the finished
tree rather than one mid-rewrite.

This is the only thing above the readers that has to be understood about any of them.
*/
restate :: proc(t: ^Tree) {
	sync.atomic_store(&t.restated, true)
}

// Whether the tree has been restated since this was last asked, clearing it.
taken_restated :: proc(t: ^Tree) -> bool {
	return bool(sync.atomic_exchange(&t.restated, false))
}

// Say that some btrfs sizes in the tree are logical, not what the files occupy.
mark_logical :: proc(t: ^Tree) {
	sync.atomic_store(&t.logical, true)
}

// Count `count` more directories the reader could not read whole, `denied` if
// any of them refused for want of permission.
add_unread :: proc(t: ^Tree, count: u64, denied: bool) {
	if count == 0 {
		return
	}
	sync.atomic_add(&t.unread, count)
	if denied {
		sync.atomic_store(&t.denied, true)
	}
}

// How many directories the reader could not read whole, and whether permission
// was what any of them lacked.
unread :: proc(t: ^Tree) -> (count: u64, denied: bool) {
	return sync.atomic_load(&t.unread), bool(sync.atomic_load(&t.denied))
}

// Whether some btrfs sizes in the tree are logical: read as root, they would be less.
is_logical :: proc(t: ^Tree) -> bool {
	return bool(sync.atomic_load(&t.logical))
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

// Paths are written for the machine showing them rather than for the filesystem they
// came from, so an NTFS volume read from unix still prints something the shell there
// would take back. Exported so a test building a path by hand joins it the same way.
SEPARATOR :: `\` when ODIN_OS == .Windows else "/"

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
		if n.parent == cur || n.parent >= slots(t) {
			break
		}
		cur = n.parent
	}

	sb := strings.builder_make(allocator)
	for j := depth - 1; j >= 0; j -= 1 {
		// Reading the flags first is what makes the name safe to read at all.
		if .Used not_in node_flags(node(t, chain[j])) {
			continue
		}
		name := name_of(t, chain[j])
		if name == "" {
			continue
		}
		// The root carries its own separator, so joining blindly would double it.
		if strings.builder_len(sb) > 0 && !strings.has_suffix(strings.to_string(sb), SEPARATOR) {
			strings.write_string(&sb, SEPARATOR)
		}
		strings.write_string(&sb, name)
	}
	if strings.builder_len(sb) == 0 {
		strings.write_string(&sb, SEPARATOR)
	}
	// The builder grew past the path. A caller frees the string it is given, so
	// the block must be exactly the string's length, or the free names the wrong
	// size: jm:debug reports that as a Size_Mismatch issue.
	shrink(&sb.buf)
	return strings.to_string(sb)
}
