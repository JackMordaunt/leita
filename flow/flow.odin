/*
Package flow holds this project's concurrency shapes.

Every shape obeys one rule: a worker owns its state and never shares it. Locks are
then unnecessary, and the caller merges the states once the run is over.

	width   how many workers a piece of work deserves
	each    claim items from a shared counter until they run out
	manage  the same, for work that discovers more of itself as it goes
*/
package flow

import "core:os"
import "core:sync"
import "core:thread"

/*
Run `work` over every item, across workers that claim one item at a time.

Each worker owns one slot of `states`, so `work` needs no locks. Merge the slots
afterwards, tolerating untouched ones. Anything else a worker touches must be read
only, or written at disjoint addresses.

Returning false stops the run; claimed items still finish.

`len(states)` sets the width, capped by `width(len(items), load)`; pass the `load`
the slice was sized with. One slot runs inline. Workers get a fresh context, so any
allocator the work needs belongs in `State`.

An item should cost more than the thirty microseconds it takes to start a thread.
*/
each :: proc(
	items: []$I,
	states: []$S,
	work: proc(item: I, state: ^S) -> bool,
	load := Load.Mixed,
) {
	if len(items) == 0 || len(states) == 0 {
		return
	}

	shared := Shared(I, S) {
		items  = items,
		states = states,
		work   = work,
	}

	pool := min(len(states), width(len(items), load))

	if pool == 1 {
		claim_loop(&shared, 0)
		return
	}

	threads := make([]^thread.Thread, pool - 1, context.temp_allocator)
	defer delete(threads, context.temp_allocator)

	started := 0
	for i in 0 ..< len(threads) {
		t := thread.create_and_start_with_poly_data(Arg(I, S){&shared, i + 1}, worker_entry)
		if t == nil {
			break
		}
		threads[i] = t
		started += 1
	}

	// The calling thread takes slot 0 rather than idling while the others work.
	claim_loop(&shared, 0)

	thread.join_multiple(..threads[:started])
	for t in threads[:started] {
		thread.destroy(t)
	}
}

// How a piece of work divides between waiting and computing, which is the part of
// the width decision that only the caller knows.
Load :: enum {
	Cpu, // computing throughout: more workers than cores only makes them compete
	Mixed, // alternates between the two, the common case
	Io, // mostly parked in a device call, using no core while it waits
}

/*
How many workers `items` pieces of work deserve. Size a state slice with it.

Computing work wants one worker per core; work parked in a device call wants several
times that, since it holds no core while it waits. `load` picks between them.

The answer starts from the core count, so no input size can run it away; `items` and
`limit` only reduce it. `limit` is also the cap when each worker needs a large buffer.

The multipliers are starting points, not measured.
*/
width :: proc(items: int, load := Load.Mixed, limit := 0) -> int {
	cores := os.get_processor_core_count()
	if cores < 1 {
		cores = 1
	}
	n: int
	switch load {
	case .Cpu:
		n = cores
	case .Mixed:
		n = cores * 2
	case .Io:
		n = cores * 4
	}
	if limit > 0 && n > limit {
		n = limit
	}
	// One worker is the floor: a caller with no work still needs a runnable answer.
	return min(n, max(items, 1))
}

@(private)
Shared :: struct($I: typeid, $S: typeid) {
	items:  []I,
	states: []S,
	work:   proc(item: I, state: ^S) -> bool,
	next:   int,
	stop:   b32,
}

@(private)
Arg :: struct($I: typeid, $S: typeid) {
	shared: ^Shared(I, S),
	index:  int,
}

@(private)
worker_entry :: proc(arg: Arg($I, $S)) {
	claim_loop(arg.shared, arg.index)
}

@(private)
claim_loop :: proc(shared: ^Shared($I, $S), index: int) {
	state := &shared.states[index]
	for !sync.atomic_load(&shared.stop) {
		// atomic_add returns the value from before the add, so this claims index i
		// and leaves the next one for whoever gets here first.
		i := sync.atomic_add(&shared.next, 1)
		if i >= len(shared.items) {
			return
		}
		if !shared.work(shared.items[i], state) {
			sync.atomic_store(&shared.stop, true)
			return
		}
	}
}
