/*
Package walk enumerates directories through core:os.

It is the reader that works anywhere: any filesystem, any platform, no privilege. It
is also much slower than reading a filesystem's own metadata, because it pays a
syscall per directory and learns nothing the OS does not hand it. That makes it the
fallback rather than the default, and the yardstick a specialised reader is measured
against.

A directory listing is already the shape of the tree, so it writes straight into it.
*/
package walk

import "core:mem"
import "core:os"
import "core:strings"

import "../flow"
import "../scan"

Config :: struct {
	workers:   int, // 0 selects DEFAULT_WORKERS
	follow:    bool, // descend through symlinks and junctions; loops are not detected
	allocator: mem.Allocator,
}

// Directory reads are latency bound and hold no core while they wait, so more
// workers than cores is right here in a way it was not for the MFT reader.
DEFAULT_WORKERS :: 8

Error :: enum {
	None,
	Open_Failed,
	Out_Of_Memory,
	Cancelled,
}

/*
Walk `root` into the tree.

Directories are the unit of work: each yields its entries and queues the directories
among them. Work is found as it goes rather than known up front, so a batch of
discovered directories is walked, and what that batch discovers becomes the next one.
Every worker writes only into slots it claimed, so nothing here is synchronised.
*/
scan :: proc(root: string, t: ^scan.Tree, cfg := Config{}) -> Error {
	allocator := context.allocator

	w := scan.writer(t, 0)
	first, claim_err := scan.claim(&w, 1)
	if claim_err != nil {
		return .Out_Of_Memory
	}
	n := scan.node(t, first)
	n.parent = first // a root holds itself
	n.name = scan.intern(&w, root)
	n.flags = {.Used, .Directory}
	t.root = first

	workers := cfg.workers
	if workers <= 0 {
		workers = DEFAULT_WORKERS
	}

	// Directories discovered but not yet walked. One generation is handed to the
	// workers while the next accumulates in their own lists.
	pending := make([dynamic]Dir, allocator)
	defer delete(pending)
	append(&pending, Dir{index = first, path = strings.clone(root, allocator)})

	// One writer per worker, and a writer needs an arena of its own, so the tree
	// caps how wide this can run.
	workers = min(workers, len(t.arenas))
	states := make([]Worker, workers, allocator)
	defer delete(states, allocator)

	next := make([dynamic]Dir, allocator)
	defer delete(next)

	for len(pending) > 0 {
		if scan.cancelled(t) {
			return .Cancelled
		}
		// Size the pool to the generation: a directory with two children should not
		// pay to start eight threads.
		n_workers := scan.width_for(len(pending), workers)
		for i in 0 ..< n_workers {
			states[i] = Worker {
				writer    = scan.writer(t, i),
				found     = make([dynamic]Dir, allocator),
				follow    = cfg.follow,
				allocator = allocator,
			}
		}

		flow.each(pending[:], states[:n_workers], walk_dir, .Io)

		clear(&next)
		for &s in states[:n_workers] {
			for d in s.found {
				append(&next, d)
			}
			delete(s.found)
		}
		for d in pending {
			delete(d.path, allocator)
		}
		clear(&pending)
		for d in next {
			append(&pending, d)
		}
	}
	return .None
}

// A directory waiting to be read, and the node already standing for it.
@(private)
Dir :: struct {
	index: u32,
	path:  string, // owned; freed once walked
}

@(private)
Worker :: struct {
	writer:    scan.Writer,
	found:     [dynamic]Dir,
	follow:    bool,
	allocator: mem.Allocator,
}

@(private)
walk_dir :: proc(d: Dir, w: ^Worker) -> bool {
	if scan.cancelled(w.writer.tree) {
		return false
	}
	f, open_err := os.open(d.path)
	if open_err != nil {
		// A directory we may not read is not a reason to abandon the scan; it is
		// simply worth nothing. Permission denied is normal on a live system.
		return true
	}
	defer os.close(f)

	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)

	nodes: u64
	bytes: u64
	for info in os.read_directory_iterator(&it) {
		if _, err := os.read_directory_iterator_error(&it); err != nil {
			continue
		}
		index, claim_err := scan.claim(&w.writer, 1)
		if claim_err != nil {
			return false
		}
		n := scan.node(w.writer.tree, index)
		n.parent = d.index
		n.name = scan.intern(&w.writer, info.name)
		n.size = u64(max(info.size, 0))
		n.flags = {.Used}

		switch info.type {
		case .Directory:
			n.flags |= {.Directory}
			append(&w.found, Dir{index = index, path = strings.clone(info.fullpath, w.allocator)})
		case .Symlink:
			n.flags |= {.Reparse}
			if w.follow {
				append(&w.found, Dir{index = index, path = strings.clone(info.fullpath, w.allocator)})
			}
		case .Undetermined, .Regular, .Named_Pipe, .Socket, .Character_Device, .Block_Device:
			// core:os reports the logical length and nothing about allocation, so
			// the on-disk figure is the best estimate available here: the size
			// rounded up to a block. A reader that talks to the filesystem directly
			// knows the real answer; this one cannot.
			n.disk = round_up(n.size, BLOCK_ESTIMATE)
		}
		nodes += 1
		bytes += n.disk
	}
	scan.progress(w.writer.tree, nodes, bytes)
	return true
}

// Without filesystem-specific knowledge the allocation unit is a guess, and four
// kilobytes is the common one. It makes small files cost something rather than
// nothing, which matters more than being exactly right.
@(private)
BLOCK_ESTIMATE :: 4096

@(private)
round_up :: proc(v, unit: u64) -> u64 {
	if v == 0 {
		return 0
	}
	return (v + unit - 1) / unit * unit
}
