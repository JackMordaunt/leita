package ntfs

import "core:mem"

import "../scan"

/*
Carried between projections so repeating one is cheap and adds nothing twice.

`settled` remembers which records have been folded in for good. A record is only
finished with once its parent reference is final, because a parent not yet published
may still turn out to hold the name, and a node written before then would be left
rooted at itself forever.

`fresh` is what became final since the last call, which is the only work an
incremental consumer has to do.
*/
Projection :: struct {
	// What to call the root. NTFS names it ".", which says nothing in a path, and the
	// caller is the one that knows where the volume is mounted. Setting it here rather
	// than afterwards keeps a watching thread from ever catching the placeholder.
	root_name:  string,
	links_done: int,
	settled:    []u64, // one bit per record
	allocator:  mem.Allocator,
}

/*
Forget what has been projected, so the next call redoes every record.

A settled record is skipped on later calls, which is what makes a frame cheap, but it
also means its size is never re-read. Extension records add to a base record after it
was published, and a badly fragmented file can hold most of its allocation there, so
a projection taken during a scan under-reports them. Call this once the scan has
finished to get an exact answer.
*/
projection_reset :: proc(p: ^Projection) {
	for i in 0 ..< len(p.settled) {
		p.settled[i] = 0
	}
	p.links_done = 0
}

projection_destroy :: proc(p: ^Projection) {
	delete(p.settled, p.allocator)
	p^ = {}
}

/*
Project a table into the normalised tree, or bring an earlier projection up to date.

The table stays the native form and keeps what only NTFS has: record and sequence
numbers, per-stream allocation, the resident-file accounting. A caller wanting the
truth reads it directly. This is the lossy view everything above the reader shares
with the other readers.

Record numbers become node indices unchanged, so the tree has a slot per record slot,
including the dead ones. That wastes the slots but keeps every parent reference valid
without a second mapping, and a dead slot is simply not marked used.

Safe to call while a scan runs: only records the reader has finished with are read,
and names are borrowed from the table's arenas rather than copied, so repeating this
allocates nothing. The table must therefore outlive the tree.
*/
to_tree :: proc(m: ^Mft, t: ^scan.Tree, p: ^Projection) -> scan.Error {
	// Hard links are merged into the table in one go at the very end, so reading them
	// before that would race the reader appending them, and would size the tree from
	// a count that was still growing.
	links := len(m.links) if mft_complete(m) else 0

	// Records take slot per slot, extra names the range directly above them. Sizing
	// for both up front is what lets a replay land on the same slots as the pass
	// before it, so repeating one never has to empty the tree first.
	if err := scan.reserve(t, u32(len(m.entries) + links)); err != nil {
		return err
	}
	if p.settled == nil {
		p.allocator = t.allocator
		bits, err := make([]u64, (len(m.entries) + 63) / 64, p.allocator)
		if err != nil {
			return .Out_Of_Memory
		}
		p.settled = bits
	}

	used, bytes: u64

	for i in 0 ..< u32(len(m.entries)) {
		if marked(p.settled, i) {
			used += 1
			bytes += m.entries[i].allocated
			continue
		}
		e := &m.entries[i]
		// Only records the reader has finished with, so a name is never half written.
		if !entry_published(e) || e.name == "" {
			continue
		}
		n := scan.node(t, i)
		// Borrowed, not copied: names live in the table's arenas and stay put for its
		// life, so repeating this projection allocates nothing.
		n.name = e.name
		n.size = e.size
		n.disk = e.allocated

		flags := scan.Node_Flags{.Used}
		if .Directory in e.flags {
			flags |= {.Directory}
		}
		if .Reparse_Point in e.attributes {
			flags |= {.Reparse}
		}
		parent, settled := entry_parent_settled(m, i)
		n.parent = parent
		if settled {
			flags |= {.Settled}
			mark(p.settled, i)
		}
		// Last, so a builder watching this tree never sees a node before its parent.
		scan.node_publish(n, flags)
		used += 1
		bytes += e.allocated
	}

	// Extra names for a file already counted. They belong in the tree so a file can
	// be found at every path it has, but their bytes must not be counted twice. Each
	// sits at its ordinal above the record range, so a link written twice is written
	// to the same slot. Links are merged when the scan ends, so this is empty
	// until then.
	for l, k in m.links[p.links_done:links] {
		index := u32(len(m.entries) + p.links_done + k)
		n := scan.node(t, index)
		n.parent = l.parent
		n.name = l.name
		n.disk = m.entries[l.record].allocated
		n.size = m.entries[l.record].size
		scan.node_publish(n, {.Used, .Settled, .Extra_Name})
	}
	p.links_done = links

	t.root = RECORD_ROOT
	if p.root_name != "" {
		scan.node(t, RECORD_ROOT).name = p.root_name
	}
	t.nodes_done = used
	t.bytes_done = bytes
	return .None
}

@(private)
marked :: proc(b: []u64, i: u32) -> bool {
	return b[i >> 6] & (1 << uint(i & 63)) != 0
}

@(private)
mark :: proc(b: []u64, i: u32) {
	b[i >> 6] |= 1 << uint(i & 63)
}
