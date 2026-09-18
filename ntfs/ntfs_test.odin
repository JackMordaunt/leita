package ntfs

import "core:testing"
import "core:unicode/utf16"

// ---- synthetic on-disk structures -------------------------------------------------
//
// Real MFT records are awkward to ship as fixtures (they carry the volume's file
// names), so tests build records byte by byte with the same layout rules the parser
// enforces. Everything is allocated from the temp allocator, which the test runner
// resets between tests.

@(private = "file")
put16 :: proc(b: []byte, off: int, v: u16) {
	b[off] = byte(v)
	b[off + 1] = byte(v >> 8)
}

@(private = "file")
put32 :: proc(b: []byte, off: int, v: u32) {
	put16(b, off, u16(v))
	put16(b, off + 2, u16(v >> 16))
}

@(private = "file")
put64 :: proc(b: []byte, off: int, v: u64) {
	put32(b, off, u32(v))
	put32(b, off + 4, u32(v >> 32))
}

@(private = "file")
utf16_of :: proc(s: string) -> []u16 {
	buf := make([]u16, len(s) * 2 + 1, context.temp_allocator)
	n := utf16.encode_string(buf, s)
	return buf[:n]
}

@(private = "file")
align8 :: proc(n: int) -> int {
	return (n + 7) & ~int(7)
}

@(private = "file")
resident :: proc(type: Attr_Type, value: []byte, name := "", flags: Attr_Flags = {}) -> []byte {
	name16 := utf16_of(name)
	name_ofs := size_of(Resident_Header)
	value_ofs := align8(name_ofs + len(name16) * 2)
	length := align8(value_ofs + len(value))
	b := make([]byte, length, context.temp_allocator)
	put32(b, 0, u32(type))
	put32(b, 4, u32(length))
	b[8] = 0
	b[9] = u8(len(name16))
	put16(b, 10, u16(name_ofs))
	put16(b, 12, transmute(u16)flags)
	put16(b, 14, 1)
	put32(b, 16, u32(len(value)))
	put16(b, 20, u16(value_ofs))
	for c, i in name16 {
		put16(b, name_ofs + 2 * i, c)
	}
	copy(b[value_ofs:], value)
	return b
}

@(private = "file")
nonresident :: proc(
	type: Attr_Type,
	allocated, data_size: u64,
	runlist: []byte,
	name := "",
	flags: Attr_Flags = {},
	compressed_size: u64 = 0,
	lowest_vcn: u64 = 0,
) -> []byte {
	name16 := utf16_of(name)
	has_cs := .Compressed in flags || .Sparse in flags
	hdr_len := size_of(Nonresident_Header) + (8 if has_cs else 0)
	name_ofs := hdr_len
	run_ofs := align8(name_ofs + len(name16) * 2)
	length := align8(run_ofs + len(runlist))
	b := make([]byte, length, context.temp_allocator)
	put32(b, 0, u32(type))
	put32(b, 4, u32(length))
	b[8] = 1
	b[9] = u8(len(name16))
	put16(b, 10, u16(name_ofs))
	put16(b, 12, transmute(u16)flags)
	put16(b, 14, 2)
	put64(b, 16, lowest_vcn)
	clusters := allocated / 4096
	if clusters > 0 {
		put64(b, 24, lowest_vcn + clusters - 1)
	}
	put16(b, 32, u16(run_ofs))
	put64(b, 40, allocated)
	put64(b, 48, data_size)
	put64(b, 56, data_size)
	if has_cs {
		put64(b, 64, compressed_size)
	}
	for c, i in name16 {
		put16(b, name_ofs + 2 * i, c)
	}
	copy(b[run_ofs:], runlist)
	return b
}

@(private = "file")
file_name_value :: proc(parent: File_Ref, name: string, ns: Name_Space, attrs: File_Attributes = {}) -> []byte {
	name16 := utf16_of(name)
	b := make([]byte, size_of(File_Name_Header) + 2 * len(name16), context.temp_allocator)
	put64(b, 0, u64(parent))
	put32(b, 0x38, transmute(u32)attrs)
	b[0x40] = u8(len(name16))
	b[0x41] = u8(ns)
	for c, i in name16 {
		put16(b, size_of(File_Name_Header) + 2 * i, c)
	}
	return b
}

