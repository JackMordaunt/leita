package btrfs

import "core:mem"
import "core:sync"

/*
Extents is what a walk's workers, together, have charged on one pool: every extent
some file has paid for, by its first byte on disk, so each is charged once however
many files, reflinks or snapshots refer to it. It is Usage.seen made safe to share.

The set is split into shards by a hash of the extent's address, each behind its own
mutex, so workers charging different extents seldom wait on one another, and a
shard that grows rehashes only its own part. A pool of a few million extents takes
some thousands per shard. Each entry also keeps a token for the file that paid, so a
file meeting an extent it paid for itself, through another of its ranges, is not
called shared.

Which file pays for an extent two files share depends on which worker reaches it
first, so it can differ from one walk to the next. The total cannot: every extent is
paid for exactly once, as Usage.seen pays for it in measure's single pass, whose
totals matched compsize -b on a test volume (2026-10-15).
*/
Extents :: struct {
	shards:    [EXTENT_SHARDS]Extent_Shard,
	allocator: mem.Allocator,
}

@(private)
EXTENT_SHARDS :: 256
// What a shard makes room for when first used: 256 shards of 1,024 hold a quarter of
// a million extents before any grows.
@(private)
SHARD_START :: 1024

// On a cache line of its own, as the tree's arenas are, so neighbouring shards'
// mutexes do not contend for one line.
@(private)
Extent_Shard :: struct #align (64) {
	mutex:  sync.Mutex,
	owners: map[u64]u64,
}

extents_init :: proc(e: ^Extents, allocator := context.allocator) {
	e.allocator = allocator
}

extents_destroy :: proc(e: ^Extents) {
	for &s in e.shards {
		delete(s.owners)
	}
}

/*
owner_of names a file for Extents: its inode and the device its subvolume shows,
since a snapshot's copy of a file can keep its inode number: a snapshot starts as a
copy of its subvolume's tree, inode items included (on a test volume a file and its
copy in a snapshot were both inode 260, on devices 75 and 88; 2026-10-15). Mixed into one number, so
two files could share a token, which at worst leaves one of them unmarked as shared:
the charge never depends on it.
*/
owner_of :: proc(device, inode: u64) -> u64 {
	return inode ~ (device * 0x9e3779b97f4a7c15)
}

/*
Claim the extent at `at` for `owner`: first is set when no file had paid for it, so
this one does now. other is set when another file had.
*/
claim :: proc(e: ^Extents, at, owner: u64) -> (first, other: bool, err: mem.Allocator_Error) {
	// An extent starts on a sector boundary (sectorsize in btrfs_ioctl_fs_info_args, 4 KiB
	// on most pools), so the low bits say little; the product folds them into the high ones.
	h := at * 0x9e3779b97f4a7c15
	s := &e.shards[h >> (64 - 8)]
	#assert(EXTENT_SHARDS == 1 << 8)
	sync.mutex_guard(&s.mutex)
	if s.owners == nil {
		s.owners = make(map[u64]u64, SHARD_START, e.allocator) or_return
	}
	paid, found := s.owners[at]
	if found {
		return false, paid != owner, nil
	}
	_, value, _, entry_err := map_entry(&s.owners, at)
	if entry_err != nil {
		return false, false, entry_err
	}
	value^ = owner
	return true, false, nil
}

/*
Charge is one file's share of a pool shared by a walk's workers: the disk no other
file had paid for, and whether some of what it refers to another file had.
*/
Charge :: struct {
	disk:   u64,
	shared: bool,
}

/*
Charge one file extent item to `owner`'s file. An inline extent belongs to its file
alone and a hole is charged nothing. Of the rest, only the first file to claim an
extent pays for it.
*/
charge_shared :: proc(item: []u8, e: ^Extents, owner: u64, c: ^Charge) -> Item_Error {
	it, err := parse(item)
	if err != .None {
		return err
	}
	if it.inline {
		if !u64_fits(c.disk, it.disk) {
			return .Overflow
		}
		c.disk += it.disk
		return .None
	}
	if it.at == 0 {
		return .None
	}
	// Refuse before claim. A wrapped add would record the extent as paid
	// and then store a small total.
	if !u64_fits(c.disk, it.disk) {
		return .Overflow
	}
	first, other, claim_err := claim(e, it.at, owner)
	if claim_err != nil {
		return .Out_Of_Memory
	}
	if first {
		c.disk += it.disk
	}
	if other {
		c.shared = true
	}
	return .None
}
