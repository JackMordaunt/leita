package flow

import "core:testing"

// A binary tree flattened into indices: node i holds 2i+1 and 2i+2. Walking it is
// the shape manage is for, since a worker only learns of a node by visiting its
// parent, and it is deterministic enough to check exactly.
@(private = "file")
NODES :: 20_000

@(private = "file")
Visit :: struct {
	seen:  [dynamic]int,
	found: [dynamic]int,
	stop:  int, // visit this node and the run ends; -1 for never
	sink:  int, // keeps the busy loop below from being optimised away
}

@(private = "file")
descend :: proc(item: int, v: ^Visit) -> bool {
	append(&v.seen, item)
	if item == v.stop {
		return false
	}
	for c in ([]int{2 * item + 1, 2 * item + 2}) {
		if c < NODES {
			append(&v.found, c)
		}
	}
	return true
}

@(private = "file")
hand_over :: proc(item: int, ok: bool, v: ^Visit, queue: ^[dynamic]int) -> bool {
	for c in v.found {
		append(queue, c)
	}
	clear(&v.found)
	return ok
}

/*
Worker states, each holding what its worker saw.

The dynamic arrays are deliberately not on the temp allocator. A dynamic array
remembers the allocator it was made with, and these are appended to from every
worker at once, so a per-thread arena belonging to whichever thread built them would
be grown from all of them without a lock. That miscounted a node roughly once in
twelve runs. `delete` them with `release`.
*/
@(private = "file")
visitors :: proc(n: int, stop := -1) -> []Visit {
	v := make([]Visit, n, context.temp_allocator)
	for i in 0 ..< n {
		v[i] = Visit {
			seen  = make([dynamic]int, context.allocator),
			found = make([dynamic]int, context.allocator),
			stop  = stop,
		}
	}
	return v
}

@(private = "file")
release :: proc(v: []Visit) {
	for s in v {
		delete(s.seen)
		delete(s.found)
	}
}

@(private = "file")
totals :: proc(v: []Visit) -> (count, sum: int) {
	for s in v {
		for i in s.seen {
			count += 1
			sum += i
		}
	}
	return
}

@(test)
test_manage_reaches_every_node_once :: proc(t: ^testing.T) {
	v := visitors(8)
	defer release(v)
	manage([]int{0}, v, descend, hand_over)

	// The count proves how many were visited and the sum proves which, so together
	// they rule out one node twice and another never.
	count, sum := totals(v)
	testing.expect_value(t, count, NODES)
	testing.expect_value(t, sum, NODES * (NODES - 1) / 2)
}

@(test)
test_manage_agrees_with_one_worker :: proc(t: ^testing.T) {
	// A single worker runs inline with no threads at all, which is the yardstick the
	// concurrent run has to match.
	one := visitors(1)
	defer release(one)
	manage([]int{0}, one, descend, hand_over)
	count, sum := totals(one)
	testing.expect_value(t, count, NODES)
	testing.expect_value(t, sum, NODES * (NODES - 1) / 2)
}

@(private = "file")
HEAVY :: 400

// A node has to cost appreciably more than starting a thread, or the calling thread
// drains the queue before the others are scheduled and the split says nothing. That
// is a property of the work, not of the traversal.
@(private = "file")
descend_slowly :: proc(item: int, v: ^Visit) -> bool {
	acc := 0
	for i in 0 ..< 400_000 {
		acc += i ~ item
	}
	v.sink += acc & 1
	append(&v.seen, item)
	for c in ([]int{2 * item + 1, 2 * item + 2}) {
		if c < HEAVY {
			append(&v.found, c)
		}
	}
	return true
}

@(test)
test_manage_spreads_across_workers :: proc(t: ^testing.T) {
	v := visitors(4)
	defer release(v)
	manage([]int{0}, v, descend_slowly, hand_over)

	count, sum := totals(v)
	testing.expect_value(t, count, HEAVY)
	testing.expect_value(t, sum, HEAVY * (HEAVY - 1) / 2)

	busy := 0
	for s in v {
		if len(s.seen) > 0 {
			busy += 1
		}
	}
	testing.expect(t, busy > 1, "the traversal stayed on a single worker")
}

@(test)
test_manage_stops_when_the_manager_returns_false :: proc(t: ^testing.T) {
	// One worker keeps this exact: with several, those already holding an item
	// finish it, which is the documented behaviour.
	one := visitors(1, stop = 0)
	defer release(one)
	manage([]int{0}, one, descend, hand_over)
	count, _ := totals(one)
	testing.expect_value(t, count, 1)
}

@(test)
test_manage_tolerates_an_empty_seed :: proc(t: ^testing.T) {
	v := visitors(4)
	defer release(v)
	manage([]int{}, v, descend, hand_over)
	count, _ := totals(v)
	testing.expect_value(t, count, 0)
}

// A failed item is the manager's to judge, and the judgement it cannot make without
// being told which item failed is to try that one again.
@(private = "file")
Attempt :: struct {
	id:    int,
	tries: int,
}

@(private = "file")
Flaky :: struct {
	seen: [dynamic]Attempt,
}

@(private = "file")
refuse_twice :: proc(item: Attempt, f: ^Flaky) -> bool {
	append(&f.seen, item)
	return !(item.id == 1 && item.tries < 2)
}

@(private = "file")
retry :: proc(item: Attempt, ok: bool, f: ^Flaky, queue: ^[dynamic]Attempt) -> bool {
	if !ok {
		append(queue, Attempt{id = item.id, tries = item.tries + 1})
	}
	return true
}

@(test)
test_manage_requeues_a_failed_item :: proc(t: ^testing.T) {
	// One worker keeps the count exact; the point is the shape, not the width.
	f := make([]Flaky, 1, context.temp_allocator)
	f[0].seen = make([dynamic]Attempt, context.temp_allocator)
	seed := []Attempt{{id = 0}, {id = 1}, {id = 2}}
	manage(seed, f, refuse_twice, retry)

	// Three items, one of them attempted three times, and the run carried on past
	// the failures rather than ending at the first.
	testing.expect_value(t, len(f[0].seen), 5)
	tries := 0
	for a in f[0].seen {
		if a.id == 1 {
			tries += 1
		}
	}
	testing.expect_value(t, tries, 3)
}
