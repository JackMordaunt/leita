package ntfs

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:unicode/utf16"
import "core:unicode/utf8"

// One row per MFT record. Indexed by record number in Mft.entries.
Entry :: struct {
	parent:          u32, // record number of the directory holding `name`
	parent_sequence: u16, // sequence the parent had when this name was written; mismatch means orphan
	sequence:        u16,
	link_count:      u16,
	namespace:       Name_Space, // of `name`
	flags:           Record_Flags, // .In_Use and .Directory are the ones that matter
	attributes:      File_Attributes, // from $STANDARD_INFORMATION; .Reparse_Point marks junctions and cloud placeholders
	name:            string, // UTF-8; empty when the record has no $FILE_NAME (free records, extension records)
	size:            u64, // logical length of the unnamed $DATA stream
	allocated:       u64, // bytes on disk across every non-resident attribute: data, alternate streams, indexes
}

// A file with several names. The first Win32 or POSIX name becomes Entry.name; the
// rest land here so they can be shown but never double-counted.
Hard_Link :: struct {
	record: u32,
	parent: u32,
	name:   string,
}

Mft_Stats :: struct {
	records:      u64, // record slots in $MFT
	records_read: u64, // slots that held a FILE record
	records_bad:  u64, // FILE records whose fixups failed
	in_use:       u64,
	directories:  u64,
}

Mft :: struct {
	entries:   []Entry,
	links:     [dynamic]Hard_Link,
	boot:      Boot_Sector,
	stats:     Mft_Stats,
	names:     virtual.Arena, // backing store for every name string; never moves
	allocator: mem.Allocator,
}

mft_init :: proc(m: ^Mft, record_count: int, allocator := context.allocator) -> Error {
	m.allocator = allocator
	entries, err := make([]Entry, record_count, allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	m.entries = entries
	m.links = make([dynamic]Hard_Link, allocator)
	if virtual.arena_init_growing(&m.names) != nil {
		delete(m.entries, allocator)
		delete(m.links)
		return .Out_Of_Memory
	}
	m.stats.records = u64(record_count)
	return .None
}

mft_destroy :: proc(m: ^Mft) {
	delete(m.entries, m.allocator)
	delete(m.links)
	virtual.arena_destroy(&m.names)
	m^ = {}
}

/*
Fold one fixed-up FILE record into the table. Records may arrive in any order.

An extension record carries attributes that did not fit in its base record (a heavily
fragmented file, or one with many hard links). Its header names the base record, so
its attributes are credited to the base entry. This makes the $ATTRIBUTE_LIST
attribute unnecessary for our purposes: by visiting every record we see every
attribute anyway.

Records not in use are skipped entirely. Their contents are stale and may point at
records that have since been reused.
*/
mft_add_record :: proc(m: ^Mft, record_number: u32, rec: []byte) -> Error {
	if len(rec) < size_of(Record_Header) {
		return .Bad_Record
	}
	h := record_header(rec)
	if h.magic != RECORD_MAGIC {
		return .Bad_Record
	}
	if .In_Use not_in h.flags {
		return .None
	}

	owner := record_number
	if h.base_record != 0 {
		owner = u32(ref_record(h.base_record))
		if int(owner) >= len(m.entries) {
			return .None
		}
	}
	if int(owner) >= len(m.entries) {
		return .Bad_Record
	}
	e := &m.entries[owner]
	if owner == record_number {
		e.sequence = h.sequence
		e.link_count = h.link_count
		e.flags = h.flags
		m.stats.in_use += 1
		if .Directory in h.flags {
			m.stats.directories += 1
		}
	}

	it := attributes(rec)
	for {
		a, ok := next_attribute(&it)
		if !ok {
			break
		}
		#partial switch a.type {
		case .Standard_Information:
			if si, si_ok := standard_information(a); si_ok {
				e.attributes = si.file_attributes
			}
		case .File_Name:
			if fn, fn_ok := file_name(a); fn_ok {
				add_name(m, owner, fn)
			}
		case .Data:
			if a.non_resident {
				// Only the first extent carries the sizes; later extents repeat them.
				if a.lowest_vcn == 0 {
					e.allocated += attr_disk_size(a)
					if len(a.name) == 0 {
						e.size = a.data_size
					}
				}
			} else if len(a.name) == 0 {
				e.size = u64(len(a.value))
			}
		case:
			// Directory indexes, bitmaps, reparse data, and EFS streams occupy clusters too.
			if a.non_resident && a.lowest_vcn == 0 {
				e.allocated += attr_disk_size(a)
			}
		}
	}
	return .None
}

