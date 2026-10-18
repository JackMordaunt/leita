/*
Package fuzz checks the NTFS parsers against mutated bytes.

	boot        parse twice, and an accepted sector agrees with itself
	attributes  every attribute slice stays inside the record
	runlist     each run's VCN is the non-wrapping sum of the lengths before it
	record      a short or damaged FILE record is an error or a bounded prefix

There is no $ATTRIBUTE_LIST entry decoder. The attribute iterator is what a
record yields, including a type-0x20 attribute, and the slices stay in range.
*/
package ntfs_fuzz

import "core:fmt"
import "core:math/bits"

import harness "jm:fuzz"

import ntfs ".."

Case :: struct {}

properties := []harness.Property(Case) {
	{"boot", check_boot},
	{"attributes", check_attributes},
	{"runlist", check_runlist},
	{"record", check_record},
}

CORPUS :: "ntfs/fuzz/corpus"

INPUT_CAP :: 4096

suite :: proc() -> harness.Suite(Case) {
	return {name = "ntfs", setup = setup, teardown = teardown, properties = properties}
}

run :: proc(opts := harness.Opts{}, allocator := context.allocator) -> harness.Report {
	return harness.run(suite(), opts, allocator)
}

setup :: proc() -> (Case, bool) {
	return {}, true
}

teardown :: proc(_: ^Case) {}

@(private)
boot_seed :: proc() -> []byte {
	b := make([]byte, 512)
	copy(b[3:], "NTFS    ")
	put16(b, 0x0B, 512)
	b[0x0D] = 8
	put64(b, 0x28, 786_432 * 4096 + 4096)
	put64(b, 0x30, 786_432)
	put64(b, 0x38, 2)
	b[0x40] = 0xF6
	b[0x44] = 1
	put64(b, 0x48, 0xDEADBEEF)
	b[0x1FE] = 0x55
	b[0x1FF] = 0xAA
	return b
}

@(private)
RUNLIST_SEED := []byte{0x21, 0x18, 0x34, 0x56, 0x11, 0x30, 0xF0, 0x01, 0x10, 0x00}

check_boot :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	raw, _ := harness.damage(src, [][]byte{boot_seed()})
	if len(raw) > INPUT_CAP {
		return fmt.tprintf("drew %d bytes, cap is %d", len(raw), INPUT_CAP), false
	}
	first, err1 := ntfs.parse_boot_sector(raw)
	second, err2 := ntfs.parse_boot_sector(raw)
	if err1 != err2 || first != second {
		return fmt.tprintf("parse twice: %v then %v", err1, err2), false
	}
	if err1 == .None {
		if first.bytes_per_cluster != first.bytes_per_sector * first.sectors_per_cluster {
			return "cluster size is not sector size times sectors per cluster", false
		}
	}
	return "", true
}

check_attributes :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	raw, _ := harness.damage(src, [][]byte{file_record()})
	if len(raw) > INPUT_CAP {
		return fmt.tprintf("drew %d bytes, cap is %d", len(raw), INPUT_CAP), false
	}
	return slices_stay_inside(raw)
}

check_runlist :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	raw, _ := harness.damage(src, [][]byte{RUNLIST_SEED})
	if len(raw) > INPUT_CAP {
		return fmt.tprintf("drew %d bytes, cap is %d", len(raw), INPUT_CAP), false
	}
	first_vcn: u64
	if harness.boolean(src) {
		first_vcn = harness.u64_of(src)
	}
	runs, err := ntfs.decode_runlist(raw, first_vcn)
	defer delete(runs)
	if err != .None {
		return "", true
	}
	if len(runs) > len(raw) {
		return fmt.tprintf("%d runs from %d bytes", len(runs), len(raw)), false
	}
	vcn := first_vcn
	for r, i in runs {
		if r.vcn != vcn {
			//review:ignore odin-temp-in-loop the formatted string is the failure return; the loop stops
			return fmt.tprintf("run %d vcn %d, running %d", i, r.vcn, vcn), false
		}
		end, wrapped := bits.overflowing_add(vcn, r.length)
		if wrapped {
			//review:ignore odin-temp-in-loop the formatted string is the failure return; the loop stops
			return fmt.tprintf("run %d length %d wraps vcn %d", i, r.length, vcn), false
		}
		vcn = end
	}
	return "", true
}

