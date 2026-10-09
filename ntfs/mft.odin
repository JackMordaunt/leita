package ntfs

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:unicode/utf16"
import "core:unicode/utf8"

import "../scan"

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
	records:            u64, // record slots in $MFT
	records_read:       u64, // slots that held a FILE record
	records_bad:        u64, // FILE records whose fixups failed
	in_use:             u64,
	directories:        u64,
	// Files whose unnamed $DATA fits inside their MFT record. They occupy no clusters
	// of their own, so their bytes are charged to $MFT rather than to their directory.
	resident_files:     u64,
	resident_bytes:     u64,
	// Clusters $Bitmap reports as allocated; 0 when it could not be read. This is the
	// file system's own total, independent of the per-file sums.
	allocated_clusters: u64,
	// What the read plan decided, from $MFT's own $BITMAP of live record slots.
	planned_bytes:      u64,
	skipped_bytes:      u64,
	extents:            u64,
	workers:            u64, // threads the scan actually ran on
	// Phase timings, nanoseconds.
	io_ns:              i64,
	parse_ns:           i64,
	bitmap_ns:          i64,
}

/*
A record that belongs to a base record elsewhere in the table.

Its attributes are credited to the base entry, which another worker may own, so it
cannot be folded in during a parallel pass. The bytes are copied because the read
buffer is reused for the next chunk.
*/
Deferred :: struct {
	record: u32,
	bytes:  []byte,
}

/*
Where one worker puts what it produces.

Entries are written straight into the table at their own record numbers, which no
two workers share, so only these need merging afterwards. The arena outlives the run
because every `Entry.name` points into it.
*/
Sink :: struct {
	names:    virtual.Arena,
	links:    [dynamic]Hard_Link,
	deferred: [dynamic]Deferred,
	stats:    Mft_Stats,
}

Mft :: struct {
	entries:           []Entry,
	links:             [dynamic]Hard_Link,
	sinks:             []Sink, // one per worker; kept alive for the names they hold
	boot:              Boot_Sector,
	bytes_per_cluster: u64,
	stats:             Mft_Stats,
	allocator:         mem.Allocator,
	ready:             b32, // the table exists and may be read while it fills
	complete:          b32, // nothing further will be added to it
}