@(private = "file")
standard_info_value :: proc(attrs: File_Attributes) -> []byte {
	b := make([]byte, 72, context.temp_allocator)
	put32(b, 0x20, transmute(u32)attrs)
	return b
}

// A 1024-byte record with fixups applied the way the file system writes them: the
// last two bytes of each 512-byte block are replaced by the sequence number and the
// displaced bytes are saved in the update sequence array.
@(private = "file")
build_record :: proc(
	attrs: [][]byte,
	record_number: u32 = 100,
	sequence: u16 = 7,
	flags: Record_Flags = {.In_Use},
	base: File_Ref = 0,
	link_count: u16 = 1,
) -> []byte {
	rec := make([]byte, 1024, context.temp_allocator)
	put32(rec, 0, RECORD_MAGIC)
	put16(rec, 4, 0x30) // update sequence array offset
	put16(rec, 6, 3) // sequence number + one entry per 512-byte block
	put16(rec, 0x10, sequence)
	put16(rec, 0x12, link_count)
	put16(rec, 0x14, 0x38) // first attribute
	put16(rec, 0x16, transmute(u16)flags)
	put64(rec, 0x20, u64(base))
	put32(rec, 0x2C, record_number)

	off := 0x38
	for a in attrs {
		copy(rec[off:], a)
		off += len(a)
	}
	put32(rec, off, u32(Attr_Type.End))
	off += 8
	put32(rec, 0x18, u32(off))
	put32(rec, 0x1C, 1024)
	assert(off <= 510, "test record too large: attributes overlap the first fixup")

	// Give the protected bytes recognisable values so a test can see them restored.
	put16(rec, 510, 0xABCD)
	put16(rec, 1022, 0xEF01)
	usn: u16 = 0x1234
	put16(rec, 0x30, usn)
	put16(rec, 0x32, rd16(rec, 510))
	put16(rec, 0x34, rd16(rec, 1022))
	put16(rec, 510, usn)
	put16(rec, 1022, usn)
	return rec
}

@(private = "file")
add :: proc(t: ^testing.T, m: ^Mft, rec: []byte) {
	testing.expect_value(t, apply_fixups(rec), Error.None)
	testing.expect_value(t, mft_add_record(m, record_header(rec).record_number, rec, &m.sinks[0]), Error.None)
	mft_merge_sinks(m)
}

// ---- boot sector --------------------------------------------------------------------

@(test)
test_boot_sector :: proc(t: ^testing.T) {
	b := make([]byte, 512, context.temp_allocator)
	copy(b[3:], "NTFS    ")
	put16(b, 0x0B, 512)
	b[0x0D] = 8
	put64(b, 0x28, 1_000_000)
	put64(b, 0x30, 786_432)
	put64(b, 0x38, 2)
	b[0x40] = 0xF6 // 2^10 bytes per record
	b[0x44] = 1 // one cluster per index block
	put64(b, 0x48, 0xDEADBEEF)
	b[0x1FE] = 0x55
	b[0x1FF] = 0xAA

	bs, err := parse_boot_sector(b)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, bs.bytes_per_cluster, u32(4096))
	testing.expect_value(t, bs.record_size, u32(1024))
	testing.expect_value(t, bs.index_block_size, u32(4096))
	testing.expect_value(t, bs.mft_lcn, u64(786_432))
	testing.expect_value(t, bs.serial, u64(0xDEADBEEF))

	// 0xF4 encodes 2^12 sectors per cluster: the 2 MiB clusters Windows 10 allows.
	b[0x0D] = 0xF4
	bs, err = parse_boot_sector(b)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, bs.bytes_per_cluster, u32(2 * 1024 * 1024))

	copy(b[3:], "MSDOS5.0")
	_, err = parse_boot_sector(b)
	testing.expect_value(t, err, Error.Not_Ntfs)
}

// ---- run lists ----------------------------------------------------------------------

