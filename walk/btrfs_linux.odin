#+build linux
package walk

import "core:mem"
import "core:os"
import "core:sync"
import "core:sys/linux"

import "../btrfs"
import "../scan"

/*
What a walk knows about btrfs: one Btrfs_Pool for each pool it has listed a
directory of, shared by every worker.

st_blocks on btrfs is what a file refers to, not what it occupies: a compressed file
counts its uncompressed size, and a reflinked copy or a snapshot's file counts again
the extents it shares. So on btrfs each regular file is asked for its extents
(btrfs.charge_file), and charged only the extents no file before it paid for. That
search needs CAP_SYS_ADMIN. Without it the first file of a pool is refused, the
search is off for that pool from then on, and its files keep st_blocks, which the
tree records as logical (scan.mark_logical).

NO_BTRFS_SEARCH_ENV set to anything turns the search off for the whole walk, so the
cost of searching can be measured against the same walk without it.

An update on btrfs reads the whole tree again. The baseline stores each file's
once-only charge, not the extents that produced it or the capability under which
it was read. Mixing a copied charge with a restat or a new extent search can
therefore charge a shared extent twice, or mix charged and st_blocks sizes after
a privilege change. A fresh walk builds one extent set and chooses its basis
from current capabilities, at the cost of incremental scan speed on btrfs.
Other filesystems retain incremental updates. Following links also reads afresh,
since those links can enter btrfs even when the root is on another filesystem.
*/
@(private)
Btrfs_Search :: struct {
	mutex:     sync.Mutex, // guards pools
	pools:     [dynamic]^Btrfs_Pool,
	off:       bool, // NO_BTRFS_SEARCH_ENV is set
	search:    Search_File,
	stand_in:  bool, // search is a test's: every directory is on btrfs
	tree:      ^scan.Tree, // borrowed from the walk, to mark logical
	allocator: mem.Allocator,
}

// How a walk asks for one file's extents: btrfs.charge_file.
@(private)
Search_File :: #type proc(
	dir: linux.Fd,
	ino: u64,
	args: ^btrfs.Search_Args,
	e: ^btrfs.Extents,
	owner: u64,
) -> (
	btrfs.Charge,
	btrfs.Error,
)

/*
What a walk started on this thread searches with in place of btrfs.charge_file, nil
for that. The search needs root and btrfs, so a test stands this in to check what
the walk does with the answers anywhere: a walk given a stand-in treats every
directory as lying on one btrfs pool. On this thread only, so the tests running
beside it walk as they would.
*/
@(private, thread_local)
search_stand_in: Search_File

NO_BTRFS_SEARCH_ENV :: "LEITA_NO_BTRFS_SEARCH"

@(private)
Btrfs_Pool :: struct {
	filesystem: u128,
	off:        b32, // refused, or turned off: its files keep st_blocks
	extents:    btrfs.Extents,
}

@(private)
btrfs_search_init :: proc(s: ^Btrfs_Search, t: ^scan.Tree, allocator: mem.Allocator) {
	s.tree = t
	s.allocator = allocator
	s.search = btrfs.charge_file
	if search_stand_in != nil {
		s.search, s.stand_in = search_stand_in, true
	}
	s.pools = make([dynamic]^Btrfs_Pool, allocator)
	off := os.get_env(NO_BTRFS_SEARCH_ENV, allocator)
	s.off = off != ""
	delete(off, allocator)
}

@(private)
btrfs_search_destroy :: proc(s: ^Btrfs_Search) {
	for p in s.pools {
		btrfs.extents_destroy(&p.extents)
		free(p, s.allocator)
	}
	delete(s.pools)
}

/*
The pool to charge a btrfs directory's files to, nil when its search is off. A
worker keeps the last pool it used, so the shared list is locked only when the
worker moves onto another pool than the one it last charged.
*/
@(private)
btrfs_pool_for :: proc(w: ^Worker, filesystem: u128) -> ^Btrfs_Pool {
	s := &w.scratch
	p := s.pool
	if p == nil || p.filesystem != filesystem {
		p = btrfs_pool_find(w.btrfs, filesystem)
		s.pool = p
	}
	if p == nil || sync.atomic_load(&p.off) {
		return nil
	}
	// The search buffer is 64 KiB, so a worker takes one only once it meets a pool
	// to search, and keeps it.
	if s.args == nil {
		args, err := new(btrfs.Search_Args, s.allocator)
		if err != nil {
			btrfs_search_stop(w, p)
			return nil
		}
		s.args = args
	}
	return p
}

@(private)
btrfs_pool_find :: proc(b: ^Btrfs_Search, filesystem: u128) -> ^Btrfs_Pool {
	sync.mutex_guard(&b.mutex)
	for p in b.pools {
		if p.filesystem == filesystem {
			return p
		}
	}
	p, err := new(Btrfs_Pool, b.allocator)
	if err != nil {
		scan.mark_logical(b.tree)
		return nil
	}
	p.filesystem = filesystem
	btrfs.extents_init(&p.extents, b.allocator)
	if _, append_err := append(&b.pools, p); append_err != nil {
		btrfs.extents_destroy(&p.extents)
		free(p, b.allocator)
		scan.mark_logical(b.tree)
		return nil
	}
	if b.off {
		p.off = true
		scan.mark_logical(b.tree)
	}
	return p
}

// Charge the rest of a pool's files their st_blocks.
@(private)
btrfs_search_stop :: proc(w: ^Worker, p: ^Btrfs_Pool) {
	sync.atomic_store(&p.off, true)
	scan.mark_logical(w.writer.tree)
}

// A normal walk stops at other filesystems, so root identifies its accounting
// domain. A failed query cannot establish that copying old charges is safe.
@(private)
btrfs_update_needs_read :: proc(root: string, follow: bool) -> bool {
	if follow || search_stand_in != nil {
		return true
	}
	buf: Path
	cpath, terminated := terminate(root, &buf)
	if !terminated {
		return true
	}
	fs: linux.Stat_FS
	return linux.statfs(cpath, &fs) != .NONE || fs.type == .BTRFS_SUPER_MAGIC
}
