package ntfs

import "core:mem"
import "core:sync"

import "../scan"

/*
Carried between projections so repeating one is cheap and adds nothing twice.

`settled` remembers which records have been folded in for good. A record is only
finished with once its parent reference is final, because a parent not yet published
may still turn out to hold the name, and a node written before then would be left
rooted at itself forever.

`fresh` is what became final since the last call, which is the only work an
incremental consumer has to do.

`under` is what keeps a subtree to itself. Rooting the tree at a record cuts it
from its parents, but every other record of the volume would still be a used node
beside it, and whatever reads the tree's nodes rather than the root's descendants,
a search or a list of the largest files, would answer for the whole volume.
*/
Projection :: struct {
	// What to call the root. NTFS names it ".", which says nothing in a path, and the
	// caller is the one that knows where the volume is mounted. Setting it here rather
	// than afterwards keeps a watching thread from ever catching the placeholder.
	root_name:   string,
	root:        scan.Name, // root_name, copied into the tree once
	// The record to root the tree at, found by the caller without reading the table
	// at all. RECORD_ROOT, the volume's own root, unless set: a subtree the caller
	// could not address directly still gets a true tree, just the whole volume's.
	root_record: u32,
	links_done: int,
	settled:    []u64, // one bit per record
	// With a root_record other than the volume's own, whether each record is under
	// it. Nil for the whole volume, where every record is.
	under:      []Under,
	chain:      [dynamic]u32, // the records being followed up to one already decided
	allocator:  mem.Allocator,
}

/*
Whether a record is under the chosen root.

A record is decided once every link from it up to the root, or up to some other
record rooted at itself, is final, and then it never changes. Until then it waits,
because a parent not yet read may still turn out to be the way in.
*/
@(private)
Under :: enum u8 {
	Undecided,
	Yes,
	No,
	Waiting, // a link above it is not final yet; asked again on the next call
	Following, // on the chain being followed now, so meeting it again is a loop
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
	// What was decided stays true, but redoing every record means deciding it again
	// too, so the final answer owes nothing to a frame taken while the table filled.
	for &u in p.under {
		u = .Undecided
	}
	p.links_done = 0
}

