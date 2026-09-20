package flow

import "core:sync"
import "core:thread"

/*
Run work over a set that grows as the work discovers more of it.

`seed` starts the queue; every later item arrives through `manager`, which runs one
at a time. `work` runs on many threads at once, taking the next item the moment one
exists rather than in rounds.

Each worker owns one slot of `states`, so `work` needs no locks, exactly as in `each`.
`manager` sees that slot beside the item that filled it, and queues whatever comes
next, that item included.

`work` returning false marks the item failed, not the run. `manager` returning false
ends the run; workers finish the item in hand and report through their state.

Every item reaches `work` or `discard`, never both and never neither. A stopped run
leaves items queued that nothing else can reach, so an item owning memory needs
`discard` to release it.

`len(states)` sets the width, capped by what the machine can use.
*/
manage :: proc(
	seed: []$I,
	states: []$S,
	work: proc(item: I, state: ^S) -> bool,
	manager: proc(item: I, ok: bool, state: ^S, queue: ^[dynamic]I) -> bool,
	discard: proc(item: I) = nil,
	load := Load.Io,
) {
	if len(seed) == 0 || len(states) == 0 {
		return
	}
	q: Queue(I, S)
	q.states = states
	q.work = work
	q.manager = manager
	q.items = make([dynamic]I, context.allocator)
	defer delete(q.items)
	// Runs before the delete above, while the queue still holds what was never taken.
	defer sweep(&q, discard)
	append(&q.items, ..seed)

	pool := min(len(states), width(1 << 30, load))
	if pool == 1 {
		drain(&q, 0)
		return
	}

	threads := make([]^thread.Thread, pool - 1, context.temp_allocator)
	defer delete(threads, context.temp_allocator)
	started := 0
	for i in 0 ..< len(threads) {
		t := thread.create_and_start_with_poly_data(Hand(I, S){&q, i + 1}, hand_entry)
		if t == nil {
			break
		}
		threads[i] = t
		started += 1
	}
	drain(&q, 0)
	thread.join_multiple(..threads[:started])
	for t in threads[:started] {
		thread.destroy(t)
	}
}

// Release what the run never took, once every worker has stopped.
@(private)
sweep :: proc(q: ^Queue($I, $S), discard: proc(item: I)) {
	if discard == nil {
		return
	}
	for item in q.items[q.head:] {
		discard(item)
	}
	q.head = len(q.items)
}

@(private)
Queue :: struct($I: typeid, $S: typeid) {
	items:   [dynamic]I,
	head:    int,
	active:  int, // workers holding an item, which may yet produce more
	over:    bool,
	mutex:   sync.Mutex,
	wake:    sync.Cond,
	states:  []S,
	work:    proc(item: I, state: ^S) -> bool,
	manager: proc(item: I, ok: bool, state: ^S, queue: ^[dynamic]I) -> bool,
}

@(private)
Hand :: struct($I: typeid, $S: typeid) {
	queue: ^Queue(I, S),
	index: int,
}

@(private)
hand_entry :: proc(h: Hand($I, $S)) {
	drain(h.queue, h.index)
}

@(private)
drain :: proc(q: ^Queue($I, $S), index: int) {
	state := &q.states[index]
	for {
		sync.mutex_lock(&q.mutex)
		// Wait while the queue is empty but someone still holds an item, since that
		// worker may yet discover more. Empty with nobody working means finished.
		for q.head >= len(q.items) && q.active > 0 && !q.over {
			sync.cond_wait(&q.wake, &q.mutex)
		}
		if q.over || q.head >= len(q.items) {
			q.over = true
			sync.cond_broadcast(&q.wake)
			sync.mutex_unlock(&q.mutex)
			return
		}
		item := q.items[q.head]
		q.head += 1
		q.active += 1
		// Reclaim the consumed prefix once it dominates, or a deep traversal keeps
		// every item it has ever seen.
		if q.head > 1024 && q.head * 2 > len(q.items) {
			n := copy(q.items[:], q.items[q.head:])
			resize(&q.items, n)
			q.head = 0
		}
		sync.mutex_unlock(&q.mutex)

		ok := q.work(item, state)

		sync.mutex_lock(&q.mutex)
		q.active -= 1
		// The manager runs for a failed item too: deciding what a failure means is
		// the whole of its job.
		if !q.manager(item, ok, state, &q.items) {
			q.over = true
		}
		sync.cond_broadcast(&q.wake)
		sync.mutex_unlock(&q.mutex)
	}
}
