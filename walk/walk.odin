/*
Package walk enumerates directories through core:os.

It is the reader that works anywhere: any filesystem, any platform, no privilege. It
is also much slower than reading a filesystem's own metadata, because it pays a
syscall per directory and learns nothing the OS does not hand it. That makes it the
fallback rather than the default, and the yardstick a specialised reader is measured
against.

A directory listing is already the shape of the tree, so it writes straight into it.
Reading one directory is the only part that differs by platform, and it is the part
worth specialising: `read_dir` is portable through core:os everywhere but Linux and
macOS, which ask the kernel directly.
*/
package walk

import "core:mem"
import "core:strings"
import "core:sync"

import "../scan"
import "jm:flow"

Config :: struct {
	workers: int, // 0 lets `width` choose
	follow:  bool, // descend through symlinks and junctions; loops are not detected
	media:   scan.Media, // what holds the tree, which `width` fits the choice to
	pace:    Pace,
}

/*
How hard a walk leans on the machine it runs on.

Full takes what the volume and the cores can give. Gentle is for a machine with other
work to do, a server or a shared host, and gives up readers rather than priority.

Lowering the readers' priority made them worse neighbours on macOS. A cached `find`
over /System/Library/Frameworks and /Applications took 2.2 s alone and the same
beside a gentle walk at normal priority, but 5.1 to 6.0 s beside one in the Darwin
background band or with its I/O throttled, and the walk itself slowed from 22 s to
31 s and 37 s. The likely cause is a throttled reader sleeping while it holds the
directory it is reading, so whatever needs that directory waits behind it. Linux's
idle I/O class and Windows' background mode were not measured, and are not used
either.
*/
Pace :: enum {
	Full,
	Gentle,
}

/*
How many directories a walk with `cfg` reads at once: what was asked for, or else a
count fitted to the machine and to what stores the tree.

A directory read mostly waits on the volume and holds no core while it does, so on
flash twice as many workers as logical cores keep it busier than one per core would:
reading a 2.6 million entry home directory on an 8-core M-series Mac took 15.8 s with
8 workers, 12.5 s with 16 and 11.5 s with 32. The cap is the most that was measured,
not a limit anything was seen to hit. A spinning disk gets one, on the assumption,
not measured, that every read in flight beyond the first moves the head away from
the last. A volume that did not say what it is gets the flash count.

Gentle stops at the knee of the same curve. Below 4 workers the scan slows in step
and the CPU spent hardly falls: 1 worker took 73 s and 17 s of system time, 4 took
21 s and 20 s, and 8 took 15.5 s and 35 s, the extra probably lost to contention.

The cores counted are the ones this process may use, which in a container can be
far fewer than the host has.

The tree needs a writer per worker, so a caller sizes it with this before reading.
*/
width :: proc(cfg: Config) -> int {
	if cfg.workers > 0 {
		return cfg.workers
	}
	if cfg.media == .Rotational {
		return 1
	}
	if cfg.pace == .Gentle {
		return min(GENTLE_WORKERS, cpus())
	}
	return clamp(2 * cpus(), 1, MAX_WORKERS)
}

@(private)
MAX_WORKERS :: 32
@(private)
GENTLE_WORKERS :: 4

Error :: enum {
	None,
	Out_Of_Memory,
	Cancelled,
}

/*
Read everything under `root` into the tree.

Every directory below it is opened, each entry it holds becomes a node, and each
directory among them is read in turn. A worker takes the next directory the moment
one is known rather than waiting for a level to finish, so a tree that is wide near
the root and one that is deep in a single branch both keep them busy.

Returns once the tree holds everything under `root`; Cancelled if the scan was called
off part way, and Out_Of_Memory if the tree ran out of room, in which case what is
there is short rather than wrong.
*/
read :: proc(root: string, t: ^scan.Tree, cfg := Config{}) -> Error {
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

	// One writer per worker, and a writer needs an arena of its own, so a tree sized
	// for fewer caps how wide this can run.
	workers := min(width(cfg), len(t.arenas))

	linked := Linked_Files {
		seen = make(map[File_Id]struct{}, allocator),
	}
	defer delete(linked.seen)

	states := make([]Worker, workers, allocator)
	defer delete(states, allocator)
	for i in 0 ..< workers {
		states[i] = Worker {
			writer    = scan.writer(t, i),
			found     = make([dynamic]Dir, allocator),
			follow    = cfg.follow,
			linked    = &linked,
			scratch   = scratch_make(allocator),
			allocator = allocator,
		}
	}
	defer for &s in states {
		delete(s.found)
		scratch_destroy(&s.scratch)
	}

	seed := []Dir{{index = first, path = strings.clone(root, allocator)}}
	flow.manage(seed, states, walk_dir, hand_over, drop)

	for &s in states {
		if s.err != nil {
			return s.err
		}
	}
	if scan.cancelled(t) {
		return .Cancelled
	}
	return .None
}