mft_init :: proc(
	m: ^Mft,
	record_count: int,
	bytes_per_cluster: u64,
	sinks := 1,
	allocator := context.allocator,
) -> Error {
	m.allocator = allocator
	m.bytes_per_cluster = bytes_per_cluster
	entries, err := make([]Entry, record_count, allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	m.entries = entries
	m.links = make([dynamic]Hard_Link, allocator)
	m.sinks = make([]Sink, max(sinks, 1), allocator)
	for &s in m.sinks {
		// Static, so the tree can borrow names by offset; see `to_tree`.
		if virtual.arena_init_static(&s.names, scan.POOL_RESERVE) != nil {
			mft_destroy(m)
			return .Out_Of_Memory
		}
		s.links.allocator = allocator
		s.deferred.allocator = allocator
	}
	m.stats.records = u64(record_count)
	return .None
}

mft_destroy :: proc(m: ^Mft) {
	delete(m.entries, m.allocator)
	delete(m.links)
	for &s in m.sinks {
		delete(s.links)
		delete(s.deferred)
		if s.names.curr_block != nil {
			virtual.arena_destroy(&s.names)
		}
	}
	delete(m.sinks, m.allocator)
	m^ = {}
}

// Say the table is sized and safe to watch. Until then there is nothing to read.
mft_set_ready :: proc(m: ^Mft) {
	sync.atomic_store(&m.ready, true)
}

mft_ready :: proc(m: ^Mft) -> bool {
	return bool(sync.atomic_load(&m.ready))
}

// Say the table is finished. Hard links are merged in at the very end, so anything
// reading them concurrently has to wait for this.
mft_set_complete :: proc(m: ^Mft) {
	sync.atomic_store(&m.complete, true)
}

mft_complete :: proc(m: ^Mft) -> bool {
	return bool(sync.atomic_load(&m.complete))
}

/*
Whether an entry is finished and safe for another thread to read.

Folding writes an entry's flags last, so a reader that sees them set is looking at a
record whose name and sizes are already in place. Without that order a watcher could
catch a half-written name, which is a pointer and a length written separately.
*/
entry_published :: proc(e: ^Entry) -> bool {
	return .In_Use in transmute(Record_Flags)sync.atomic_load((^u16)(&e.flags))
}

/*
An entry's parent, and whether that answer can still change.

A parent record that has not been published yet may turn out to hold this name, so
the link is not final until it appears. One that has been published and does not
match never will be, which is just as final as a valid answer and lets the node be
charged instead of waiting forever.

The returned index is the entry's own when it has no usable parent.
*/
entry_parent_settled :: proc(m: ^Mft, i: u32) -> (parent: u32, settled: bool) {
	e := &m.entries[i]
	if int(e.parent) >= len(m.entries) || e.parent == i {
		return i, true
	}
	p := &m.entries[e.parent]
	if !entry_published(p) {
		return i, false
	}
	if .Directory in p.flags && p.sequence == e.parent_sequence {
		return e.parent, true
	}
	return i, true
}

// Fold each worker's private results into the table. Only these needed merging;
// entries were written into slots no other worker could reach.
mft_merge_sinks :: proc(m: ^Mft) {
	for &s in m.sinks {
		m.stats.records_read += s.stats.records_read
		m.stats.records_bad += s.stats.records_bad
		m.stats.in_use += s.stats.in_use
		m.stats.directories += s.stats.directories
		m.stats.resident_files += s.stats.resident_files
		m.stats.resident_bytes += s.stats.resident_bytes
		m.stats.io_ns += s.stats.io_ns
		m.stats.parse_ns += s.stats.parse_ns
		for l in s.links {
			append(&m.links, l)
		}
		clear(&s.links)
	}
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
mft_add_record :: proc(m: ^Mft, record_number: u32, rec: []byte, sink: ^Sink) -> Error {
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
	publish := owner == record_number
	if publish {
		e.sequence = h.sequence
		e.link_count = h.link_count
		sink.stats.in_use += 1
		if .Directory in h.flags {
			sink.stats.directories += 1
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
				add_name(m, owner, fn, sink)
			}
		case .Data:
			if a.non_resident {
				// Every extent contributes its own clusters.
				e.allocated += attr_disk_size(a, m.bytes_per_cluster)
			} else if len(a.name) == 0 {
				sink.stats.resident_files += 1
				sink.stats.resident_bytes += u64(len(a.value))
			}
		case:
			// Directory indexes, bitmaps, reparse data, and EFS streams occupy clusters too.
			e.allocated += attr_disk_size(a, m.bytes_per_cluster)
		}
	}
	// Last, and atomically: this is what tells a watching thread the entry is whole.
	if publish {
		sync.atomic_store((^u16)(&e.flags), transmute(u16)h.flags)
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
add_name :: proc(m: ^Mft, owner: u32, fn: File_Name, sink: ^Sink) {
	e := &m.entries[owner]
	parent := u32(ref_record(fn.parent))
	parent_seq := ref_sequence(fn.parent)

	if e.name == "" {
		e.name = intern_utf16(sink, fn.name)
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
		e.name = intern_utf16(sink, fn.name)
		e.parent = parent
		e.parent_sequence = parent_seq
		e.namespace = fn.namespace
		return
	}
	name := intern_utf16(sink, fn.name)
	if name == e.name && parent == e.parent {
		return
	}
	append(&sink.links, Hard_Link{record = owner, parent = parent, name = name})
}

// Copy a UTF-16LE name into the arena as UTF-8. Names are at most 255 code units.
@(private)
intern_utf16 :: proc(sink: ^Sink, name: []u16) -> string {
	runes: [256]rune
	n := utf16.decode(runes[:], name)
	total := 0
	for r in runes[:n] {
		total += utf8.rune_size(r)
	}
	buf, err := make([]byte, total, virtual.arena_allocator(&sink.names))
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
