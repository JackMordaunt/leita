package main

import "scan"

/*
Directory totals maintained across passes.

Recomputing from scratch costs the whole tree every time, which is what made the
simulated UI's frames climb from 14 ms to 50. Totals are never cleared here; each node
is charged once and stays charged.

Which nodes those are is read off the tree rather than told: a reader says a node is
settled, and `charged` remembers whether this has acted on it yet. That keeps the
arithmetic the same whichever reader ran, and a node whose ancestors have not arrived
is simply left unmarked and reached again next pass.
*/
Rollup :: struct {
	totals:  [dynamic]u64,
	charged: [dynamic]u64, // one bit per node
	pending: int, // settled nodes still waiting on an ancestor, as of the last pass
}

rollup_destroy :: proc(r: ^Rollup) {
	delete(r.totals)
	delete(r.charged)
	r^ = {}
}

// Forget every total, for a reader that has restated what it already said.
rollup_restate :: proc(r: ^Rollup) {
	for i in 0 ..< len(r.totals) {
		r.totals[i] = 0
	}
	for i in 0 ..< len(r.charged) {
		r.charged[i] = 0
	}
	r.pending = 0
}

// Charge every settled node not charged already.
rollup_advance :: proc(r: ^Rollup, t: ^scan.Tree) {
	count := int(scan.slots(t))
	if count > len(r.totals) {
		resize(&r.totals, count)
	}
	if words := (count + 63) / 64; words > len(r.charged) {
		resize(&r.charged, words)
	}
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
		// A root, an orphan, or a parent that leaves the tree: the chain ends here.
		// The batch roll-up and path rebuilding both stop on the same conditions, and
		// this is the one that runs while a reader is still filling slots in.
		if c.parent == cur || c.parent >= u32(len(r.totals)) {
			break
		}
		chain[depth] = c.parent
		depth += 1
		cur = c.parent
	}
	if .Directory in flags {
		r.totals[i] += n.disk
	}
	for j in 0 ..< depth {
		r.totals[chain[j]] += n.disk
	}
	return true
}

@(private)
marked :: proc(b: []u64, i: u32) -> bool {
	return b[i >> 6] & (1 << uint(i & 63)) != 0
}

@(private)
mark :: proc(b: []u64, i: u32) {
	b[i >> 6] |= 1 << uint(i & 63)
}