check_record :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	raw, _ := harness.damage(src, [][]byte{file_record()})
	if len(raw) > INPUT_CAP {
		return fmt.tprintf("drew %d bytes, cap is %d", len(raw), INPUT_CAP), false
	}
	if why, held := slices_stay_inside(raw); !held {
		return why, false
	}
	// A handful of entries. The virtual name arena is this case's, destroyed
	// before the property returns, so a copied subject cannot leak it.
	m: ntfs.Mft
	if ntfs.mft_init(&m, 4, 4096, 1) != .None {
		return "mft table was not created", false
	}
	defer ntfs.mft_destroy(&m)
	_ = ntfs.apply_fixups(raw)
	_ = ntfs.mft_add_record(&m, 1, raw, &m.sinks[0])
	return "", true
}

@(private)
slices_stay_inside :: proc(rec: []byte) -> (detail: string, ok: bool) {
	lo := uintptr(raw_data(rec))
	hi := lo + uintptr(len(rec))
	it := ntfs.attributes(rec)
	n := 0
	for {
		a, got := ntfs.next_attribute(&it)
		if !got {
			break
		}
		n += 1
		if n > len(rec) {
			//review:ignore odin-temp-in-loop the formatted string is the failure return; the loop stops
			return fmt.tprintf("more than %d attributes", len(rec)), false
		}
		if !inside(lo, hi, transmute([]byte)a.name) {
			return "attribute name leaves the record", false
		}
		if !inside(lo, hi, a.value) {
			return "attribute value leaves the record", false
		}
		if !inside(lo, hi, a.runlist) {
			return "runlist leaves the record", false
		}
	}
	return "", true
}

@(private)
inside :: proc(lo, hi: uintptr, b: []byte) -> bool {
	if len(b) == 0 {
		return true
	}
	start := uintptr(raw_data(b))
	end := start + uintptr(len(b))
	return start >= lo && end <= hi && end >= start
}

@(private)
file_record :: proc() -> []byte {
	// A resident $FILE_NAME of one letter. Parent ref 5, name "a" after the
	// 66-byte header.
	value := make([]byte, 66 + 2)
	put64(value, 0, 5)
	value[0x40] = 1
	value[0x41] = 1
	value[66] = u8('a')
	attr := resident(u32(ntfs.Attr_Type.File_Name), value)
	return record_with(attr)
}

@(private)
resident :: proc(type: u32, value: []byte) -> []byte {
	length := (24 + len(value) + 7) & ~int(7)
	b := make([]byte, length)
	put32(b, 0, type)
	put32(b, 4, u32(length))
	put32(b, 16, u32(len(value)))
	put16(b, 20, 24)
	copy(b[24:], value)
	return b
}

@(private)
record_with :: proc(attr: []byte) -> []byte {
	rec := make([]byte, 1024)
	put32(rec, 0, 0x454C4946)
	put16(rec, 4, 0x30)
	put16(rec, 6, 3)
	put16(rec, 0x10, 7)
	put16(rec, 0x12, 1)
	put16(rec, 0x14, 0x38)
	put16(rec, 0x16, 1) // in use
	put32(rec, 0x2C, 1)
	copy(rec[0x38:], attr)
	off := 0x38 + len(attr)
	put32(rec, off, 0xFFFFFFFF)
	off += 8
	put32(rec, 0x18, u32(off))
	put32(rec, 0x1C, 1024)
	put16(rec, 0x30, 0x1234)
	put16(rec, 0x32, 0xABCD)
	put16(rec, 0x34, 0xEF01)
	put16(rec, 510, 0x1234)
	put16(rec, 1022, 0x1234)
	return rec
}

//review:ignore duplicate-body ntfs_test's copy is private to that file, and ntfs.wr16 is private to the parser
@(private)
put16 :: proc(b: []byte, off: int, v: u16) {
	b[off] = byte(v)
	b[off + 1] = byte(v >> 8)
}

//review:ignore duplicate-body ntfs_test's copy is private to that file; this package cannot call it
@(private)
put32 :: proc(b: []byte, off: int, v: u32) {
	put16(b, off, u16(v))
	put16(b, off + 2, u16(v >> 16))
}

//review:ignore duplicate-body ntfs_test's copy is private to that file; this package cannot call it
@(private)
put64 :: proc(b: []byte, off: int, v: u64) {
	put32(b, off, u32(v))
	put32(b, off + 4, u32(v >> 32))
}
