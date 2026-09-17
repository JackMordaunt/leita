package ntfs

import "core:mem"

RECORD_MAGIC :: u32(0x454C4946) // "FILE"
RECORD_MAGIC_BAD :: u32(0x44414142) // "BAAD": chkdsk marked the record as damaged

// Fixups protect every 512 bytes regardless of the physical sector size.
FIXUP_BLOCK :: 512

Record_Flag :: enum u16 {
	In_Use     = 0,
	Directory  = 1,
	Extension  = 2, // record lives in $Extend
	View_Index = 3,
}
Record_Flags :: bit_set[Record_Flag; u16]

Record_Header :: struct #packed {
	magic:           u32,
	usa_offset:      u16, // update sequence array
	usa_count:       u16, // entries in the array, including the sequence number itself
	lsn:             u64, // $LogFile sequence number
	sequence:        u16,
	link_count:      u16, // hard links, i.e. number of $FILE_NAME attributes across all namespaces
	attrs_offset:    u16,
	flags:           Record_Flags,
	bytes_in_use:    u32,
	bytes_allocated: u32,
	base_record:     File_Ref, // 0 for a base record; otherwise this is an extension record
	next_attr_id:    u16,
	_pad:            u16,
	record_number:   u32, // NTFS 3.1+
}
#assert(size_of(Record_Header) == 48)

Attr_Type :: enum u32 {
	Standard_Information  = 0x10,
	Attribute_List        = 0x20,
	File_Name             = 0x30,
	Object_Id             = 0x40,
	Security_Descriptor   = 0x50,
	Volume_Name           = 0x60,
	Volume_Information    = 0x70,
	Data                  = 0x80,
	Index_Root            = 0x90,
	Index_Allocation      = 0xA0,
	Bitmap                = 0xB0,
	Reparse_Point         = 0xC0,
	EA_Information        = 0xD0,
	EA                    = 0xE0,
	Logged_Utility_Stream = 0x100,
	End                   = 0xFFFFFFFF,
}

Attr_Flag :: enum u16 {
	Compressed = 0,
	Encrypted  = 14,
	Sparse     = 15,
}
Attr_Flags :: bit_set[Attr_Flag; u16]

Attr_Header :: struct #packed {
	type:         Attr_Type,
	length:       u32, // whole attribute record, header included, 8-byte aligned
	non_resident: u8,
	name_length:  u8, // in UTF-16 code units
	name_offset:  u16,
	flags:        Attr_Flags,
	id:           u16,
}
#assert(size_of(Attr_Header) == 16)

Resident_Header :: struct #packed {
	hdr:          Attr_Header,
	value_length: u32,
	value_offset: u16,
	indexed:      u8,
	_pad:         u8,
}
#assert(size_of(Resident_Header) == 24)

Nonresident_Header :: struct #packed {
	hdr:              Attr_Header,
	lowest_vcn:       u64,
	highest_vcn:      u64,
	runlist_offset:   u16,
	compression_unit: u8,
	_pad:             [5]u8,
	allocated_size:   u64, // clusters reserved, in bytes; for compressed/sparse this is logical, see compressed_size
	data_size:        u64, // logical length
	initialized_size: u64,
	// compressed_size: u64 follows only when flags contain Compressed or Sparse
}
#assert(size_of(Nonresident_Header) == 64)

// Decoded view of one attribute record. Slices point into the record buffer.
Attribute :: struct {
	type:             Attr_Type,
	flags:            Attr_Flags,
	id:               u16,
	name:             []u16, // empty for the unnamed attribute
	non_resident:     bool,
	value:            []byte, // resident only
	lowest_vcn:       u64, // non-resident only from here on
	highest_vcn:      u64,
	allocated_size:   u64,
	data_size:        u64,
	initialized_size: u64,
	compressed_size:  u64, // equals allocated_size when the attribute is neither compressed nor sparse
	runlist:          []byte, // raw mapping pairs; decode with decode_runlist
}

// Bytes this attribute extent actually occupies on disk. Resident values live inside
// the record and cost nothing extra. Compressed and sparse attributes report their
// logical allocation in allocated_size, so the real figure is compressed_size.
attr_disk_size :: proc "contextless" (a: Attribute) -> u64 {
	if !a.non_resident {
		return 0
	}
	if .Compressed in a.flags || .Sparse in a.flags {
		return a.compressed_size
	}
	return a.allocated_size
}

record_header :: proc "contextless" (rec: []byte) -> ^Record_Header {
	return (^Record_Header)(raw_data(rec))
}

/*
Undo the update sequence protection in place.

NTFS writes a record in 512-byte blocks and cannot guarantee all blocks land together
after a power loss. So it stamps the last two bytes of every block with the same
sequence number and stores the displaced bytes in the update sequence array. Reading
a record means checking every stamp matches, then restoring the original bytes. A
mismatch means a torn write; the record is unreliable.
*/
apply_fixups :: proc(rec: []byte) -> Error {
	if len(rec) < size_of(Record_Header) {
		return .Bad_Record
	}
	h := record_header(rec)
	if h.magic != RECORD_MAGIC {
		return .Bad_Record
	}
	usa_ofs := int(h.usa_offset)
	count := int(h.usa_count)
	if count < 2 || usa_ofs + 2 * count > len(rec) || (count - 1) * FIXUP_BLOCK > len(rec) {
		return .Bad_Record
	}
	usn := rd16(rec, usa_ofs)
	for i in 1 ..< count {
		end := i * FIXUP_BLOCK
		if rd16(rec, end - 2) != usn {
			return .Bad_Record
		}
		wr16(rec, end - 2, rd16(rec, usa_ofs + 2 * i))
	}
	return .None
}

