package btrfs

import "core:encoding/endian"
import "core:math/bits"

/*
What btrfs charges a file for, read from its extent items rather than from
st_blocks, which on btrfs counts the bytes a file refers to: a compressed file is
charged its uncompressed size, and a reflinked copy or a snapshot is charged again
for extents it shares. This is compsize's accounting
(https://github.com/kilobyte/compsize), the file extent items of an inode taken
one at a time, each distinct extent charged once, where it is first met.

Three sizes, as compsize names them. Disk is what the extents occupy on disk,
compressed. Uncompressed is the same extents' size before compression.
Referenced is what the file's ranges point at, an extent counted once for every
range that points into it, holes left out.
*/
Sizes :: struct {
	disk:         u64,
	uncompressed: u64,
	referenced:   u64,
}

// How an extent is stored: btrfs_compression_type, with preallocated extents kept
// apart as compsize keeps them.
Compression :: enum u8 {
	None,
	Zlib,
	Lzo,
	Zstd,
	Prealloc,
}

/*
Usage is what a run over many files has charged so far: the sizes by how each
extent is stored, and the counts compsize prints. Seen holds every extent already
charged, by its first byte on disk, so a second reference to it, from a reflink, a
snapshot or another range of the same file, adds only to referenced.
*/
Usage :: struct {
	by:      [Compression]Sizes,
	files:   u64,
	extents: u64,
	refs:    u64,
	inline:  u64,
	// What st_blocks claims for the same files, in bytes: the naive sum a walk takes.
	blocks:  u64,
	seen:    map[u64]struct{},
}

/*
File is one file's share. Its own sizes count each distinct extent it refers to
once, what compsize reports for that file alone. Charged is the part of its disk
no file before it in the run had already been charged for; shared is set when
some of its extents had been.
*/
File :: struct {
	using sizes: Sizes,
	charged:     u64,
	shared:      bool,
	own:         map[u64]struct{},
}

usage_destroy :: proc(u: ^Usage) {
	delete(u.seen)
}

file_destroy :: proc(f: ^File) {
	delete(f.own)
}

total :: proc(u: Usage) -> (s: Sizes) {
	for c in u.by {
		s.disk += c.disk
		s.uncompressed += c.uncompressed
		s.referenced += c.referenced
	}
	return
}

// struct btrfs_file_extent_item in linux/btrfs_tree.h, packed: a 21 byte header
// (generation, ram_bytes, compression, encryption, other_encoding, type), then, unless
// the extent is inline, where it lies on disk.
@(private)
ITEM_INLINE_HEADER :: 21
@(private)
ITEM_SIZE :: 53
@(private)
EXTENT_INLINE :: 0
@(private)
EXTENT_PREALLOC :: 2

Item_Error :: enum {
	None,
	Short,
	Compression,
	Out_Of_Memory,
	// A size that does not fit in u64. The totals are left as they were.
	Overflow,
}

// One file extent item, read: its header and, unless it is inline, where it lies.
@(private)
Item :: struct {
	compression: Compression,
	inline:      bool,
	ram:         u64,
	// Inline: the bytes the item holds after its header. Otherwise the extent's.
	disk:        u64,
	at:          u64, // first byte on disk; 0 for a hole or an inline extent
	refers:      u64,
}

@(private)
parse :: proc(item: []u8) -> (it: Item, err: Item_Error) {
	if len(item) < ITEM_INLINE_HEADER {
		return {}, .Short
	}
	it.ram, _ = endian.get_u64(item[8:16], .Little)
	kind := item[20]
	stored := item[16]
	if stored > u8(Compression.Zstd) {
		return {}, .Compression
	}
	it.compression = Compression(stored)
	if kind == EXTENT_INLINE {
		// The data lies in the item itself, after the header.
		it.inline = true
		it.disk = u64(len(item) - ITEM_INLINE_HEADER)
		return it, .None
	}
	if len(item) < ITEM_SIZE {
		return {}, .Short
	}
	if kind == EXTENT_PREALLOC {
		it.compression = .Prealloc
	}
	it.at, _ = endian.get_u64(item[21:29], .Little)
	it.disk, _ = endian.get_u64(item[29:37], .Little)
	it.refers, _ = endian.get_u64(item[45:53], .Little)
	return it, .None
}

