package main

import "core:slice"

import "scan"

/*
Directory totals maintained across frames.

Recomputing from scratch costs the whole tree every time, which is what made the
simulated UI's frames climb from 14 ms to 50. Totals are never cleared here; each
node is charged once, and a frame costs what changed rather than what exists.

`pending` holds nodes that could not be charged yet because an ancestor had not been
published. They are retried each frame and drain away as the scan fills in.
*/
Rollup :: struct {
	totals:  [dynamic]u64,
	pending: [dynamic]u32,
}

rollup_destroy :: proc(r: ^Rollup) {
	delete(r.totals)
	delete(r.pending)
	r^ = {}
}

// Charge everything newly settled, and retry what could not be charged before.
rollup_advance :: proc(r: ^Rollup, t: ^scan.Tree, fresh: []u32) {
	if int(t.count) > len(r.totals) {
		resize(&r.totals, int(t.count))
	}
	retry := slice.clone(r.pending[:], context.temp_allocator)
	clear(&r.pending)
	for i in retry {
		charge(r, t, i)
	}
	for i in fresh {
		charge(r, t, i)
	}
}

/*
Charge a node to every ancestor at once, or to none of them.

Stopping halfway would mean resuming from the middle once the rest of the chain
arrives, which needs a record per node of how far it got. Waiting costs a re-walk
instead, and the chain is a handful of links.

Every node on the way up must be settled, not merely present: an unsettled one is
rooted at itself for now and would look like the top of the tree.
*/
@(private = "file")
charge :: proc(r: ^Rollup, t: ^scan.Tree, i: u32) {
	n := scan.node(t, i)
	if .Extra_Name in n.flags {
		return // another name for a file already charged
	}
	chain: [64]u32
	depth := 0
	cur := i
	for depth < len(chain) {
		c := scan.node(t, cur)
		if .Settled not_in c.flags {
			append(&r.pending, i)
			return
		}
		if c.parent == cur {
			break // a root, or an orphan: the chain ends here
		}
		chain[depth] = c.parent
		depth += 1
		cur = c.parent
	}
	if .Directory in n.flags {
		r.totals[i] += n.disk
	}
	for j in 0 ..< depth {
		r.totals[chain[j]] += n.disk
	}
}
