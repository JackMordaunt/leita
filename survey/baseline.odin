package survey

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:sync"

import "../changes"
import "../faults"
import "../scan"

/*
A baseline is the whole of a place's last tree, kept in a file between runs with the
cursor taken before it was read, so the next run can apply what changed since rather
than read the place again. History keeps far less, entries of at least a megabyte, so
it cannot serve: an update needs every file to copy.

The file is written whole to a temporary name of its own and renamed over the old
one, so a run that stops part way leaves the last good baseline, never a torn one. The
command line, the window and the monitor may each finish a scan of the same place at
once: each writes its own temporary file, and the last whole one renamed wins. It is
written for this machine, little-endian:

	magic        "LEITABL4"
	cursor       source u8, volume 2 x u64, place 2 x u64, journal u64,
	             position i64, full i64, updates u64
	place        u32 length, then its bytes
	nodes        u32 count, u32 root
	each node    u32 parent, u8 flags, u64 disk, u16 name length, name bytes
	links        u32 count
	each link    u32 node, u64 device, u64 inode, u64 upper

Nodes are numbered afresh, used ones only, so a parent names the new number. The
numbers follow the scan's order. A parent is not moved ahead of its child, a root
or an orphan stores its own number, and a cycle is refused when the file is read.
A name is one entry in its directory: a separator or a NUL is refused, apart from
the root, whose name is the place path. The flags kept are the ones an update
needs: what a node is, Unread for a directory the scan could not open, which the
update walks rather than copies (walk.update), and Shared for a btrfs file charged
only what it does not share, so a tree read back, and an update copying from it,
can still tell it from a file that shares nothing. The flags byte held every flag
before Shared was kept, so a file written without it reads as one whose files
share nothing, which is what it said.
Roughly 15 bytes and the name a node: a home directory of 2.6 million is 70 to 80 MB.
The links are scan.Tree.linked, the name each file with more than one was charged
under and the file it names, which an update needs to charge such a file once
beside a name it copies; 28 bytes each, for such files alone. LEITABL1 kept none,
and a file of it is read as one of another version: the place is read whole once.
LEITABL2's cursor kept no place, the directory the place was, so a file of it is
read whole once too, rather than trusted by a cursor that cannot tell a replaced tree.
LEITABL3's cursor kept no count of updates, which says whose turn it is among the
small files an update measures again (walk.Update); a file of it is read whole once.
*/

@(private)
BASELINE_MAGIC :: "LEITABL4"

// The cursor's bytes: source, then eight 64-bit fields.
@(private)
CURSOR_SIZE :: 1 + 8 * 8

// Numbers each temporary file this process writes, so two threads never share one.
@(private = "file")
baseline_writes: u64

