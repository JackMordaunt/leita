package survey

import "../scan"

/*
Directory totals maintained across passes.

Recomputing from scratch costs the whole tree every time, which is what made the
simulated UI's frames climb from 14 ms to 50. Totals are never cleared here; each node
is charged once and stays charged.

Which nodes those are is read off the tree rather than told: a reader says a node is
settled, and `charged` remembers whether this has acted on it yet. That keeps the
arithmetic the same whichever reader ran, and a node whose ancestors have not arrived
is simply left unmarked and reached again next pass.

Only directories have totals, and they are few: 301,994 of 2,581,257 nodes in one
home directory, measured 2026-10-08. So totals are kept by directory number rather
than by node. A directory is numbered the first time it is charged, and its number
lives in its node's `dir`, which no reader writes. A tree is therefore rolled up by one
Rollup at a time.
*/
Rollup :: struct {
	tree:       ^scan.Tree, // what this rolls up, from the first pass on
	seen:       u32, // slots looked at so far; nothing at or past this is charged
	dir_totals: [dynamic]u64, // by directory number; read with `total`
	charged:    [dynamic]u64, // one bit per node
	pending:    int, // settled nodes still waiting on an ancestor, as of the last pass
	// Set before the first pass to also index each directory's children, for a
	// caller that browses the tree rather than ranking all of it. A node joins its
	// parent's list when it is charged, so a list holds exactly what the totals do.
	linked:     bool,
	first:      [dynamic]u32, // by directory number: its most recently charged child, or NONE
	next:       [dynamic]u32, // by node: the sibling charged before it, or NONE
	// Nodes taken out of the tree after it was read, a bit each: whatever is under
	// one is neither charged nor listed, now or after a restatement.
	gone:       [dynamic]u64,
}

// NONE ends a child list.
NONE :: max(u32)

rollup_destroy :: proc(r: ^Rollup) {
	delete(r.dir_totals)
	delete(r.charged)
	delete(r.first)
	delete(r.next)
	delete(r.gone)
	r^ = {}
}

// The children of `dir` charged so far, in no order.
Children :: struct {
	r:   ^Rollup,
	cur: u32,
}

children :: proc(r: ^Rollup, dir: u32) -> Children {
	if !r.linked || dir >= r.seen {
		return {r, NONE}
	}
	d := scan.node(r.tree, dir).dir
	if d == 0 {
		return {r, NONE}
	}
	return {r, r.first[d - 1]}
}

// What node `i` holds as charged so far: 0 for a file, or for a directory nothing has
// been charged to yet.
total :: proc(r: ^Rollup, i: u32) -> u64 {
	if i >= r.seen {
		return 0
	}
	d := scan.node(r.tree, i).dir
	if d == 0 {
		return 0
	}
	return r.dir_totals[d - 1]
}

next_child :: proc(it: ^Children) -> (node: u32, ok: bool) {
	if it.cur == NONE {
		return NONE, false
	}
	node = it.cur
	it.cur = it.r.next[node]
	return node, true
}

// Forget every total, for a reader that has restated what it already said.
rollup_restate :: proc(r: ^Rollup) {
	for i in 0 ..< len(r.dir_totals) {
		r.dir_totals[i] = 0
	}
	for i in 0 ..< len(r.charged) {
		r.charged[i] = 0
	}
	for i in 0 ..< len(r.first) {
		r.first[i] = NONE
	}
	for i in 0 ..< len(r.next) {
		r.next[i] = NONE
	}
	r.pending = 0
}

// Charge every settled node not charged already.
rollup_advance :: proc(r: ^Rollup, t: ^scan.Tree) {
	assert(r.tree == nil || r.tree == t, "one rollup rolling up two trees")
	r.tree = t
	count := int(scan.slots(t))
	if words := (count + 63) / 64; words > len(r.charged) {
		resize(&r.charged, words)
	}
	if r.linked && count > len(r.next) {
		from := len(r.next)
		resize(&r.next, count)
		for i in from ..< count {
			r.next[i] = NONE
		}
	}
	r.seen = max(r.seen, u32(count))
	r.pending = 0
	for i in 0 ..< u32(count) {
		if marked(r.charged[:], i) {
			continue
		}
		f := scan.node_flags(scan.node(t, i))
		if .Used not_in f || .Settled not_in f {
			continue
		}
		if charge(r, t, i) {
			mark(r.charged[:], i)
		} else {
			r.pending += 1
		}
	}
}