/*
Charge one file extent item, as the tree search hands it back, to the file and to
the run. A hole, an extent whose disk_bytenr is 0, is charged nothing.
*/
charge :: proc(item: []u8, u: ^Usage, f: ^File) -> Item_Error {
	it, err := parse(item)
	if err != .None {
		return err
	}
	c := it.compression
	if it.inline {
		// Checked before any write: a wrapped total would be a small number
		// for a huge extent.
		if !u64_fits(u.by[c].disk, it.disk) ||
		   !u64_fits(u.by[c].uncompressed, it.ram) ||
		   !u64_fits(u.by[c].referenced, it.ram) ||
		   !u64_fits(u.inline, 1) ||
		   !u64_fits(f.disk, it.disk) ||
		   !u64_fits(f.uncompressed, it.ram) ||
		   !u64_fits(f.referenced, it.ram) ||
		   !u64_fits(f.charged, it.disk) {
			return .Overflow
		}
		u.by[c].disk += it.disk
		u.by[c].uncompressed += it.ram
		u.by[c].referenced += it.ram
		u.inline += 1
		f.disk += it.disk
		f.uncompressed += it.ram
		f.referenced += it.ram
		f.charged += it.disk
		return .None
	}
	if it.at == 0 {
		return .None
	}
	new_here := it.at not_in f.own
	fresh := it.at not_in u.seen
	if !u64_fits(u.refs, 1) ||
	   !u64_fits(u.by[c].referenced, it.refers) ||
	   !u64_fits(f.referenced, it.refers) {
		return .Overflow
	}
	if new_here && (!u64_fits(f.disk, it.disk) || !u64_fits(f.uncompressed, it.ram)) {
		return .Overflow
	}
	if fresh &&
	   (!u64_fits(u.by[c].disk, it.disk) ||
		   !u64_fits(u.by[c].uncompressed, it.ram) ||
		   !u64_fits(u.extents, 1) ||
		   !u64_fits(f.charged, it.disk)) {
		return .Overflow
	}
	u.refs += 1
	u.by[c].referenced += it.refers
	f.referenced += it.refers
	if new_here {
		if _, _, _, map_err := map_entry(&f.own, it.at); map_err != nil {
			return .Out_Of_Memory
		}
		f.disk += it.disk
		f.uncompressed += it.ram
	}
	if !fresh {
		// Charged already: to an earlier file, which is sharing, or to this one
		// through an earlier range, which is not.
		if new_here {
			f.shared = true
		}
		return .None
	}
	if _, _, _, map_err := map_entry(&u.seen, it.at); map_err != nil {
		return .Out_Of_Memory
	}
	u.by[c].disk += it.disk
	u.by[c].uncompressed += it.ram
	u.extents += 1
	f.charged += it.disk
	return .None
}

// u64_fits reports whether dst+add stays in u64.
@(private)
u64_fits :: proc(dst, add: u64) -> bool {
	_, wrapped := bits.overflowing_add(dst, add)
	return !wrapped
}

// SEARCH_HEADER is how many bytes come off the front of one record before its body.
SEARCH_HEADER :: 32

// read_search_item splits one TREE_SEARCH_V2 record from the front of buf.
// The length is checked by what remains after the header, not by adding it on.
read_search_item :: proc(
	buf: []u8,
) -> (
	rest: []u8,
	offset: u64,
	item_type: u32,
	body: []u8,
	ok: bool,
) {
	if len(buf) < SEARCH_HEADER {
		return
	}
	offset, _ = endian.get_u64(buf[16:24], .Little)
	item_type, _ = endian.get_u32(buf[24:28], .Little)
	length, _ := endian.get_u32(buf[28:32], .Little)
	remain := len(buf) - SEARCH_HEADER
	if uint(length) > uint(remain) {
		return
	}
	n := int(length)
	body = buf[SEARCH_HEADER:][:n]
	rest = buf[SEARCH_HEADER + n:]
	ok = true
	return
}