@(test)
test_runlist :: proc(t: ^testing.T) {
	// 0x21: 1-byte length, 2-byte delta. 24 clusters at LCN 0x5634.
	// 0x11: 1-byte length, 1-byte delta of -16. 48 clusters at LCN 0x5624.
	// 0x01: 1-byte length, no delta. 16 sparse clusters.
	data := []byte{0x21, 0x18, 0x34, 0x56, 0x11, 0x30, 0xF0, 0x01, 0x10, 0x00}
	runs, err := decode_runlist(data, 0, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(runs), 3)
	testing.expect_value(t, runs[0], Run{vcn = 0, lcn = 0x5634, length = 0x18})
	testing.expect_value(t, runs[1], Run{vcn = 0x18, lcn = 0x5624, length = 0x30})
	testing.expect_value(t, runs[2], Run{vcn = 0x48, lcn = 0, length = 0x10, sparse = true})
	testing.expect_value(t, runlist_clusters(runs), u64(0x58))

	_, err = decode_runlist([]byte{0x21, 0x18}, 0, context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Runlist)

	// A delta that would take the LCN negative is corruption.
	_, err = decode_runlist([]byte{0x11, 0x01, 0xFF, 0x00}, 0, context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Runlist)
}

// ---- fixups -------------------------------------------------------------------------

@(test)
test_fixups :: proc(t: ^testing.T) {
	rec := build_record({})
	testing.expect_value(t, rd16(rec, 510), u16(0x1234))

	torn := make([]byte, 1024, context.temp_allocator)
	copy(torn, rec)
	put16(torn, 1022, 0x9999)
	testing.expect_value(t, apply_fixups(torn), Error.Bad_Record)

	testing.expect_value(t, apply_fixups(rec), Error.None)
	testing.expect_value(t, rd16(rec, 510), u16(0xABCD))
	testing.expect_value(t, rd16(rec, 1022), u16(0xEF01))

	put32(rec, 0, RECORD_MAGIC_BAD)
	testing.expect_value(t, apply_fixups(rec), Error.Bad_Record)
}

// ---- records into entries -----------------------------------------------------------

@(test)
test_resident_file :: proc(t: ^testing.T) {
	root := make_ref(RECORD_ROOT, 5)
	rec := build_record(
		{
			resident(.Standard_Information, standard_info_value({.Archive})),
			resident(.File_Name, file_name_value(root, "HELLOW~1.TXT", .Dos)),
			resident(.File_Name, file_name_value(root, "hello world.txt", .Win32)),
			resident(.Data, transmute([]byte)string("hello, world!")),
		},
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)
	add(t, &m, rec)

	e := m.entries[100]
	testing.expect_value(t, e.name, "hello world.txt")
	testing.expect_value(t, e.namespace, Name_Space.Win32)
	testing.expect_value(t, e.parent, u32(RECORD_ROOT))
	testing.expect_value(t, e.parent_sequence, u16(5))
	testing.expect_value(t, e.sequence, u16(7))
	testing.expect_value(t, e.size, u64(13))
	testing.expect_value(t, e.allocated, u64(0))
	testing.expect(t, .In_Use in e.flags)
	testing.expect(t, .Directory not_in e.flags)
	testing.expect(t, .Archive in e.attributes)
	testing.expect_value(t, len(m.links), 0)
	testing.expect_value(t, m.stats.in_use, u64(1))
}

@(test)
test_dos_name_first_is_replaced :: proc(t: ^testing.T) {
	root := make_ref(RECORD_ROOT, 5)
	rec := build_record(
		{
			resident(.File_Name, file_name_value(root, "LONGNA~1.TXT", .Dos)),
			resident(.File_Name, file_name_value(root, "long name.txt", .Win32)),
		},
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)
	add(t, &m, rec)
	testing.expect_value(t, m.entries[100].name, "long name.txt")
	testing.expect_value(t, len(m.links), 0)
}