/*
Keep `t`, a finished scan of `place`, in the file at `path` with `cursor`. Whether
it was kept: a baseline that cannot be written is no reason to fail the scan, only
to read the place whole next time.
*/
baseline_save :: proc(path, place: string, t: ^scan.Tree, cursor: changes.Cursor) -> bool {
	count := scan.slots(t)
	if t.root >= count {
		return false
	}
	renumber := make([]u32, count)
	defer delete(renumber)
	used: u32
	for i in 0 ..< count {
		f := scan.node_flags(scan.node(t, i))
		renumber[i] = scan.NO_NODE
		if .Used in f && .Settled in f {
			renumber[i] = used
			used += 1
		}
	}
	if renumber[t.root] == scan.NO_NODE {
		return false
	}

	// Sized first and written in place. Appended field by field it took 384 ms for
	// /home/jfm's 2.1 million nodes, 125 ms this way (2026-10-12, timed around
	// baseline_save as survey/bench_test.odin times a fill).
	size := len(BASELINE_MAGIC) + CURSOR_SIZE + 4 + len(place) + 2 * 4
	for i in 0 ..< count {
		if renumber[i] != scan.NO_NODE {
			size += NODE_FIXED + len(scan.name_of(t, i))
		}
	}
	links: u32
	for l in t.linked {
		if l.node < count && renumber[l.node] != scan.NO_NODE {
			links += 1
		}
	}
	size += 4 + int(links) * LINK_SIZE
	out := make([]u8, size)
	defer delete(out)
	w := Writer{out, 0}
	put(&w, transmute([]u8)string(BASELINE_MAGIC))
	put_u8(&w, u8(cursor.source))
	put_u64(&w, cursor.volume[0])
	put_u64(&w, cursor.volume[1])
	put_u64(&w, cursor.place[0])
	put_u64(&w, cursor.place[1])
	put_u64(&w, cursor.journal)
	put_u64(&w, u64(cursor.position))
	put_u64(&w, u64(cursor.full))
	put_u64(&w, cursor.updates)
	put_u32(&w, u32(len(place)))
	put(&w, transmute([]u8)place)
	put_u32(&w, used)
	put_u32(&w, renumber[t.root])
	for i in 0 ..< count {
		if renumber[i] == scan.NO_NODE {
			continue
		}
		n := scan.node(t, i)
		parent := renumber[n.parent] if n.parent < count else scan.NO_NODE
		if parent == scan.NO_NODE {
			parent = renumber[i] // an orphan, or the root: it holds itself
		}
		name := scan.name_of(t, i)
		put_u32(&w, parent)
		put_u8(
			&w,
			transmute(u8)(scan.node_flags(n) &
				{.Directory, .Reparse, .Extra_Name, .Mount, .Shared, .Unread}),
		)
		put_u64(&w, n.disk)
		put_u16(&w, u16(len(name)))
		put(&w, transmute([]u8)name)
	}
	put_u32(&w, links)
	for l in t.linked {
		if l.node < count && renumber[l.node] != scan.NO_NODE {
			put_u32(&w, renumber[l.node])
			put_u64(&w, l.id.device)
			put_u64(&w, l.id.inode)
			put_u64(&w, l.id.upper)
		}
	}
	assert(w.at == len(out), "a baseline's size was miscounted")

	temporary := fmt.tprintf(
		"%s.%d-%d.new",
		path,
		os.get_pid(),
		sync.atomic_add(&baseline_writes, 1),
	)
	if dir, _ := os.split_path(path); dir != "" {
		_ = os.make_directory_all(dir)
	}
	if faults.write_entire_file(temporary, out) != nil {
		faults.remove(temporary)
		return false
	}
	if !replace(temporary, path) {
		faults.remove(temporary)
		return false
	}
	return true
}

/*
How many entries the baseline at `path` kept of `place`, read from its head alone,
so a place read whole can be sized without loading the tree; nil when there is no
baseline of this version and place. The count is of nodes kept, the entries a walk
of the place would find.
*/
baseline_entries :: proc(path, place: string, allocator := context.temp_allocator) -> Maybe(u64) {
	if path == "" {
		return nil
	}
	f, open_err := os.open(path)
	if open_err != nil {
		return nil
	}
	defer os.close(f)

	head := make([]u8, len(BASELINE_MAGIC) + CURSOR_SIZE + 4 + len(place) + 4, allocator)
	defer delete(head, allocator)

	if n, _ := os.read_full(f, head); n < len(head) {
		return nil
	}

	r := Reader{head, 0, true}
	if string(take(&r, len(BASELINE_MAGIC))) != BASELINE_MAGIC {
		return nil
	}
	take(&r, CURSOR_SIZE)
	if string(take(&r, int(take_u32(&r)))) != place {
		return nil
	}
	count := take_u32(&r)
	if !r.ok {
		return nil
	}
	return u64(count)
}