Attr_Iterator :: struct {
	rec:    []byte,
	offset: int,
}

// Iterate a fixed-up record's attributes. Stops at the end marker or the first
// malformed header, so a corrupt record yields a prefix rather than garbage.
attributes :: proc "contextless" (rec: []byte) -> Attr_Iterator {
	return Attr_Iterator{rec = rec, offset = int(record_header(rec).attrs_offset)}
}

next_attribute :: proc(it: ^Attr_Iterator) -> (a: Attribute, ok: bool) {
	rec := it.rec
	if it.offset < 0 || it.offset + 4 > len(rec) {
		return
	}
	if Attr_Type(rd32(rec, it.offset)) == .End {
		return
	}
	if it.offset + size_of(Attr_Header) > len(rec) {
		return
	}
	hdr := (^Attr_Header)(raw_data(rec[it.offset:]))^
	length := int(hdr.length)
	if length < size_of(Attr_Header) || length % 8 != 0 || it.offset + length > len(rec) {
		return
	}
	raw := rec[it.offset:it.offset + length]

	a.type = hdr.type
	a.flags = hdr.flags
	a.id = hdr.id
	if hdr.name_length > 0 {
		no := int(hdr.name_offset)
		nl := int(hdr.name_length) * 2
		if no + nl > length {
			return
		}
		a.name = mem.slice_data_cast([]u16, raw[no:no + nl])
	}

	if hdr.non_resident == 0 {
		if length < size_of(Resident_Header) {
			return
		}
		r := (^Resident_Header)(raw_data(raw))^
		vo := int(r.value_offset)
		vl := int(r.value_length)
		if vo + vl > length {
			return
		}
		a.value = raw[vo:vo + vl]
	} else {
		if length < size_of(Nonresident_Header) {
			return
		}
		n := (^Nonresident_Header)(raw_data(raw))^
		a.non_resident = true
		a.lowest_vcn = n.lowest_vcn
		a.highest_vcn = n.highest_vcn
		a.allocated_size = n.allocated_size
		a.data_size = n.data_size
		a.initialized_size = n.initialized_size
		a.compressed_size = n.allocated_size
		if (.Compressed in hdr.flags || .Sparse in hdr.flags) && length >= size_of(Nonresident_Header) + 8 {
			a.compressed_size = rd64(raw, size_of(Nonresident_Header))
		}
		ro := int(n.runlist_offset)
		if ro >= size_of(Nonresident_Header) && ro <= length {
			a.runlist = raw[ro:]
		}
	}

	it.offset += length
	ok = true
	return
}

// Windows FILE_ATTRIBUTE_* bits as stored in $STANDARD_INFORMATION and $FILE_NAME.
File_Attribute :: enum u32 {
	Read_Only             = 0,
	Hidden                = 1,
	System                = 2,
	Directory             = 4,
	Archive               = 5,
	Device                = 6,
	Normal                = 7,
	Temporary             = 8,
	Sparse                = 9,
	Reparse_Point         = 10,
	Compressed            = 11,
	Offline               = 12,
	Not_Content_Indexed   = 13,
	Encrypted             = 14,
	Integrity_Stream      = 15,
	Virtual               = 16,
	No_Scrub              = 17,
	Recall_On_Open        = 18,
	Pinned                = 19,
	Unpinned              = 20,
	Recall_On_Data_Access = 22,
	Directory_Index       = 28, // NTFS-internal: record has an $I30 index
	View_Index            = 29,
}
File_Attributes :: bit_set[File_Attribute; u32]

Standard_Information :: struct #packed {
	created:         u64, // FILETIME
	modified:        u64,
	mft_modified:    u64,
	accessed:        u64,
	file_attributes: File_Attributes,
	max_versions:    u32,
	version:         u32,
	class_id:        u32,
	// NTFS 3.x adds owner id, security id, quota, and USN; not needed here
}
#assert(size_of(Standard_Information) == 48)

standard_information :: proc(a: Attribute) -> (si: Standard_Information, ok: bool) {
	if a.type != .Standard_Information || a.non_resident || len(a.value) < size_of(Standard_Information) {
		return
	}
	return (^Standard_Information)(raw_data(a.value))^, true
}

Name_Space :: enum u8 {
	Posix         = 0, // case-sensitive, any Unicode except NUL and '/'
	Win32         = 1,
	Dos           = 2, // 8.3 alias generated alongside a Win32 name
	Win32_And_Dos = 3, // the Win32 name already fits 8.3, so one entry serves both
}

File_Name_Header :: struct #packed {
	parent:          File_Ref,
	created:         u64,
	modified:        u64,
	mft_modified:    u64,
	accessed:        u64,
	allocated_size:  u64, // only updated when the directory entry is; do not trust for sizing
	data_size:       u64,
	file_attributes: File_Attributes,
	reparse_or_ea:   u32,
	name_length:     u8, // UTF-16 code units
	namespace:       Name_Space,
}
#assert(size_of(File_Name_Header) == 66)

File_Name :: struct {
	parent:          File_Ref,
	file_attributes: File_Attributes,
	namespace:       Name_Space,
	name:            []u16,
}

file_name :: proc(a: Attribute) -> (fn: File_Name, ok: bool) {
	if a.type != .File_Name || a.non_resident || len(a.value) < size_of(File_Name_Header) {
		return
	}
	h := (^File_Name_Header)(raw_data(a.value))^
	n := int(h.name_length) * 2
	if size_of(File_Name_Header) + n > len(a.value) {
		return
	}
	fn.parent = h.parent
	fn.file_attributes = h.file_attributes
	fn.namespace = h.namespace
	fn.name = mem.slice_data_cast([]u16, a.value[size_of(File_Name_Header):size_of(File_Name_Header) + n])
	return fn, true
}