// Move what a worker found into the queue, and judge whatever it could not read.
// Serialised by `manage`, so this is the one place the set of directories still to
// walk is touched.
@(private)
hand_over :: proc(d: Dir, ok: bool, w: ^Worker, queue: ^[dynamic]Dir) -> bool {
	for found in w.found {
		append(queue, found)
	}
	clear(&w.found)
	// A directory that would not open is worth nothing and is not worth retrying,
	// but it is no reason to abandon the rest of the volume. Running out of room
	// for the tree is, since everything after it would be missing silently.
	return w.err == nil && !scan.cancelled(w.writer.tree)
}

// A directory a stopped scan never reached. `walk_dir` frees what it is handed; this
// is the other half, since cancelling mid-volume otherwise strands a path per
// directory found but not yet walked. Runs on the thread that called `scan`, and
// paths are cloned from that context, so the two allocators are the same one.
@(private)
drop :: proc(d: Dir) {
	delete(d.path, context.allocator)
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
	linked:    ^Linked_Files, // shared by every worker
	err:       Error, // why this worker gave up, which only the manager acts on
	scratch:   Scratch, // reused by the platform's reader between directories
	allocator: mem.Allocator,
}

@(private)
walk_dir :: proc(d: Dir, w: ^Worker) -> bool {
	defer delete(d.path, w.allocator)
	if scan.cancelled(w.writer.tree) {
		return false
	}
	nodes, bytes, ok := read_dir(d, w)
	scan.progress(w.writer.tree, nodes, bytes)
	return ok
}

// One entry as a directory read describes it, before it becomes a node. `disk` is
// whatever the platform could learn about allocation; every reader fills it, since
// only the reader knows how good its own answer is. `links` is how many names the
// file has, left 0 by a reader that cannot tell, which charges every name.
@(private)
Entry :: struct {
	name:      string,
	size:      u64,
	disk:      u64,
	directory: bool,
	symlink:   bool,
	links:     u32,
	id:        File_Id,
	mount:     bool, // a directory another volume is mounted on
}

// Where a file's data lives, the same for every name it has.
@(private)
File_Id :: struct {
	device: u64,
	inode:  u64,
}

/*
The files with more than one name that some worker has already charged.

A hard-linked file is charged once, to the first of its names a worker records, and
every later name is an Extra_Name: in the tree so the file can be found at each path,
but not counted again, as the NTFS reader does with its extra names. Which name is
first depends on how the workers' directories happened to interleave, so a file
linked from two directories can be charged to either from one scan to the next. A
rollup charges a node once and for good, so the choice has to be made when the node is
published and cannot wait until every name is known. Only files with more than one
name come here, which keeps the lock off the path almost every file takes.
*/
@(private)
Linked_Files :: struct {
	mutex: sync.Mutex,
	seen:  map[File_Id]struct{},
}

// Record a name of `id`, and whether it is the first any worker has recorded.
@(private)
mark_charged :: proc(l: ^Linked_Files, id: File_Id) -> (first: bool, err: mem.Allocator_Error) {
	sync.mutex_guard(&l.mutex)
	_, _, first, err = map_entry(&l.seen, id)
	return
}

/*
Record one entry against the directory holding it.

`descend` marks an entry to walk in turn: a directory, or a symlink when the caller
asked for those to be followed. A directory another volume is mounted on is recorded
but not walked, so a scan stays on the volume it started on and never reaches the same
files twice: / reaches the Data volume through the firmlinks /usr/share/firmlinks
lists, such as /Users, and would read it again at /System/Volumes/Data. `charged` is
what the node adds to the volume's total, which is nothing for a directory, a link, or
a name of a file already charged. Shared so that what a node means cannot drift
between one platform's reader and another's.
*/
@(private)
record :: proc(
	w: ^Worker,
	parent: u32,
	e: Entry,
) -> (
	index: u32,
	descend: bool,
	charged: u64,
	ok: bool,
) {
	slot, err := scan.claim(&w.writer, 1)
	if err != nil {
		w.err = .Out_Of_Memory
		return 0, false, 0, false
	}
	index = slot
	n := scan.node(w.writer.tree, index)
	n.parent = parent
	n.name = scan.intern(&w.writer, e.name)
	n.size = e.size

	// A walker reaches a child through its parent, so the link is never in doubt.
	flags := scan.Node_Flags{.Used, .Settled}
	switch {
	case e.directory:
		flags |= {.Directory}
		descend = !e.mount
	case e.symlink:
		flags |= {.Reparse}
		descend = w.follow
	case:
		n.disk = e.disk
		charged = e.disk
		if e.links > 1 {
			first, map_err := mark_charged(w.linked, e.id)
			if map_err != nil {
				w.err = .Out_Of_Memory
				return 0, false, 0, false
			}
			if !first {
				flags |= {.Extra_Name}
				charged = 0
			}
		}
	}
	// Last, so a builder watching this tree never sees a node before its size.
	scan.node_publish(n, flags)
	return index, descend, charged, true
}
