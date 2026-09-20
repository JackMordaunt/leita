package main

import "core:sync"
import "core:time"

import "ntfs"
import "scan"

/*
Owns the tree and everything derived from it.

Between the readers and the UI there has to be somewhere the graph work happens.
Ancestors are shared between readers, so charging one from several threads would need
atomics on every total; giving a single thread sole ownership removes that entirely.
The UI is kept out for the opposite reason: its frame must cost the same whatever the
volume holds, so it reads a published snapshot rather than the tree.

This runs as fast as it can rather than on a clock. Each pass folds whatever the
readers have finished with, charges it, and publishes. If a pass takes longer than a
frame the UI simply draws the previous answer.
*/
Builder :: struct {
	table:      ^ntfs.Mft,
	tree:       ^scan.Tree,
	out:        ^scan.Publisher,
	mount:      string,
	scanning:   ^b32, // cleared by the reader thread when the table is finished
	started:    time.Tick,
	projection: ntfs.Projection,
	roll:       Rollup,
	done:       b32,
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

		if ntfs.mft_ready(b.table) {
			b.projection.root_name = b.mount
			builder_pass(b, exact = finished)
		}
		if finished {
			return
		}
	}
}

// One pass: fold what is newly readable, charge it, rank it, publish it.
@(private = "file")
builder_pass :: proc(b: ^Builder, exact: bool) {
	if exact {
		// A record settled mid-scan misses whatever extension records added to it
		// afterwards, so the last pass redoes every one of them. The tree is not
		// emptied first: a UI resolves the paths of the rows it drew from it, and an
		// empty tree would hand that thread a truncated one. Redoing a projection
		// rewrites each slot where it already sat.
		ntfs.projection_reset(&b.projection)
	}
	if err := ntfs.to_tree(b.table, b.tree, &b.projection); err != nil {
		return
	}
	if exact {
		resize(&b.roll.totals, int(b.tree.count))
		for i in 0 ..< len(b.roll.totals) {
			b.roll.totals[i] = 0
		}
		clear(&b.roll.pending)
		roll_up(b.tree, b.roll.totals[:])
	} else {
		rollup_advance(&b.roll, b.tree, b.projection.fresh[:])
	}
	top: [scan.TOP_ROWS]Sized
	count := rank(b.tree, b.roll.totals[:], top[:])

	s := scan.Snapshot {
		count    = count,
		nodes    = b.tree.nodes_done,
		bytes    = b.tree.bytes_done,
		pending  = len(b.roll.pending),
		elapsed  = time.duration_milliseconds(time.tick_since(b.started)),
		complete = exact,
	}
	for i in 0 ..< count {
		s.rows[i] = {
			node  = top[i].record,
			bytes = top[i].bytes,
		}
	}
	scan.publish(b.out, s)
}
