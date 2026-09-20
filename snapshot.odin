package main

import "core:sync"

Row :: struct {
	node:  u32,
	bytes: u64,
}

// What a UI draws: a fixed number of rows and a few counters, whatever the size of
// the volume behind it.
Snapshot :: struct {
	rows:     [TOP_N]Row,
	count:    int,
	nodes:    u64, // records folded so far
	bytes:    u64,
	pending:  int, // nodes waiting on an ancestor
	elapsed:  f64, // milliseconds since the scan began
	complete: bool,
}

/*
Hands a snapshot from the thread building it to the thread drawing it.

A sequence number is odd only while a write is in flux. A reader copies, then checks
the number is unchanged and even. A frame therefore never waits on a build: it gets
the new answer, or keeps the one it had.
*/
Publisher :: struct {
	seq:  u32,
	data: Snapshot,
}

publish :: proc(p: ^Publisher, s: Snapshot) {
	sync.atomic_add(&p.seq, 1)
	p.data = s
	sync.atomic_add(&p.seq, 1)
}

/*
Attempts before giving up.

Enough to cover one write, which copies a few hundred bytes and so takes tens of
nanoseconds against under ten for an attempt. Beyond that the builder has been
descheduled partway through and no amount of spinning will help, while a caller that
keeps last frame's answer has lost nothing.
*/
@(private)
ATTEMPTS :: 4

// The latest complete snapshot. Fails while a write is in flux, which is the
// caller's cue to keep the frame it already has.
current :: proc(p: ^Publisher) -> (s: Snapshot, ok: bool) {
	for _ in 0 ..< ATTEMPTS {
		before := sync.atomic_load(&p.seq)
		if before & 1 != 0 {
			continue // a write is in progress
		}
		// Both loads are sequentially consistent, which is what stops the compiler
		// hoisting this copy above the first or sinking it below the second. Moving it
		// either way turns a correct seqlock into one that returns torn data silently.
		s = p.data
		if sync.atomic_load(&p.seq) == before {
			return s, true
		}
	}
	return {}, false
}
