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

Directories are the unit of work and each yields more of them, which is the shape
`flow.manage` exists for: a worker takes the next directory the moment one is known
rather than waiting for a level to finish. Every worker writes only into slots it
claimed, so nothing here is synchronised except the queue itself.
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
	n.flags = {.Used, .Settled, .Directory}
	t.root = first

	workers := cfg.workers
	if workers <= 0 {
		workers = DEFAULT_WORKERS
	}
	// One writer per worker, and a writer needs an arena of its own, so the tree
	// caps how wide this can run.
	workers = min(workers, len(t.arenas))

	states := make([]Worker, workers, allocator)
	defer delete(states, allocator)
	for i in 0 ..< workers {
		states[i] = Worker {
			writer    = scan.writer(t, i),
			found     = make([dynamic]Dir, allocator),
			follow    = cfg.follow,
			allocator = allocator,
		}
	}
	defer for &s in states {
		delete(s.found)
	}

	seed := []Dir{{index = first, path = strings.clone(root, allocator)}}
	flow.manage(seed, states, walk_dir, hand_over)

	if scan.cancelled(t) {
		return .Cancelled
	}
	return .None
}

// Move what a worker found into the queue. Serialised by `manage`, so this is the
// one place the set of directories still to walk is touched.
@(private)
hand_over :: proc(w: ^Worker, queue: ^[dynamic]Dir) -> bool {
	for d in w.found {
		append(queue, d)
	}
	clear(&w.found)
	return !scan.cancelled(w.writer.tree)
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
	defer delete(d.path, w.allocator)
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
		// A walker reaches a child through its parent, so the link is never in doubt.
		n.flags = {.Used, .Settled}

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
