package btrfs

import "core:encoding/endian"
import "core:sync"
import "core:testing"
import "core:thread"

// A file extent item as the tree search returns it: inline when at is never asked
// for, so the data follows the header.
@(private = "file")
item :: proc(kind, compression: u8, ram: u64, at, disk, refers: u64, inline_len := 0) -> []u8 {
	size := ITEM_SIZE if kind != EXTENT_INLINE else ITEM_INLINE_HEADER + inline_len
	b := make([]u8, size, context.temp_allocator)
	endian.put_u64(b[8:16], .Little, ram)
	b[16] = compression
	b[20] = kind
	if kind != EXTENT_INLINE {
		endian.put_u64(b[21:29], .Little, at)
		endian.put_u64(b[29:37], .Little, disk)
		endian.put_u64(b[45:53], .Little, refers)
	}
	return b
}

@(private = "file")
EXTENT_REGULAR :: 1

// An inline extent is charged what the item holds on disk and its uncompressed
// length otherwise, to its file alone.
@(test)
test_inline_is_charged_to_its_file :: proc(t: ^testing.T) {
	u: Usage
	defer usage_destroy(&u)
	f: File
	defer file_destroy(&f)
	testing.expect_value(
		t,
		charge(item(EXTENT_INLINE, 3, 3000, 0, 0, 0, 120), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(t, u.by[.Zstd], Sizes{120, 3000, 3000})
	testing.expect_value(t, f.sizes, Sizes{120, 3000, 3000})
	testing.expect_value(t, f.charged, 120)
	testing.expect_value(t, u.inline, 1)
}

/*
A compressed extent is charged its compressed size once. A reflinked copy refers
to it again: the copy's own sizes include it and it is marked shared, but the run
charges nothing more than its referenced bytes.
*/
@(test)
test_shared_extent_is_charged_once :: proc(t: ^testing.T) {
	u: Usage
	defer usage_destroy(&u)
	a, b: File
	defer file_destroy(&a)
	defer file_destroy(&b)
	x := item(EXTENT_REGULAR, 3, 131072, 1 << 20, 4096, 131072)
	testing.expect_value(t, charge(x, &u, &a), Item_Error.None)
	testing.expect_value(t, charge(x, &u, &b), Item_Error.None)
	testing.expect_value(t, u.by[.Zstd], Sizes{4096, 131072, 262144})
	testing.expect_value(t, u.extents, 1)
	testing.expect_value(t, u.refs, 2)
	testing.expect_value(t, a.sizes, Sizes{4096, 131072, 131072})
	testing.expect_value(t, b.sizes, Sizes{4096, 131072, 131072})
	testing.expect_value(t, a.charged, 4096)
	testing.expect_value(t, b.charged, 0)
	testing.expect(t, !a.shared, "the first file to meet an extent does not share it")
	testing.expect(t, b.shared, "a reflinked copy shares its extent")
}

// An extent split by an overwrite is referred to twice by one file, which is
// charged for it once and does not share it.
@(test)
test_split_extent_is_not_shared :: proc(t: ^testing.T) {
	u: Usage
	defer usage_destroy(&u)
	f: File
	defer file_destroy(&f)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 8192, 1 << 20, 8192, 4096), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 4096, 2 << 20, 4096, 4096), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 8192, 1 << 20, 8192, 4096), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(t, f.sizes, Sizes{12288, 12288, 12288})
	testing.expect_value(t, f.charged, 12288)
	testing.expect(t, !f.shared, "a file does not share an extent with itself")
}

// A hole is charged nothing; a preallocated extent is kept apart; a short item is
// refused.
@(test)
test_holes_prealloc_and_short_items :: proc(t: ^testing.T) {
	u: Usage
	defer usage_destroy(&u)
	f: File
	defer file_destroy(&f)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 1 << 20, 0, 0, 1 << 20), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(t, total(u), Sizes{})
	testing.expect_value(t, u.refs, 0)
	testing.expect_value(
		t,
		charge(item(EXTENT_PREALLOC, 0, 4096, 1 << 20, 4096, 4096), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(t, u.by[.Prealloc], Sizes{4096, 4096, 4096})
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 0, 0, 0, 0)[:30], &u, &f),
		Item_Error.Short,
	)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 9, 4096, 3 << 20, 4096, 4096), &u, &f),
		Item_Error.Compression,
	)
}

