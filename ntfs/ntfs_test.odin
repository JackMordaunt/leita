package ntfs

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "core:unicode/utf16"

import "../scan"

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
file_name_value :: proc(
	parent: File_Ref,
	name: string,
	ns: Name_Space,
	attrs: File_Attributes = {},
) -> []byte {
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
	testing.expect_value(
		t,
		mft_add_record(m, record_header(rec).record_number, rec, &m.sinks[0]),
		Error.None,
	)
	mft_merge_sinks(m)
}

// ---- boot sector --------------------------------------------------------------------

@(test)
test_boot_sector :: proc(t: ^testing.T) {
	b := make([]byte, 512, context.temp_allocator)
	copy(b[3:], "NTFS    ")
	put16(b, 0x0B, 512)
	b[0x0D] = 8
	// The same LCN has to sit inside the volume for 8 sectors per cluster and for
	// the 2 MiB clusters below, where one cluster is 4096 sectors.
	put64(b, 0x28, 786_432 * 4096 + 4096)
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

// A boot sector whose sizes the volume cannot mean.
@(test)
test_boot_sector_rejects_what_it_cannot_mean :: proc(t: ^testing.T) {
	// 0x80 is the literal 128 sectors: 128 * 512 = 64 KiB. A byte above 0x80 is
	// an exponent; 0x80 is not.
	wide := boot_sector(0x80, 128 * 4, 1)
	bs, err := parse_boot_sector(wide)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, bs.sectors_per_cluster, u32(128))
	testing.expect_value(t, bs.bytes_per_cluster, u32(64 * 1024))

	// 0xE0 encodes 2^(256-0xE0) = 2^32 sectors. The shift does not fit in u32.
	_, err = parse_boot_sector(boot_sector(0xE0, 1 << 20, 1))
	testing.expect_value(t, err, Error.Bad_Boot_Sector)

	// 0xE9 encodes 2^23 sectors. 512 * 2^23 = 2^32, which wraps the u32 cluster size.
	_, err = parse_boot_sector(boot_sector(0xE9, 1 << 25, 1))
	testing.expect_value(t, err, Error.Bad_Boot_Sector)

	// Ten clusters, and the MFT claims the one just past the last.
	_, err = parse_boot_sector(boot_sector(8, 80, 10))
	testing.expect_value(t, err, Error.Bad_Boot_Sector)
}

@(private = "file")
boot_sector :: proc(sectors_per_cluster: byte, total_sectors, mft_lcn: u64) -> []byte {
	b := make([]byte, 512, context.temp_allocator)
	copy(b[3:], "NTFS    ")
	put16(b, 0x0B, 512)
	b[0x0D] = sectors_per_cluster
	put64(b, 0x28, total_sectors)
	put64(b, 0x30, mft_lcn)
	put64(b, 0x38, 2)
	b[0x40] = 0xF6
	b[0x44] = 1
	put64(b, 0x48, 0xDEADBEEF)
	b[0x1FE] = 0x55
	b[0x1FF] = 0xAA
	return b
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

	// A length of zero is not a run. The reader would otherwise never advance.
	_, err = decode_runlist([]byte{0x11, 0x00, 0x01, 0x00}, 0, context.temp_allocator)
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
	testing.expect_value(t, e.allocated, u64(len("hello, world!")))
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
			nonresident(
				.Data,
				1 << 20,
				1 << 20,
				compressed,
				name = "packed",
				flags = {.Compressed},
				compressed_size = 65536,
			),
		},
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 128, 4096, 1), Error.None)
	defer mft_destroy(&m)
	add(t, &m, rec)

	e := m.entries[100]
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
}

