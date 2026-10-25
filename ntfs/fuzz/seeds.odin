package ntfs_fuzz

import "core:unicode/utf16"

import ntfs ".."

// The shapes ntfs/ntfs_test.odin builds, as damage's starting points. The unit
// tests keep their builders to themselves, and there is no NTFS image in the
// repository to take bytes from, so these are the same bytes made again: a
// record with each attribute kind the reader walks (resident, nonresident,
// named, compressed, a hard link's second name, an extension record), the
// boot sectors whose cluster sizes the tests take apart, and the run lists
// they decode. A mutation of one of these starts past the magic, the update
// sequence and the attribute chain, where a length can be trusted.
//
// The zero case is still the first seed of each list.

// boots are the boot sectors: 4096-byte clusters, the 2 MiB cluster that 0xF4
// encodes as an exponent, and the literal 128 sectors of 0x80.
@(private)
boots :: proc(allocator := context.allocator) -> [][]byte {
	out := make([][]byte, 3, allocator)
	out[0] = boot_seed()
	out[1] = boot_seed()
	out[1][0x0D] = 0xF4
	out[2] = boot_seed()
	out[2][0x0D] = 0x80
	put64(out[2], 0x28, 128 * 4)
	put64(out[2], 0x30, 1)
	return out
}

// runlists are the ones test_runlist, test_nonresident_streams and the
// fragment tests decode: signed deltas, a sparse run, a compressed stream's
// sparse tail, a run of one cluster.
@(private)
RUNLISTS := [][]byte {
	{0x21, 0x18, 0x34, 0x56, 0x11, 0x30, 0xF0, 0x01, 0x10, 0x00},
	{0x11, 0x02, 0x10, 0x00},
	{0x11, 0x10, 0x30, 0x01, 0xF0, 0x00},
	{0x31, 0x01, 0x02, 0x03, 0x04, 0x00},
	{0x42, 0x08, 0x00, 0x10, 0x00, 0x01, 0x00},
}

@(private)
runlists :: proc() -> [][]byte {
	return RUNLISTS
}

// records are the FILE records the tests read, each with fixups applied.
@(private)
records :: proc(allocator := context.allocator) -> [][]byte {
	context.allocator = allocator

	two_clusters := []byte{0x11, 0x02, 0x10, 0x00}
	compressed := []byte{0x11, 0x10, 0x30, 0x01, 0xF0, 0x00}
	one_cluster := []byte{0x11, 0x01, 0x20, 0x00}
	out := make([dynamic][]byte, allocator)
	// A resident name of one letter: the zero case.
	append(&out, file_record())
	// Standard information, a name in the Win32 and DOS namespace, and a
	// nonresident stream (test_nonresident_streams).
	append(
		&out,
		record_with(
			{
				resident(u32(ntfs.Attr_Type.Standard_Information), make([]byte, 72)),
				resident(u32(ntfs.Attr_Type.File_Name), name_value(64, "big.bin", 3)),
				nonresident(u32(ntfs.Attr_Type.Data), 8192, 5000, two_clusters, ""),
			},
		),
	)
	// A named stream beside the unnamed one, and a compressed stream.
	append(
		&out,
		record_with(
			{
				resident(u32(ntfs.Attr_Type.File_Name), name_value(5, "streams", 1)),
				nonresident(u32(ntfs.Attr_Type.Data), 4096, 100, one_cluster, "Zone.Identifier"),
				nonresident(
					u32(ntfs.Attr_Type.Data),
					1 << 20,
					1 << 20,
					compressed,
					"packed",
					compressed = true,
				),
			},
		),
	)
	// An extension record: its base is record 2 (test_extension_record_and_hard_links).
	append(
		&out,
		record_with(
			{
				resident(u32(ntfs.Attr_Type.File_Name), name_value(5, "b.txt", 1)),
				nonresident(u32(ntfs.Attr_Type.Data), 4096, 10, one_cluster, ""),
			},
			number = 3,
			base = 2 | 9 << 48,
		),
	)
	// A directory: an index root and no data.
	append(
		&out,
		record_with(
			{
				resident(u32(ntfs.Attr_Type.File_Name), name_value(5, "dir", 1)),
				resident(u32(ntfs.Attr_Type.Index_Root), make([]byte, 32), "$I30"),
			},
			directory = true,
		),
	)
	return out[:]
}

// name_value is a $FILE_NAME value: parent record, namespace, UTF-16 name.
@(private)
name_value :: proc(
	parent: u64,
	name: string,
	namespace: u8,
	allocator := context.allocator,
) -> []byte {
	units: [32]u16
	n := utf16.encode_string(units[:], name)
	b := make([]byte, 66 + 2 * n, allocator)
	put64(b, 0, parent | 1 << 48)
	b[0x40] = u8(n)
	b[0x41] = namespace
	for c, i in units[:n] {
		put16(b, 66 + 2 * i, c)
	}
	return b
}

// nonresident is an attribute with its data in clusters elsewhere, the header
// ntfs_test.odin's builder writes.
@(private)
nonresident :: proc(
	type: u32,
	allocated, data_size: u64,
	runlist: []byte,
	name: string,
	compressed := false,
	allocator := context.allocator,
) -> []byte {
	units: [32]u16
	n := utf16.encode_string(units[:], name)
	header := size_of(ntfs.Nonresident_Header) + (8 if compressed else 0)
	run_at := (header + 2 * n + 7) & ~int(7)
	length := (run_at + len(runlist) + 7) & ~int(7)
	b := make([]byte, length, allocator)
	put32(b, 0, type)
	put32(b, 4, u32(length))
	b[8] = 1
	b[9] = u8(n)
	put16(b, 10, u16(header))
	if compressed {
		put16(b, 12, 1)
	}
	put16(b, 14, 2)
	if allocated >= 4096 {
		put64(b, 24, allocated / 4096 - 1)
	}
	put16(b, 32, u16(run_at))
	put64(b, 40, allocated)
	put64(b, 48, data_size)
	put64(b, 56, data_size)
	if compressed {
		put64(b, 64, 65536)
	}
	for c, i in units[:n] {
		put16(b, header + 2 * i, c)
	}
	copy(b[run_at:], runlist)
	return b
}
