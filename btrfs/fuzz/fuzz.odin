/*
Package fuzz checks extent charging and TREE_SEARCH_V2 item headers.

	charge  charged disk never exceeds the sum of the lengths charged
	search  a header's body stays inside the buffer it was cut from

Disk fields drawn for the sum are capped, and one item may be max(u64) so a
wrapping add has to come back as Overflow with the total unchanged.
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
	sum: u64
	sum_wrapped := false
	for _ in 0 ..< n {
		item := draw_item(src)
		before := btrfs.total(u).disk
		err := btrfs.charge(item, &u, &f)
		after := btrfs.total(u).disk
		if err != .None && after != before {
			//review:ignore odin-temp-in-loop the formatted string is the failure return; the loop stops
			return fmt.tprintf("%v changed the total", err), false
		}
		if after < before {
			return "charged total wrapped", false
		}
		next, wrapped := bits.overflowing_add(sum, after - before)
		if wrapped {
			sum_wrapped = true
		} else {
			sum = next
		}
	}
	if sum_wrapped {
		return "the charged lengths do not fit in u64", false
	}
	if btrfs.total(u).disk != sum {
		return fmt.tprintf("charged %d, added lengths sum to %d", btrfs.total(u).disk, sum), false
	}
	return "", true
}

check_search :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	raw, _ := harness.damage(src, [][]byte{search_seed()})
	if len(raw) > 4096 {
		return fmt.tprintf("drew %d bytes, cap is %d", len(raw), 4096), false
	}
	rest, _, _, body, ok_item := btrfs.read_search_item(raw)
	if !ok_item {
		return "", true
	}
	if !inside(raw, body) || !inside(raw, rest) {
		return "search item leaves the buffer", false
	}
	return "", true
}

@(private)
draw_item :: proc(src: ^harness.Source) -> []byte {
	// A regular extent. disk is capped unless one byte asks for the top of u64.
	disk: u64 = 4096
	if harness.byte_of(src) == 0xFF {
		disk = max(u64)
	} else {
		disk = u64(harness.integer_in(src, 0, 8)) << 12
	}
	at := u64(harness.integer_in(src, 1, 32)) << 12
	b := make([]byte, 53)
	b[20] = 1
	endian.put_u64(b[21:29], .Little, at)
	endian.put_u64(b[29:37], .Little, disk)
	return b
}

@(private)
search_seed :: proc() -> []byte {
	b := make([]byte, 32 + 4)
	endian.put_u64(b[16:24], .Little, 1)
	endian.put_u32(b[24:28], .Little, 108)
	endian.put_u32(b[28:32], .Little, 4)
	return b
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
