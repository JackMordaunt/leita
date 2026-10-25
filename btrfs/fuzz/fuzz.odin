/*
Package fuzz checks extent charging and TREE_SEARCH_V2 item headers.

	charge  each unique extent contributes its encoded disk length exactly once
	search  a header's body stays inside the buffer it was cut from

Disk fields drawn for the independent sum are capped, and one item may be
max(u64) so a wrapping add has to come back as Overflow with the total unchanged.
*/
package btrfs_fuzz

import "core:encoding/endian"
import "core:fmt"
import "core:math/bits"

import harness "jm:fuzz"

import btrfs ".."

Case :: struct {}

properties := []harness.Property(Case){{"charge", check_charge}, {"search", check_search}}

CORPUS :: "btrfs/fuzz/corpus"

suite :: proc() -> harness.Suite(Case) {
	return {name = "btrfs", setup = setup, teardown = teardown, properties = properties}
}

run :: proc(opts := harness.Opts{}, allocator := context.allocator) -> harness.Report {
	return harness.run(suite(), opts, allocator)
}

setup :: proc() -> (Case, bool) {
	return {}, true
}

teardown :: proc(_: ^Case) {}

check_charge :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	n := harness.integer_in(src, 0, 5)
	u: btrfs.Usage
	defer btrfs.usage_destroy(&u)
	f: btrfs.File
	defer btrfs.file_destroy(&f)
	expected: u64
	seen := make(map[u64]struct{})
	defer delete(seen)
	for _ in 0 ..< n {
		item, at, disk := draw_item(src)
		_, duplicate := seen[at]
		next, wrapped := bits.overflowing_add(expected, disk)
		if duplicate {
			next, wrapped = expected, false
		}
		before := btrfs.total(u).disk
		err := btrfs.charge(item, &u, &f)
		after := btrfs.total(u).disk
		if wrapped {
			if err != .Overflow || after != before {
				return "wrapping extent did not leave the total unchanged", false
			}
			continue
		}
		if err != .None {
			return "valid extent was rejected", false
		}
		if !duplicate {
			seen[at] = {}
		}
		expected = next
		if after != expected {
			return "unique extents were charged by the wrong length", false
		}
	}
	return "", true
}

check_search :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	raw, _ := harness.damage(src, search_seeds())
	if len(raw) > 4096 {
		return fmt.tprintf("drew %d bytes, cap is %d", len(raw), 4096), false
	}
	// The reader of a reply takes item after item from what is left, so the
	// walk is the property: every body and every remainder stays in the buffer.
	u: btrfs.Usage
	defer btrfs.usage_destroy(&u)
	f: btrfs.File
	defer btrfs.file_destroy(&f)
	rest := raw
	for len(rest) > 0 {
		next, _, kind, body, ok_item := btrfs.read_search_item(rest)
		if !ok_item {
			return "", true
		}
		if !inside(raw, body) || !inside(raw, next) {
			return "search item leaves the buffer", false
		}
		if len(next) >= len(rest) {
			return "search item took no bytes", false
		}
		if kind == 108 {
			// EXTENT_DATA: what the reader does with the body, whatever it holds.
			_ = btrfs.charge(body, &u, &f)
		}
		rest = next
	}
	return "", true
}

@(private)
draw_item :: proc(src: ^harness.Source) -> (item: []byte, at, disk: u64) {
	// A regular extent. disk is capped unless one byte asks for the top of u64.
	disk = 4096
	if harness.byte_of(src) == 0xFF {
		disk = max(u64)
	} else {
		disk = u64(harness.integer_in(src, 0, 8)) << 12
	}
	at = u64(harness.integer_in(src, 1, 32)) << 12
	return make_item(at, disk), at, disk
}

@(private)
make_item :: proc(at, disk: u64) -> []byte {
	b := make([]byte, 53)
	b[20] = 1
	endian.put_u64(b[21:29], .Little, at)
	endian.put_u64(b[29:37], .Little, disk)
	return b
}

// search_seeds are TREE_SEARCH_V2 buffers: an item with a 4-byte body, as
// the unit test cuts one, the regular extent item the charge tests make, an
// inline one, and two items back to back, the shape a real reply has.
@(private)
search_seeds :: proc() -> [][]byte {
	regular := make_item(4096, 8192)
	inline := make([]byte, 21 + 6)
	inline[20] = 0
	out := make([][]byte, 4)
	out[0] = search_item(1, 108, make([]byte, 4))
	out[1] = search_item(4096, 108, regular)
	out[2] = search_item(0, 108, inline)
	out[3] = join(search_item(4096, 108, regular), search_item(8192, 108, regular))
	return out
}

@(private)
search_item :: proc(offset: u64, type: u32, body: []byte) -> []byte {
	b := make([]byte, 32 + len(body))
	endian.put_u64(b[16:24], .Little, offset)
	endian.put_u32(b[24:28], .Little, type)
	endian.put_u32(b[28:32], .Little, u32(len(body)))
	copy(b[32:], body)
	return b
}

@(private)
join :: proc(a, b: []byte) -> []byte {
	out := make([]byte, len(a) + len(b))
	copy(out, a)
	copy(out[len(a):], b)
	return out
}

@(private)
inside :: proc(buf, part: []byte) -> bool {
	if len(part) == 0 {
		return true
	}
	lo := uintptr(raw_data(buf))
	hi := lo + uintptr(len(buf))
	start := uintptr(raw_data(part))
	end := start + uintptr(len(part))
	return start >= lo && end <= hi
}