/*
Choose which $FILE_NAME becomes the entry's name.

A file usually has one Win32 name and, when that name does not fit 8.3, a DOS alias
pointing at the same parent. The alias is not a separate link, so it is skipped
whenever a proper name exists. Any further Win32 or POSIX name is a real hard link.
*/
@(private)
add_name :: proc(m: ^Mft, owner: u32, fn: File_Name) {
	e := &m.entries[owner]
	parent := u32(ref_record(fn.parent))
	parent_seq := ref_sequence(fn.parent)

	if e.name == "" {
		e.name = intern_utf16(m, fn.name)
		e.parent = parent
		e.parent_sequence = parent_seq
		e.namespace = fn.namespace
		return
	}
	if fn.namespace == .Dos {
		return
	}
	if e.namespace == .Dos {
		// The alias arrived first; the real name replaces it.
		e.name = intern_utf16(m, fn.name)
		e.parent = parent
		e.parent_sequence = parent_seq
		e.namespace = fn.namespace
		return
	}
	name := intern_utf16(m, fn.name)
	if name == e.name && parent == e.parent {
		return
	}
	append(&m.links, Hard_Link{record = owner, parent = parent, name = name})
}

// Copy a UTF-16LE name into the arena as UTF-8. Names are at most 255 code units.
@(private)
intern_utf16 :: proc(m: ^Mft, name: []u16) -> string {
	runes: [256]rune
	n := utf16.decode(runes[:], name)
	total := 0
	for r in runes[:n] {
		total += utf8.rune_size(r)
	}
	buf, err := make([]byte, total, virtual.arena_allocator(&m.names))
	if err != nil {
		return ""
	}
	off := 0
	for r in runes[:n] {
		enc, size := utf8.encode_rune(r)
		copy(buf[off:], enc[:size])
		off += size
	}
	return string(buf)
}

// True when the entry's parent reference still points at the record it was written for.
entry_parent_valid :: proc(m: ^Mft, e: Entry) -> bool {
	if int(e.parent) >= len(m.entries) {
		return false
	}
	p := m.entries[e.parent]
	return .In_Use in p.flags && .Directory in p.flags && p.sequence == e.parent_sequence
}

/*
Reconstruct the path of a record by following parent references up to the root.
The result starts with a backslash and omits the drive letter, e.g.
`\Windows\explorer.exe`. Records whose chain does not reach the root (files inside a
deleted directory, or a stale parent reference) yield a path rooted at the highest
reachable ancestor, prefixed with `<orphan>`.
*/
mft_path :: proc(m: ^Mft, record: u32, allocator := context.allocator) -> string {
	chain: [64]u32
	depth := 0
	r := record
	orphan := false
	for depth < len(chain) {
		if int(r) >= len(m.entries) || r == RECORD_ROOT {
			break
		}
		e := m.entries[r]
		chain[depth] = r
		depth += 1
		if !entry_parent_valid(m, e) || e.parent == r {
			orphan = true
			break
		}
		r = e.parent
	}
	if depth == len(chain) {
		orphan = true
	}

	sb := strings.builder_make(allocator)
	if orphan {
		strings.write_string(&sb, "<orphan>")
	}
	if depth == 0 {
		strings.write_string(&sb, `\`)
	}
	for i := depth - 1; i >= 0; i -= 1 {
		strings.write_string(&sb, `\`)
		strings.write_string(&sb, m.entries[chain[i]].name)
	}
	return strings.to_string(sb)
}