/*
Charge a node to every ancestor at once, or to none of them.

Stopping halfway would mean resuming from the middle once the rest of the chain
arrives, which needs a record per node of how far it got. Waiting costs a re-walk
instead, and the chain is a handful of links.

Every node on the way up must be settled, not merely present: an unsettled one is
rooted at itself for now and would look like the top of the tree. Returning false
leaves it uncharged, which is the whole of what has to be remembered about it.
*/
@(private)
charge :: proc(r: ^Rollup, t: ^scan.Tree, i: u32) -> bool {
	n := scan.node(t, i)
	flags := scan.node_flags(n)
	if .Extra_Name in flags {
		return true // another name for a file already charged
	}
	chain: [64]u32
	depth := 0
	cur := i
	for depth < len(chain) {
		c := scan.node(t, cur)
		if .Settled not_in scan.node_flags(c) {
			return false
		}
		if is_forgotten(r, cur) {
			return true // under something forgotten: there is nothing to charge
		}
		// A root, an orphan, or a parent that leaves the tree: the chain ends here.
		// The batch roll-up and path rebuilding both stop on the same conditions, and
		// this is the one that runs while a reader is still filling slots in.
		if c.parent == cur || c.parent >= r.seen {
			break
		}
		chain[depth] = c.parent
		depth += 1
		cur = c.parent
	}
	// Numbered before indexing, since numbering can grow the array being indexed.
	if .Directory in flags {
		d := number(r, i)
		r.dir_totals[d] += n.disk
	}
	for j in 0 ..< depth {
		d := number(r, chain[j])
		r.dir_totals[d] += n.disk
	}
	if r.linked && depth > 0 {
		p := number(r, n.parent)
		r.next[i] = r.first[p]
		r.first[p] = i
	}
	return true
}

// The number of the directory at node `i`, given one now if it has none.
@(private)
number :: proc(r: ^Rollup, i: u32) -> u32 {
	n := scan.node(r.tree, i)
	if n.dir == 0 {
		append(&r.dir_totals, 0)
		if r.linked {
			append(&r.first, NONE)
		}
		n.dir = u32(len(r.dir_totals))
	}
	return n.dir - 1
}

/*
Take a node and everything under it out of the totals and the child lists, for a
caller that has removed it from the disk after the reader found it.

Whatever its ancestors were charged on its account comes off them again: its own
total for a directory, which already holds everything under it that was charged,
or its size for a file. Anything under it the reader settles later finds it gone
and is charged nowhere.
*/
forget :: proc(r: ^Rollup, t: ^scan.Tree, i: u32) {
	if i >= r.seen || is_forgotten(r, i) {
		return
	}
	n := scan.node(t, i)
	flags := scan.node_flags(n)
	taken: u64
	switch {
	case .Directory in flags:
		taken = total(r, i)
	case marked(r.charged[:], i) && .Extra_Name not_in flags:
		taken = n.disk
	}
	cur := i
	for _ in 0 ..< 64 {
		c := scan.node(t, cur)
		if c.parent == cur || c.parent >= r.seen {
			break
		}
		cur = c.parent
		d := number(r, cur)
		r.dir_totals[d] -= min(taken, r.dir_totals[d])
	}
	if r.linked && n.parent != i && n.parent < r.seen {
		unlink(r, number(r, n.parent), i)
	}
	if words := int(i) / 64 + 1; words > len(r.gone) {
		resize(&r.gone, words)
	}
	mark(r.gone[:], i)
}

// removed is whether i, or anything above it, has been forgotten.
removed :: proc(r: ^Rollup, t: ^scan.Tree, i: u32) -> bool {
	if len(r.gone) == 0 {
		return false
	}
	cur := i
	for _ in 0 ..< 64 {
		if is_forgotten(r, cur) {
			return true
		}
		c := scan.node(t, cur)
		if c.parent == cur || c.parent >= r.seen {
			return false
		}
		cur = c.parent
	}
	return false
}

@(private)
is_forgotten :: proc(r: ^Rollup, i: u32) -> bool {
	return int(i >> 6) < len(r.gone) && marked(r.gone[:], i)
}

// unlink takes node i out of the child list of the directory numbered dir.
@(private)
unlink :: proc(r: ^Rollup, dir, i: u32) {
	if r.first[dir] == i {
		r.first[dir] = r.next[i]
		return
	}
	for c := r.first[dir]; c != NONE; c = r.next[c] {
		if r.next[c] == i {
			r.next[c] = r.next[i]
			return
		}
	}
}

@(private)
marked :: proc(b: []u64, i: u32) -> bool {
	return b[i >> 6] & (1 << uint(i & 63)) != 0
}

@(private)
mark :: proc(b: []u64, i: u32) {
	b[i >> 6] |= 1 << uint(i & 63)
}