/*
Read the baseline at `path` into `t`, which must be fresh, with the cursor kept with
it. Not ok, with why, when there is none, it is of another place, or it cannot be
read whole: any of which means the place is read whole.
*/
baseline_load :: proc(
	path, place: string,
	t: ^scan.Tree,
) -> (
	cursor: changes.Cursor,
	why: string,
	ok: bool,
) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return {}, "no earlier scan of this place was kept whole", false
	}
	defer delete(data)
	r := Reader{data, 0, true}
	if string(take(&r, len(BASELINE_MAGIC))) != BASELINE_MAGIC {
		return {}, "the scan kept of this place is of another version", false
	}
	cursor.source = changes.Source(take_u8(&r))
	cursor.volume[0] = take_u64(&r)
	cursor.volume[1] = take_u64(&r)
	cursor.place[0] = take_u64(&r)
	cursor.place[1] = take_u64(&r)
	cursor.journal = take_u64(&r)
	cursor.position = i64(take_u64(&r))
	cursor.full = i64(take_u64(&r))
	cursor.updates = take_u64(&r)
	kept_place := string(take(&r, int(take_u32(&r))))
	if !r.ok || kept_place != place {
		return {}, "the scan kept is of another place", false
	}
	count := take_u32(&r)
	root := take_u32(&r)
	if !r.ok || count == 0 || root >= count {
		return {}, "the scan kept of this place could not be read", false
	}
	// A stored count is not a size to allocate. The unread tail has to hold
	// every node, the fixed part and each name's bytes, or this is the short
	// file a read that ran out halfway would refuse. Checked before reserve:
	// that asks for a block per 65536 nodes, up to MAX_BLOCKS, about 12 GB,
	// for a count the file does not hold.
	if !nodes_fit(r.data, r.at, count) {
		return {}, "the scan kept of this place is cut short", false
	}
	if scan.tree_init(t, 1) != nil || scan.reserve(t, count) != nil {
		scan.tree_destroy(t)
		return {}, "no room to read the scan kept of this place", false
	}
	w := scan.writer(t, 0)
	for i in 0 ..< count {
		parent := take_u32(&r)
		flags := transmute(scan.Node_Flags)take_u8(&r)
		disk := take_u64(&r)
		name := string(take(&r, int(take_u16(&r))))
		if !r.ok || parent >= count {
			scan.tree_destroy(t)
			return {}, "the scan kept of this place is cut short", false
		}
		// walk.join spells a child by its name onto its directory. A separator
		// or a NUL in that name leaves the directory: "../../.ssh" is not an
		// entry in it. The root's name is the place path, so it is the one
		// name that holds separators.
		if !name_fits(name, i == root) {
			scan.tree_destroy(t)
			return {}, "the scan kept of this place holds a name that is not one entry", false
		}
		n := scan.node(t, i)
		n.parent = parent
		n.disk = disk
		n.name = scan.intern(&w, name)
		scan.node_publish(n, flags | {.Used, .Settled})
	}
	if !take_links(&r, t, count) {
		scan.tree_destroy(t)
		return {}, "the scan kept of this place is cut short", false
	}
	// Bytes past the last link: the count does not match what was written.
	if r.at != len(r.data) {
		scan.tree_destroy(t)
		return {}, "the scan kept of this place is longer than it says", false
	}
	// baseline_save stores the scan's parent renumbered into this file's order
	// and does not make a parent precede its child. A walk claims a directory
	// before its entries, but a record kept by its own number can sit below a
	// directory numbered above it, and a root or an orphan stores its own
	// index. Comparing the two indices would refuse files this writer emits.
	// A cycle is a chain of parents that returns to a node.
	if chain_loops(t, count) {
		scan.tree_destroy(t)
		return {}, "the scan kept of this place loops", false
	}
	sync.atomic_store(&t.root, root)
	return cursor, "", true
}

// Read the links into t.linked; false when they run short or name no node.
@(private = "file")
take_links :: proc(r: ^Reader, t: ^scan.Tree, nodes: u32) -> bool {
	count := take_u32(r)
	if !r.ok || int(count) > (len(r.data) - r.at) / LINK_SIZE {
		return false
	}
	t.linked = make([dynamic]scan.Link, 0, count, t.allocator)
	for _ in 0 ..< count {
		l := scan.Link {
			node = take_u32(r),
			id = {device = take_u64(r), inode = take_u64(r), upper = take_u64(r)},
		}
		if !r.ok || l.node >= nodes {
			return false
		}
		append(&t.linked, l)
	}
	return true
}

@(private = "file")
Reader :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

@(private = "file")
take :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || r.at + n > len(r.data) {
		r.ok = false
		return nil
	}
	defer r.at += n
	return r.data[r.at:][:n]
}

@(private = "file")
take_u8 :: proc(r: ^Reader) -> u8 {
	b := take(r, 1)
	return b[0] if r.ok else 0
}