@(test)
test_nonresident_streams :: proc(t: ^testing.T) {
	two_clusters := []byte{0x11, 0x02, 0x10, 0x00}
	one_cluster := []byte{0x11, 0x01, 0x20, 0x00}
	// 16 allocated clusters followed by 240 sparse ones: a 1 MiB compressed stream
	// that squeezed into 64 KiB.
	compressed := []byte{0x11, 0x10, 0x30, 0x01, 0xF0, 0x00}
	rec := build_record(
		{
			resident(.File_Name, file_name_value(make_ref(64, 3), "big.bin", .Win32_And_Dos)),
			nonresident(.Data, 8192, 5000, two_clusters),
			nonresident(.Data, 4096, 100, one_cluster, name = "Zone.Identifier"),
			nonresident(.Data, 1 << 20, 1 << 20, compressed, name = "packed", flags = {.Compressed}, compressed_size = 65536),
		},
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)
	add(t, &m, rec)

	e := m.entries[100]
	testing.expect_value(t, e.size, u64(5000)) // unnamed stream only
	testing.expect_value(t, e.allocated, u64(8192 + 4096 + 65536)) // every stream, measured from run lists
	testing.expect_value(t, e.parent, u32(64))
	testing.expect_value(t, e.parent_sequence, u16(3))
}

@(test)
test_fragmented_extents_sum_their_own_clusters :: proc(t: ^testing.T) {
	// Both extents repeat the header sizes (8192 allocated) but each maps one cluster.
	rec := build_record(
		{
			resident(.File_Name, file_name_value(make_ref(RECORD_ROOT, 5), "frag.bin", .Win32)),
			nonresident(.Data, 8192, 8000, []byte{0x11, 0x01, 0x10, 0x00}),
			nonresident(.Data, 8192, 8000, []byte{0x11, 0x01, 0x40, 0x00}, lowest_vcn = 1),
		},
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)
	add(t, &m, rec)
	testing.expect_value(t, m.entries[100].allocated, u64(8192))
	testing.expect_value(t, m.entries[100].size, u64(8000))
}

@(test)
test_unallocated_runlist_counts_nothing :: proc(t: ^testing.T) {
	// $BadClus:$Bad spans the whole volume with sparse runs and no sparse flag.
	rec := build_record(
		{
			resident(.File_Name, file_name_value(make_ref(RECORD_ROOT, 5), "$BadClus", .Win32_And_Dos)),
			nonresident(.Data, 0, 0, []byte{0x00}),
			nonresident(.Data, 1 << 40, 1 << 40, []byte{0x04, 0x00, 0x00, 0x00, 0x10, 0x00}, name = "$Bad"),
		},
		record_number = RECORD_BAD_CLUS,
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)
	add(t, &m, rec)
	testing.expect_value(t, m.entries[RECORD_BAD_CLUS].allocated, u64(0))
}

@(test)
test_runlist_allocated_clusters :: proc(t: ^testing.T) {
	clusters, ok := runlist_allocated_clusters([]byte{0x11, 0x10, 0x30, 0x01, 0xF0, 0x00})
	testing.expect(t, ok)
	testing.expect_value(t, clusters, u64(16))
	_, ok = runlist_allocated_clusters([]byte{0x21, 0x18})
	testing.expect(t, !ok)
}

@(test)
test_extension_record_and_hard_links :: proc(t: ^testing.T) {
	base := build_record(
		{resident(.File_Name, file_name_value(make_ref(RECORD_ROOT, 5), "a.txt", .Win32))},
		record_number = 100,
		sequence = 9,
		link_count = 2,
	)
	ext := build_record(
		{
			resident(.File_Name, file_name_value(make_ref(70, 2), "b.txt", .Win32)),
			nonresident(.Data, 4096, 10, []byte{0x11, 0x01, 0x20, 0x00}),
		},
		record_number = 101,
		base = make_ref(100, 9),
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)

	// The extension arrives before its base, as it can on disk.
	add(t, &m, ext)
	add(t, &m, base)

	e := m.entries[100]
	testing.expect_value(t, e.name, "b.txt") // first proper name seen wins
	testing.expect_value(t, e.parent, u32(70))
	testing.expect_value(t, e.allocated, u64(4096))
	testing.expect_value(t, e.size, u64(10))
	testing.expect_value(t, e.sequence, u16(9))
	testing.expect_value(t, e.link_count, u16(2))
	testing.expect_value(t, len(m.links), 1)
	testing.expect_value(t, m.links[0].record, u32(100))
	testing.expect_value(t, m.links[0].parent, u32(RECORD_ROOT))
	testing.expect_value(t, m.links[0].name, "a.txt")

	// The extension slot itself is not a file.
	testing.expect_value(t, m.entries[101].name, "")
	testing.expect_value(t, m.stats.in_use, u64(1))
}