@(test)
test_unallocated_runlist_counts_nothing :: proc(t: ^testing.T) {
	// $BadClus:$Bad spans the whole volume with sparse runs and no sparse flag.
	rec := build_record(
		{
			resident(
				.File_Name,
				file_name_value(make_ref(RECORD_ROOT, 5), "$BadClus", .Win32_And_Dos),
			),
			nonresident(.Data, 0, 0, []byte{0x00}),
			nonresident(
				.Data,
				1 << 40,
				1 << 40,
				[]byte{0x04, 0x00, 0x00, 0x00, 0x10, 0x00},
				name = "$Bad",
			),
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

	// Two runs of 2^63 clusters. The sum does not fit in u64, and a wrapped total
	// would under-count the file.
	huge := []byte {
		0x18,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x80,
		0x01,
		0x18,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x00,
		0x80,
		0x01,
		0x00,
	}
	_, ok = runlist_allocated_clusters(huge)
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
	add(
		t,
		&m,
		build_record(
			{resident(.File_Name, file_name_value(root, ".", .Win32))},
			record_number = RECORD_ROOT,
			sequence = 5,
			flags = {.In_Use, .Directory},
		),
	)
	add(
		t,
		&m,
		build_record(
			{resident(.File_Name, file_name_value(root, "Windows", .Win32))},
			record_number = 64,
			sequence = 1,
			flags = {.In_Use, .Directory},
		),
	)
	add(
		t,
		&m,
		build_record(
			{resident(.File_Name, file_name_value(make_ref(64, 1), "explorer.exe", .Win32))},
			record_number = 65,
			sequence = 1,
		),
	)
	// Parent sequence 99 does not match record 64's sequence 1: the directory this
	// file was in has been deleted and its record reused.
	add(
		t,
		&m,
		build_record(
			{resident(.File_Name, file_name_value(make_ref(64, 99), "stale.tmp", .Win32))},
			record_number = 66,
			sequence = 1,
		),
	)

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
test_resident_file_reports_its_length :: proc(t: ^testing.T) {
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

	// The bytes sit in the file's MFT record, so the clusters belong to $MFT. The
	// entry still carries the length, or a directory of small files shows as empty.
	testing.expect_value(t, m.entries[100].allocated, u64(5))
	testing.expect_value(t, m.stats.resident_files, u64(1))
	testing.expect_value(t, m.stats.resident_bytes, u64(5))
}

// ---- projecting a subtree -----------------------------------------------------------

// One record holding one name, and `clusters` of data when it is a file.
@(private = "file")
put_record :: proc(
	t: ^testing.T,
	m: ^Mft,
	number: u32,
	parent: File_Ref,
	name: string,
	clusters: u8 = 0,
	directory := false,
	sequence: u16 = 1,
) {
	attrs := make([dynamic][]byte, context.temp_allocator)
	append(&attrs, resident(.File_Name, file_name_value(parent, name, .Win32)))
	if clusters > 0 {
		bytes := u64(clusters) * 4096
		append(&attrs, nonresident(.Data, bytes, bytes, []byte{0x11, clusters, 0x10, 0x00}))
	}
	flags := Record_Flags{.In_Use, .Directory} if directory else Record_Flags{.In_Use}
	add(t, m, build_record(attrs[:], record_number = number, sequence = sequence, flags = flags))
}

// One file of one cluster with a second name in another directory.
@(private = "file")
put_linked :: proc(t: ^testing.T, m: ^Mft, number: u32, first, second: File_Ref, a, b: string) {
	rec := build_record(
		{
			resident(.File_Name, file_name_value(first, a, .Win32)),
			resident(.File_Name, file_name_value(second, b, .Win32)),
			nonresident(.Data, 4096, 4096, []byte{0x11, 0x01, 0x10, 0x00}),
		},
		record_number = number,
		link_count = 2,
	)
	add(t, m, rec)
}

@(private = "file")
TEMP :: 67 // the folder a subtree projection is rooted at
@(private = "file")
SUB :: 74 // a folder inside it

/*
A volume with a folder of a few files, C:\Users\ann\temp, beside a Windows folder of
300 others, and the records a subtree must keep out even though they point near it.
The folder's own record and its subfolder are left for the caller to add, so a test
can see what waits on them.
*/
@(private = "file")
volume_around_a_folder :: proc(t: ^testing.T, m: ^Mft) {
	root := make_ref(RECORD_ROOT, 5)
	put_record(t, m, RECORD_ROOT, root, ".", directory = true, sequence = 5)
	put_record(t, m, 64, root, "Windows", directory = true)
	windows := make_ref(64, 1)
	for i in u32(200) ..< 500 {
		put_record(t, m, i, windows, "system.dll", clusters = 1)
	}
	put_record(t, m, 65, root, "Users", directory = true)
	put_record(t, m, 66, make_ref(65, 1), "ann", directory = true)

	temp := make_ref(TEMP, 3)
	put_record(t, m, 70, temp, "a.txt", clusters = 1)
	put_record(t, m, 71, temp, "b.txt", clusters = 2)
	put_record(t, m, 72, temp, "c.txt", clusters = 3)
	put_record(t, m, 73, temp, "d.txt", clusters = 4)
	put_record(t, m, 75, make_ref(SUB, 1), "e.txt", clusters = 1)
	// Counted where it lives, in Windows; here only as another name for it.
	put_linked(t, m, 76, windows, temp, "linked.txt", "here.txt")
	// Lives here; its other name, in Windows, is no path into this folder.
	put_linked(t, m, 77, temp, windows, "away.txt", "there.txt")
	// Two folders each naming the other as parent, which only a damaged table holds.
	put_record(t, m, 80, make_ref(81, 1), "round", directory = true)
	put_record(t, m, 81, make_ref(80, 1), "about", directory = true)
	// Written for an earlier folder in temp's slot, so it was never in this one.
	put_record(t, m, 82, make_ref(TEMP, 99), "stale.txt", clusters = 1)
}

// The names of every used node, the way a search reads the tree: by slot, not by
// following the root down.
@(private = "file")
used_names :: proc(tree: ^scan.Tree) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< scan.slots(tree) {
		if .Used in scan.node_flags(scan.node(tree, i)) {
			append(&names, scan.name_of(tree, i))
		}
	}
	slice.sort(names[:])
	return names[:]
}

// Whether every used node's parents lead to the tree's root.
@(private = "file")
all_under_root :: proc(tree: ^scan.Tree) -> bool {
	for i in 0 ..< scan.slots(tree) {
		if .Used not_in scan.node_flags(scan.node(tree, i)) {
			continue
		}
		r := i
		for depth := 0; scan.node(tree, r).parent != r; depth += 1 {
			if depth > 64 {
				return false
			}
			r = scan.node(tree, r).parent
		}
		if r != tree.root {
			return false
		}
	}
	return true
}

@(test)
test_a_tree_rooted_at_a_folder_holds_only_that_folder :: proc(t: ^testing.T) {
	m: Mft
	testing.expect_value(t, mft_init(&m, 1024, 4096, 1), Error.None)
	defer mft_destroy(&m)
	volume_around_a_folder(t, &m)
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree), scan.Error.None)
	defer scan.tree_destroy(&tree)
	p := Projection {
		root_name   = `C:\Users\ann\temp`,
		root_record = TEMP,
	}
	defer projection_destroy(&p)

	// The folder is not read yet, so nothing waiting on it is known to be in it, and
	// nothing else of the volume is in the tree meanwhile.
	testing.expect_value(t, to_tree(&m, &tree, &p), scan.Error.None)
	testing.expect_value(t, len(used_names(&tree)), 0)
	testing.expect_value(t, tree.nodes_done, u64(0))

	put_record(t, &m, TEMP, make_ref(66, 1), "temp", directory = true, sequence = 3)
	testing.expect_value(t, to_tree(&m, &tree, &p), scan.Error.None)
	testing.expect_value(t, tree.nodes_done, u64(6)) // temp, a to d, away
	testing.expect(t, all_under_root(&tree), "a node outside the folder")

	put_record(t, &m, SUB, make_ref(TEMP, 3), "sub", directory = true)
	testing.expect_value(t, to_tree(&m, &tree, &p), scan.Error.None)
	testing.expect_value(t, tree.nodes_done, u64(8))

	// Hard links arrive once the table is complete, and the last pass redoes every
	// record, which is the answer a scan ends on.
	mft_set_complete(&m)
	testing.expect_value(t, to_tree(&m, &tree, &p), scan.Error.None)
	projection_reset(&p)
	testing.expect_value(t, to_tree(&m, &tree, &p), scan.Error.None)

	want := []string {
		`C:\Users\ann\temp`,
		"a.txt",
		"away.txt",
		"b.txt",
		"c.txt",
		"d.txt",
		"e.txt",
		"here.txt",
		"sub",
	}
	got := used_names(&tree)
	testing.expectf(t, slice.equal(got, want), "used nodes %v, want %v", got, want)
	testing.expect(t, all_under_root(&tree), "a node outside the folder")
	testing.expect_value(t, tree.root, u32(TEMP))
	// here.txt is another name for a file counted in Windows, so it adds nothing.
	testing.expect_value(t, tree.nodes_done, u64(8))
	testing.expect_value(t, tree.bytes_done, u64((1 + 2 + 3 + 4 + 1 + 1) * 4096))
}

