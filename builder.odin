package main

import "core:sync"
import "core:time"

import "scan"
import "survey"

/*
Owns everything derived from the tree.

Between the readers and the UI there has to be somewhere the graph work happens.
Ancestors are shared between readers, so charging one from several threads would need
atomics on every total; giving a single thread sole ownership removes that entirely.
The UI is kept out for the opposite reason: its frame must cost the same whatever the
volume holds, so it reads a published snapshot rather than the tree.

Nothing here knows which reader is filling the tree. A reader settles nodes and, if it
has to correct itself, restates; those two are the whole of what passes between them.

This runs as fast as it can rather than on a clock. Each pass charges whatever is newly
settled, ranks it, and publishes. If a pass takes longer than a frame the UI simply
draws the previous answer.
*/
Builder :: struct {
	tree:     ^scan.Tree,
	out:      ^Publisher,
	scanning: ^b32, // cleared once nothing is filling the tree any more
	started:  time.Tick,
	roll:     survey.Rollup,
	done:     b32,
}

builder_run :: proc(b: ^Builder) {
	// The totals outlive this thread: the caller reads them once the scan is over,
	// so ownership stays there.
	defer sync.atomic_store(&b.done, true)

	for {
		// Read this first: if the scan ends between here and the pass below, the pass
		// still sees everything and this loop takes one more turn rather than missing
		// the last of it.
		finished := !bool(sync.atomic_load(b.scanning))
		builder_pass(b, complete = finished)
		if finished {
			return
		}
	}
}

// One pass: charge what is newly settled, rank it, publish it.
@(private = "file")
builder_pass :: proc(b: ^Builder, complete: bool) {
	// A reader that corrects itself invalidates every total drawn from what it said
	// before, so those start again rather than being added to. It restates only once
	// the rewrite is finished, so one pass over the tree is enough to replace them.
	if scan.taken_restated(b.tree) {
		survey.rollup_restate(&b.roll)
	}
	survey.rollup_advance(&b.roll, b.tree)

	top: [TOP_N]Sized
	count := rank(b.tree, b.roll.totals[:], top[:])

	s := Snapshot {
		count    = count,
		nodes    = b.tree.nodes_done,
		bytes    = b.tree.bytes_done,
		pending  = b.roll.pending,
		elapsed  = time.duration_milliseconds(time.tick_since(b.started)),
		complete = complete,
	}
	for i in 0 ..< count {
		s.rows[i] = {
			node  = top[i].record,
			bytes = top[i].bytes,
		}
	}
	publish(b.out, s)
}