/*
Charged against a walk's shared Extents, a file pays for an inline extent and for
each extent no file paid for before it, once however many of its ranges refer to
it, and nothing for a hole. A reflinked copy pays nothing for what it shares and is
marked shared; the same file meeting its own extent again is not.
*/
@(test)
test_shared_charge_pays_each_extent_once :: proc(t: ^testing.T) {
	e: Extents
	extents_init(&e)
	defer extents_destroy(&e)
	a_owner := owner_of(7, 300)
	b_owner := owner_of(7, 301)

	a_items := [?][]u8 {
		item(EXTENT_INLINE, 3, 3000, 0, 0, 0, 120),
		item(EXTENT_REGULAR, 3, 131072, 1 << 20, 4096, 131072),
		item(EXTENT_REGULAR, 0, 8192, 2 << 20, 8192, 4096),
		item(EXTENT_REGULAR, 0, 8192, 2 << 20, 8192, 4096),
		item(EXTENT_REGULAR, 0, 1 << 20, 0, 0, 1 << 20),
	}
	a: Charge
	for x in a_items {
		testing.expect_value(t, charge_shared(x, &e, a_owner, &a), Item_Error.None)
	}
	testing.expect_value(t, a, Charge{120 + 4096 + 8192, false})

	b_items := [?][]u8 {
		item(EXTENT_REGULAR, 3, 131072, 1 << 20, 4096, 131072),
		item(EXTENT_REGULAR, 0, 4096, 3 << 20, 4096, 4096),
	}
	b: Charge
	for x in b_items {
		testing.expect_value(t, charge_shared(x, &e, b_owner, &b), Item_Error.None)
	}
	testing.expect_value(t, b, Charge{4096, true})

	short: Charge
	testing.expect_value(
		t,
		charge_shared(item(EXTENT_REGULAR, 0, 0, 0, 0, 0)[:30], &e, a_owner, &short),
		Item_Error.Short,
	)
}

// Two extents of max(u64) bytes must not wrap the charged total to a small number.
@(test)
test_two_max_extents_do_not_wrap :: proc(t: ^testing.T) {
	u: Usage
	defer usage_destroy(&u)
	f: File
	defer file_destroy(&f)
	first := item(EXTENT_REGULAR, 0, 0, 4096, max(u64), 0)
	testing.expect_value(t, charge(first, &u, &f), Item_Error.None)
	testing.expect_value(t, total(u).disk, max(u64))
	second := item(EXTENT_REGULAR, 0, 0, 8192, max(u64), 0)
	testing.expect_value(t, charge(second, &u, &f), Item_Error.Overflow)
	testing.expect_value(t, total(u).disk, max(u64))

	e: Extents
	extents_init(&e)
	defer extents_destroy(&e)
	c: Charge
	testing.expect_value(t, charge_shared(first, &e, 1, &c), Item_Error.None)
	testing.expect_value(t, c.disk, max(u64))
	testing.expect_value(t, charge_shared(second, &e, 2, &c), Item_Error.Overflow)
	testing.expect_value(t, c.disk, max(u64))
}

@(test)
test_read_search_item_stops_at_the_buffer :: proc(t: ^testing.T) {
	short := make([]u8, SEARCH_HEADER, context.temp_allocator)
	endian.put_u32(short[28:32], .Little, 1)
	_, _, _, _, ok := read_search_item(short)
	testing.expect(t, !ok, "a length past the buffer is not an item")

	buf := make([]u8, SEARCH_HEADER + 4, context.temp_allocator)
	endian.put_u64(buf[16:24], .Little, 9)
	endian.put_u32(buf[24:28], .Little, 108)
	endian.put_u32(buf[28:32], .Little, 4)
	rest, offset, item_type, body, ok2 := read_search_item(buf)
	testing.expect(t, ok2, "a header and its body")
	testing.expect_value(t, offset, u64(9))
	testing.expect_value(t, item_type, u32(108))
	testing.expect_value(t, len(body), 4)
	testing.expect_value(t, len(rest), 0)
}

/*
Workers charging the same extents at once pay for each exactly once between them,
whichever of them gets there first: what they are charged adds up to the extents'
disk, as one worker charging them alone would.
*/
@(test)
test_concurrent_charges_add_up_to_the_extents :: proc(t: ^testing.T) {
	WORKERS    :: 8
	EXTENTS    :: 20000
	Concurrent :: struct {
		e:     Extents,
		paid:  u64,
		start: sync.Barrier,
	}
	s: Concurrent
	extents_init(&s.e)
	defer extents_destroy(&s.e)
	sync.barrier_init(&s.start, WORKERS)

	run :: proc(s: ^Concurrent, worker: int) {
		sync.barrier_wait(&s.start)
		c: Charge
		// Every worker charges every extent, from a different starting point.
		for i in 0 ..< EXTENTS {
			k := (i + worker * 997) % EXTENTS
			at := u64(k + 1) * 4096
			b: [ITEM_SIZE]u8
			b[20] = EXTENT_REGULAR
			endian.put_u64(b[21:29], .Little, at)
			endian.put_u64(b[29:37], .Little, u64(k % 7 + 1) * 4096)
			if charge_shared(b[:], &s.e, owner_of(1, u64(worker)), &c) != .None {
				return
			}
		}
		sync.atomic_add(&s.paid, c.disk)
	}

	threads: [WORKERS]^thread.Thread
	for &th, i in threads {
		th = thread.create_and_start_with_poly_data2(&s, i, run)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	want: u64
	for k in 0 ..< EXTENTS {
		want += u64(k % 7 + 1) * 4096
	}
	testing.expect_value(t, s.paid, want)
}
