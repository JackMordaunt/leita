package main

import "core:testing"

@(test)
test_snapshot_round_trips :: proc(t: ^testing.T) {
	p: Publisher
	_, ok := current(&p)
	testing.expect(t, ok, "an untouched publisher should still hand out its zero value")

	s := Snapshot {
		count    = 2,
		nodes    = 99,
		complete = true,
	}
	s.rows[0] = {
		node  = 7,
		bytes = 4096,
	}
	publish(&p, s)

	got, got_ok := current(&p)
	testing.expect(t, got_ok)
	testing.expect_value(t, got.count, 2)
	testing.expect_value(t, got.nodes, u64(99))
	testing.expect_value(t, got.rows[0].bytes, u64(4096))
	testing.expect(t, got.complete)
}

@(test)
test_snapshot_refuses_a_write_in_flux :: proc(t: ^testing.T) {
	// An odd sequence is what a half-written snapshot looks like. The reader must
	// decline rather than hand back something torn.
	p: Publisher
	publish(&p, Snapshot{count = 1})
	p.seq += 1 // as though a write had begun

	_, ok := current(&p)
	testing.expect(t, !ok, "a snapshot mid-write was handed out")

	p.seq += 1 // and finished
	_, ok2 := current(&p)
	testing.expect(t, ok2, "a finished write was not readable")
}