@(test)
test_a_tree_of_the_whole_volume_keeps_every_record :: proc(t: ^testing.T) {
	// The same table rooted at the volume, so the test above is known to be keeping
	// something out rather than finding nothing there to keep.
	m: Mft
	testing.expect_value(t, mft_init(&m, 1024, 4096, 1), Error.None)
	defer mft_destroy(&m)
	volume_around_a_folder(t, &m)
	put_record(t, &m, TEMP, make_ref(66, 1), "temp", directory = true, sequence = 3)
	put_record(t, &m, SUB, make_ref(TEMP, 3), "sub", directory = true)
	mft_set_complete(&m)
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree), scan.Error.None)
	defer scan.tree_destroy(&tree)
	p := Projection {
		root_name = `C:\`,
	}
	defer projection_destroy(&p)

	testing.expect_value(t, to_tree(&m, &tree, &p), scan.Error.None)
	testing.expect_value(t, tree.root, u32(RECORD_ROOT))
	// The root, Windows with its 300 and linked.txt, Users, ann, temp with its
	// 7, the loop of two and the stale file; then the two extra names.
	testing.expect_value(t, tree.nodes_done, u64(1 + 302 + 2 + 8 + 2 + 1))
	testing.expect_value(t, len(used_names(&tree)), 1 + 302 + 2 + 8 + 2 + 1 + 2)
}

// A run whose byte length does not fit in u64 must fail rather than spin: the
// reader adds the bytes it got, and a product of 0 means it never moves.
@(test)
test_read_logical_rejects_a_run_that_yields_nothing :: proc(t: ^testing.T) {
	// 2^52 clusters of 4096 bytes is 2^64 bytes, which wraps to 0.
	r := Extent_Reader {
		runs    = []Run{{vcn = 0, lcn = 1, length = 1 << 52}},
		cluster = 4096,
	}
	buf := make([]byte, 16, context.temp_allocator)
	testing.expect_value(t, read_logical(&r, 0, buf), Error.Bad_Runlist)
}

// ---- short $MFT:$BITMAP -------------------------------------------------------------

@(test)
test_short_bitmap_does_not_cover_the_table :: proc(t: ^testing.T) {
	// One cluster of bitmap bytes, one short of the attribute's data_size.
	short := make([]byte, 512, context.temp_allocator)
	testing.expect(t, !bitmap_covers(short, 513, 4097 * 1024, 1024))

	// data_size is covered, but 4097 records need 513 bytes of bits.
	tiny := []byte{0xFF}
	testing.expect(t, !bitmap_covers(tiny, 1, 4097 * 1024, 1024))

	whole := make([]byte, 513, context.temp_allocator)
	testing.expect(t, bitmap_covers(whole, 513, 4097 * 1024, 1024))
}

// $MFT:$BITMAP's run list covers one byte less than its data_size, so the tail
// record's bit is past the buffer. The scan has to read that record anyway.
@(test)
test_short_bitmap_still_reads_the_tail :: proc(t: ^testing.T) {
	cluster := 512
	record_size := 1024
	mft_lcn := 8
	bitmap_lcn := 7
	tail := 4096 // first record whose bit sits past a 512-byte bitmap
	records := tail + 1
	mft_bytes := records * record_size
	mft_clusters := mft_bytes / cluster
	// The $DATA run list below is this count, little-endian, in two bytes.
	assert(mft_clusters == 0x2002, "mft run list length is hardcoded as 0x2002")
	image_bytes := (mft_lcn + mft_clusters) * cluster

	img := make([]byte, image_bytes)
	defer delete(img)

	boot := boot_sector(1, u64(image_bytes / 512), u64(mft_lcn))
	copy(img, boot)
	// Record 0 is live. Every later bit in the covered cluster stays clear, and
	// the tail's bit is not in the cluster at all.
	img[bitmap_lcn * cluster] = 0x01

	// 2-byte length, 1-byte LCN. 8194 clusters starting at LCN 8.
	mft_run := []byte{0x12, 0x02, 0x20, 0x08, 0x00}
	bitmap_run := []byte{0x11, 0x01, 0x07, 0x00}
	rec0 := build_record(
		{
			nonresident(.Data, u64(mft_bytes), u64(mft_bytes), mft_run),
			nonresident(.Bitmap, u64(cluster), 513, bitmap_run),
		},
		record_number = 0,
		sequence = 1,
	)
	copy(img[mft_lcn * cluster:], rec0)

	tail_at := mft_lcn * cluster + tail * record_size
	tail_rec := build_record(
		{resident(.File_Name, file_name_value(make_ref(RECORD_ROOT, 1), "tail.txt", .Win32))},
		record_number = u32(tail),
		sequence = 1,
	)
	copy(img[tail_at:], tail_rec)

	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	path := fmt.tprintf("%s/leita_ntfs_short_bitmap_%d.img", dir, os.get_pid())
	testing.expect(t, os.write_entire_file(path, img) == nil, "could not write the image")
	defer os.remove(path)

	v, open_err := volume_open(path)
	testing.expect_value(t, open_err, Error.None)
	defer volume_close(&v)

	m: Mft
	// min_skip of 1 makes any gap in the bitmap a skip, so a short bitmap would
	// leave the tail unread. workers 1 keeps the read on this thread.
	err := read_mft_from_volume(&v, &m, Read_Options{min_skip = 1, workers = 1})
	testing.expect_value(t, err, Error.None)
	if err != nil {
		return
	}
	defer mft_destroy(&m)
	testing.expect_value(t, m.entries[tail].name, "tail.txt")
}

// A record shorter than its header used to be read as a header anyway.
@(test)
test_a_short_record_is_not_read_past :: proc(t: ^testing.T) {
	rec := []byte{0x46, 0x49}
	it := attributes(rec)
	_, ok := next_attribute(&it)
	testing.expect(t, !ok, "a short record has no attribute")
}

// (1<<52)+1 clusters of 4096 bytes is 2^64+4096, which wraps to 4096.
@(test)
test_a_wrapping_cluster_count_is_not_a_small_file :: proc(t: ^testing.T) {
	runlist := []byte {
		0x18,
		0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
		0x01,
		0x00,
	}
	rec := build_record(
		{nonresident(.Data, 0, 0, runlist)},
		record_number = 1,
	)
	m: Mft
	testing.expect_value(t, mft_init(&m, 4, 4096, 1), Error.None)
	defer mft_destroy(&m)
	testing.expect_value(t, apply_fixups(rec), Error.None)
	it := attributes(rec)
	a, a_ok := next_attribute(&it)
	testing.expect(t, a_ok, "the data attribute is there")
	n, fit := attr_disk_size(a, 4096)
	testing.expect(t, !fit, "the cluster multiply must be refused")
	testing.expect_value(t, n, u64(0))
	testing.expect_value(
		t,
		mft_add_record(&m, 1, rec, &m.sinks[0]),
		Error.None,
	)
	testing.expect_value(t, m.entries[1].allocated, u64(0))
}

// A VCN that wraps is a corrupt length, not a run that starts over.
@(test)
test_a_wrapping_vcn_is_a_bad_runlist :: proc(t: ^testing.T) {
	data := []byte {
		0x18,
		0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
		0x01,
		0x11,
		0x01,
		0x00,
		0x00,
	}
	_, err := decode_runlist(data, 1, context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Runlist)
}