projection_destroy :: proc(p: ^Projection) {
	delete(p.settled, p.allocator)
	delete(p.under, p.allocator)
	delete(p.chain)
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
// A non-directory record with more than one name. No logical length is kept
// on this path, so Allocated is not set. An extra name is Exact from
// Node_Flag.Extra_Name, not from this account.
link_account :: proc(links: u16, allocated: u64, directory: bool) -> scan.Account {
	if directory || links <= 1 {
		return {}
	}
	return {
		links = u32(links),
		shared = allocated,
		known = {.Links, .Reclaim, .Shared},
	}
}

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
	// Found outside the table (scan/target_windows.odin asks Windows for it, not
	// the MFT), so a volume that shrank since is checked rather than trusted.
	root := p.root_record if p.root_record != 0 && int(p.root_record) < len(m.entries) else RECORD_ROOT
	if p.settled == nil {
		p.allocator = t.allocator
		bits, err := make([]u64, (len(m.entries) + 63) / 64, p.allocator)
		if err != nil {
			return .Out_Of_Memory
		}
		p.settled = bits
		if root != RECORD_ROOT {
			under, under_err := make([]Under, len(m.entries), p.allocator)
			if under_err != nil {
				return .Out_Of_Memory
			}
			p.under = under
			p.chain = make([dynamic]u32, p.allocator)
		}
		// Names stay in the table's arenas and nodes borrow them, so the tree has to be
		// able to read those arenas. Once per tree, which is when `settled` is made.
		for &s in m.sinks {
			scan.lend(t, &s.names) or_return
		}
		p.root = scan.name_copy(t, p.root_name)
	}

	if p.under != nil {
		decide(m, p, root)
	}

	used, bytes: u64

	for i in 0 ..< u32(len(m.entries)) {
		if marked(p.settled, i) {
			used += 1
			bytes += m.entries[i].allocated
			continue
		}
		// Not in the tree at all, rather than in it beside the root: that is what
		// keeps a search, or anything else that reads every node, to the subtree.
		if p.under != nil && p.under[i] != .Yes {
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
		n.name = borrow(t, e.name) or_return
		n.disk = e.allocated

		flags := scan.Node_Flags{.Used}
		if .Directory in e.flags {
			flags |= {.Directory}
		}
		if .Reparse_Point in e.attributes {
			flags |= {.Reparse}
		}
		parent, settled := entry_parent_settled(m, i)
		// The chosen root is rooted at itself, same as the volume's own root
		// naturally is, so a subtree reads as whole as a volume does: nothing
		// above it in the table reaches the tree through a parent link.
		if i == root {
			parent, settled = i, true
		}
		n.parent = parent
		if settled {
			flags |= {.Settled}
			mark(p.settled, i)
		}
		if acct := link_account(e.link_count, e.allocated, .Directory in e.flags); acct.known != nil {
			// A later pass rewrites the same slot. The first publication stands;
			// a failed claim is out of memory only when nothing was stored.
			if !scan.account_set(t, i, acct) {
				if _, published := scan.account_of(t, i); !published {
					return .Out_Of_Memory
				}
			}
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
		// A name in a directory outside the subtree is not one of its paths, though
		// the file itself may be; one inside is, though the file may live elsewhere.
		if p.under != nil && (int(l.parent) >= len(p.under) || p.under[l.parent] != .Yes) {
			continue
		}
		index := u32(len(m.entries) + p.links_done + k)
		n := scan.node(t, index)
		n.parent = l.parent
		n.name = borrow(t, l.name) or_return
		n.disk = m.entries[l.record].allocated
		scan.node_publish(n, {.Used, .Settled, .Extra_Name})
	}
	p.links_done = links

	sync.atomic_store(&t.root, root)
	if p.root_name != "" {
		scan.node(t, root).name = p.root
	}
	sync.atomic_store(&t.nodes_done, used)
	sync.atomic_store(&t.bytes_done, bytes)
	return .None
}

/*
Decide, for every record not yet decided, whether it is under `root`.

Each record is followed up its parents only until it meets one already decided, and
everything met on the way takes that answer, so no record is followed through
twice: one call is O(records) however deep the tree runs, where following every
record to the top would be O(records * depth). Records waiting on a link that is
not final are asked again next call, from where they stopped. Only the subtree's
own links matter: a record is in once its chain reaches `root`, whatever lies above.
*/
@(private)
decide :: proc(m: ^Mft, p: ^Projection, root: u32) {
	for &u in p.under {
		if u == .Waiting {
			u = .Undecided
		}
	}
	p.under[root] = .Yes
	for i in 0 ..< u32(len(m.entries)) {
		if p.under[i] == .Undecided {
			follow(m, p, i)
		}
	}
}

// Follow one record up to an answer and give it to every record on the way.
@(private)
follow :: proc(m: ^Mft, p: ^Projection, from: u32) {
	clear(&p.chain)
	answer := Under.Waiting
	r := from
	for {
		switch p.under[r] {
		case .Yes, .No, .Waiting:
			answer = p.under[r]
		case .Following:
			// A loop of parents, which only a damaged table holds, never reaches root.
			answer = .No
		case .Undecided:
			e := &m.entries[r]
			// Unpublished or still nameless, its parent may yet change.
			if !entry_published(e) || e.name == "" {
				break
			}
			parent, settled := entry_parent_settled(m, r)
			if !settled {
				break
			}
			p.under[r] = .Following
			append(&p.chain, r)
			// Rooted at itself, and not the root: the volume's own top, or an orphan.
			if parent == r {
				answer = .No
				break
			}
			r = parent
			continue
		}
		break
	}
	for c in p.chain {
		p.under[c] = answer
	}
}

// The tree's handle on a name in one of the table's arenas. Every name the table holds
// is in one, so failing here means a name came from somewhere else.
@(private)
borrow :: proc(t: ^scan.Tree, s: string) -> (scan.Name, scan.Error) {
	name, ok := scan.name_in(t, s)
	if !ok {
		return {}, .Out_Of_Memory
	}
	return name, .None
}

@(private)
marked :: proc(b: []u64, i: u32) -> bool {
	return b[i >> 6] & (1 << uint(i & 63)) != 0
}

@(private)
mark :: proc(b: []u64, i: u32) {
	b[i >> 6] |= 1 << uint(i & 63)
}