@(test)
test_free_record_is_ignored :: proc(t: ^testing.T) {
	rec := build_record(
		{resident(.File_Name, file_name_value(make_ref(RECORD_ROOT, 5), "deleted.txt", .Win32))},
		flags = {},
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)
	add(t, &m, rec)
	testing.expect_value(t, m.entries[100].name, "")
	testing.expect_value(t, m.stats.in_use, u64(0))
}

// ---- paths --------------------------------------------------------------------------

@(test)
test_path :: proc(t: ^testing.T) {
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)

	root := make_ref(RECORD_ROOT, 5)
	add(t, &m, build_record(
		{resident(.File_Name, file_name_value(root, ".", .Win32))},
		record_number = RECORD_ROOT,
		sequence = 5,
		flags = {.In_Use, .Directory},
	))
	add(t, &m, build_record(
		{resident(.File_Name, file_name_value(root, "Windows", .Win32))},
		record_number = 64,
		sequence = 1,
		flags = {.In_Use, .Directory},
	))
	add(t, &m, build_record(
		{resident(.File_Name, file_name_value(make_ref(64, 1), "explorer.exe", .Win32))},
		record_number = 65,
		sequence = 1,
	))
	// Parent sequence 99 does not match record 64's sequence 1: the directory this
	// file was in has been deleted and its record reused.
	add(t, &m, build_record(
		{resident(.File_Name, file_name_value(make_ref(64, 99), "stale.tmp", .Win32))},
		record_number = 66,
		sequence = 1,
	))

	testing.expect_value(t, mft_path(&m, 65, context.temp_allocator), `\Windows\explorer.exe`)
	testing.expect_value(t, mft_path(&m, 64, context.temp_allocator), `\Windows`)
	testing.expect_value(t, mft_path(&m, RECORD_ROOT, context.temp_allocator), `\`)
	testing.expect_value(t, mft_path(&m, 66, context.temp_allocator), `<orphan>\stale.tmp`)
}

// ---- bitmap -------------------------------------------------------------------------

@(test)
test_count_set_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, count_set_bits(nil), u64(0))
	testing.expect_value(t, count_set_bits([]byte{0xFF}), u64(8))

	// Nine bytes exercises both the eight-byte chunk loop and the trailing bytes.
	nine := []byte{0xFF, 0x00, 0x0F, 0xF0, 0x01, 0x80, 0xAA, 0x55, 0x03}
	testing.expect_value(t, count_set_bits(nine), u64(28))

	all := make([]byte, 64, context.temp_allocator)
	for i in 0 ..< len(all) {
		all[i] = 0xFF
	}
	testing.expect_value(t, count_set_bits(all), u64(512))
}

// ---- resident data ------------------------------------------------------------------

@(test)
test_resident_file_costs_no_clusters :: proc(t: ^testing.T) {
	rec := build_record(
		{
			resident(.File_Name, file_name_value(make_ref(RECORD_ROOT, 5), "tiny.txt", .Win32)),
			resident(.Data, transmute([]byte)string("hello")),
		},
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)
	add(t, &m, rec)

	// The bytes live inside the MFT record, so the file itself allocates nothing and
	// the stats record what the directory totals will therefore miss.
	testing.expect_value(t, m.entries[100].size, u64(5))
	testing.expect_value(t, m.entries[100].allocated, u64(0))
	testing.expect_value(t, m.stats.resident_files, u64(1))
	testing.expect_value(t, m.stats.resident_bytes, u64(5))
}
