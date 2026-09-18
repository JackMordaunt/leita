package scan

import "core:sync"

TOP_ROWS :: 20

Row :: struct {
	node:  u32,
	bytes: u64,
}

// What a UI draws: a fixed number of rows and a few counters, whatever the size of
// the volume behind it.
Snapshot :: struct {
	rows:     [TOP_ROWS]Row,
	count:    int,
	nodes:    u64, // records folded so far
	bytes:    u64,
	pending:  int, // nodes waiting on an ancestor
	elapsed:  f64, // milliseconds since the scan began
	complete: bool,
}

/*
Hands a snapshot from the thread building it to the thread drawing it.

A sequence number is raised before a write and again after, so it is odd only while
the data is in flux. A reader takes a copy and checks the number is unchanged and
even; if not it takes another. That is what keeps a frame from ever waiting on a
build step, however long the step takes: the reader either gets the new answer or
keeps the one it already had.
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

// The latest complete snapshot. Fails only if the builder wrote several times during
// the attempt, in which case the caller draws what it drew last frame.
current :: proc(p: ^Publisher) -> (s: Snapshot, ok: bool) {
	for _ in 0 ..< 16 {
		before := sync.atomic_load(&p.seq)
		if before & 1 != 0 {
			continue // a write is in progress
		}
		s = p.data
		if sync.atomic_load(&p.seq) == before {
			return s, true
		}
	}
	return {}, false
}