@(private = "file")
take_u16 :: proc(r: ^Reader) -> u16 {
	v, _ := endian.get_u16(take(r, 2), .Little)
	return v
}

@(private = "file")
take_u32 :: proc(r: ^Reader) -> u32 {
	v, _ := endian.get_u32(take(r, 4), .Little)
	return v
}

@(private = "file")
take_u64 :: proc(r: ^Reader) -> u64 {
	v, _ := endian.get_u64(take(r, 8), .Little)
	return v
}

// What a node takes beside its name: parent, flags, size, name length.
@(private = "file")
NODE_FIXED :: 4 + 1 + 8 + 2

// What the links' count takes, after the last node.
@(private = "file")
LINK_COUNT :: 4

// What a link takes: its node, then the file's device, inode and upper half.
@(private = "file")
LINK_SIZE :: 4 + 3 * 8

// The unread tail from at holds count nodes, each NODE_FIXED bytes plus its name,
// and then the links' count that ends the file. A count that cannot fit even with
// empty names is short, and is refused before the names are walked, so a huge
// count does not become a huge loop. The links themselves are bounded by their
// own count in take_links, before anything is reserved for them.
@(private = "file")
nodes_fit :: proc(data: []u8, at: int, count: u32) -> bool {
	if at < 0 || at > len(data) {
		return false
	}
	remain := len(data) - at
	if remain < LINK_COUNT || int(count) > (remain - LINK_COUNT) / NODE_FIXED {
		return false
	}
	pos := at
	for _ in 0 ..< count {
		if pos > len(data) - NODE_FIXED {
			return false
		}
		n, ok := endian.get_u16(data[pos + NODE_FIXED - 2:], .Little)
		if !ok || int(n) > len(data) - (pos + NODE_FIXED) {
			return false
		}
		pos += NODE_FIXED + int(n)
	}
	return len(data) - pos >= LINK_COUNT
}

// Whether name can be stored for one node. The root's name is the place path,
// separators and all; every other name is joined onto its parent, so a
// separator or a NUL in it is another path, not a name.
@(private = "file")
name_fits :: proc(name: string, root: bool) -> bool {
	for b in transmute([]u8)name {
		if b == 0 || (!root && (b == '/' || b == '\\')) {
			return false
		}
	}
	return true
}

// chain_loops reports a chain of parents that returns to a node. A node that
// holds itself is a root or an orphan, where the chain ends, not a loop. One
// byte a node: unseen, on the chain now, or settled. The chain is followed
// again to settle it, which needs no second array.
@(private = "file")
chain_loops :: proc(t: ^scan.Tree, count: u32) -> bool {
	state := make([]u8, count)
	defer delete(state)
	if len(state) != int(count) {
		return true
	}
	for start in 0 ..< count {
		if state[start] != 0 {
			continue
		}
		cur := start
		looped := false
		for {
			if state[cur] == 2 {
				break
			}
			if state[cur] == 1 {
				looped = true
				break
			}
			state[cur] = 1
			parent := scan.node(t, cur).parent
			if parent == cur {
				break
			}
			if parent >= count {
				return true
			}
			cur = parent
		}
		if looped {
			return true
		}
		cur = start
		for state[cur] == 1 {
			state[cur] = 2
			parent := scan.node(t, cur).parent
			if parent == cur {
				break
			}
			cur = parent
		}
	}
	return false
}

@(private = "file")
Writer :: struct {
	out: []u8,
	at:  int,
}

@(private = "file")
put :: proc(w: ^Writer, b: []u8) {
	copy(w.out[w.at:], b)
	w.at += len(b)
}

@(private = "file")
put_u8 :: proc(w: ^Writer, v: u8) {
	w.out[w.at] = v
	w.at += 1
}

@(private = "file")
put_u16 :: proc(w: ^Writer, v: u16) {
	endian.put_u16(w.out[w.at:], .Little, v)
	w.at += 2
}

@(private = "file")
put_u32 :: proc(w: ^Writer, v: u32) {
	endian.put_u32(w.out[w.at:], .Little, v)
	w.at += 4
}

@(private = "file")
put_u64 :: proc(w: ^Writer, v: u64) {
	endian.put_u64(w.out[w.at:], .Little, v)
	w.at += 8
}
