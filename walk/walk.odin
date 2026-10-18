/*
Package walk enumerates directories through the operating system.

It is the reader that works anywhere: any filesystem, any platform, no privilege. It
is also much slower than reading a filesystem's own metadata, because it pays a
syscall per directory and learns nothing the OS does not hand it. That makes it the
fallback rather than the default, and the yardstick a specialised reader is measured
against.

A directory listing is already the shape of the tree, so it writes straight into it.
Reading one directory is the only part that differs by platform, and it is the part
worth specialising: `read_dir` asks each kernel directly, getdents and statx on
Linux, getattrlistbulk on macOS, and a directory handle's listing on Windows.
*/
package walk

import "core:mem"
import "core:strings"
import "core:sync"

import "../scan"
import "jm:flow"

Config :: struct {
	workers: int, // 0 lets `width` choose
	// Descend through symlinks and junctions. On Linux a link to a directory above
	// it is not followed (follow_link); elsewhere such a loop is not detected.
	follow:  bool,
	media:   scan.Media, // what holds the tree, which `width` fits the choice to
	pace:    Pace,
	// Add each directory's total as it finishes, so a rollup afterwards copies
	// directories instead of charging every node. Off when a watcher is already
	// folding the same tree on its own thread.
	fold:    bool,
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

A directory read mostly waits on the volume and holds no core while it does, so more
workers than logical cores can still keep flash busier than one per core would:
reading a 2.6 million entry home directory on an 8-core M-series Mac took 15.8 s with
8 workers, 12.5 s with 16 and 11.5 s with 32. That walk was cold-ish, though, and a
warm Linux walk did not show the same climb: on a 24-logical-CPU machine, warm page
cache, ~/Source gave no further gain past the core count, and 32 workers (2x cores)
were bimodal under outside load, from 0.65 s to 6.5 s across runs that otherwise
matched (2026-10-12). Cold Linux was not measured, so this is a choice for stability
under load over an unmeasured cold gain: the default is the logical core count, not
twice it. The clamp at 32 is carried over from the Mac measurement and is rarely hit
at the core count; it still guards a machine with more logical CPUs than that was
tried on. A spinning disk gets one, on the assumption, not measured, that every read
in flight beyond the first moves the head away from the last. A volume that did not
say what it is gets the flash count.

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
	return clamp(cpus(), 1, MAX_WORKERS)
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
	first, ok := claim_root(root, t)
	if !ok {
		return .Out_Of_Memory
	}
	return run({index = first, path = root, job = .Walk}, t, cfg, nil)
}

// A node for `root`, holding itself, as the top of the tree.
@(private)
claim_root :: proc(root: string, t: ^scan.Tree) -> (first: u32, ok: bool) {
	w := scan.writer(t, 0)
	claim_err: scan.Error
	first, claim_err = scan.claim(&w, 1)
	if claim_err != nil {
		return 0, false
	}
	n := scan.node(t, first)
	n.parent = first // a root holds itself
	n.name = scan.intern(&w, root)
	n.flags = {.Used, .Settled, .Directory}
	t.root = first
	return first, true
}

// Read from `seed` down, which a walk and an update share. The seed's path is
// borrowed; the queue owns a copy.
@(private)
run :: proc(seed: Dir, t: ^scan.Tree, cfg: Config, u: ^Update) -> Error {
	allocator := context.allocator

	// One writer per worker, and a writer needs an arena of its own, so a tree sized
	// for fewer caps how wide this can run.
	workers := min(width(cfg), scan.writers(t))

	fold: ^Fold
	if cfg.fold {
		made, started := fold_start(allocator, seed.index)
		if !started {
			return .Out_Of_Memory
		}
		fold = made
	}
	defer fold_release(fold)

	linked := Linked_Files {
		payers = make(map[File_Id]Payer, allocator),
	}
	defer delete(linked.payers)
	if u != nil && !mark_base_paid(&linked, u.base) {
		return .Out_Of_Memory
	}

	search: Btrfs_Search
	btrfs_search_init(&search, t, allocator)
	defer btrfs_search_destroy(&search)

	clones := clones_make(allocator)
	defer delete(clones.paid)
	when ODIN_OS == .Darwin {
		darwin_retention(seed.path, t)
	}

	states := make([]Worker, workers, allocator)
	defer delete(states, allocator)
	for i in 0 ..< workers {
		states[i] = Worker {
			writer    = scan.writer(t, i),
			found     = make([dynamic]Dir, allocator),
			follow    = cfg.follow,
			linked    = &linked,
			btrfs     = &search,
			clones    = &clones,
			scratch   = scratch_make(allocator),
			update    = u,
			siblings  = make(map[string]u32, allocator),
			fold      = fold,
			dirs      = make([dynamic]u32, allocator),
			paid      = make([dynamic]scan.Link, allocator),
			allocator = allocator,
		}
	}
	defer for &s in states {
		delete(s.found)
		delete(s.siblings)
		delete(s.dirs)
		delete(s.paid)
		scratch_destroy(&s.scratch)
	}

	first := seed
	first.path = strings.clone(seed.path, allocator)
	flow.manage([]Dir{first}, states, walk_dir, hand_over, drop)
	paid, gathered := gather_paid(states, allocator)
	if !gathered {
		return .Out_Of_Memory
	}
	delete(t.linked)
	t.linked = paid

	if fold != nil {
		for &s in states {
			if s.err != nil {
				sync.atomic_store(&fold.bad, true)
			}
		}
		if scan.cancelled(t) {
			sync.atomic_store(&fold.bad, true)
		}
		fold_publish(fold, t, states)
	}

	unread: u64
	denied: bool
	for &s in states {
		unread += s.unread
		denied ||= s.denied
	}
	scan.add_unread(t, unread, denied)

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
	// A directory that would not open is counted and marked (mark_unread), and is
	// no reason to abandon the rest of the volume. Running out of room for the
	// tree is, since everything after it would be missing silently.
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

// A directory waiting to be read, and the node already standing for it. A walk reads
// every one; an update (update.odin) may instead copy it, or list it alone, from the
// node `base` names in the tree it updates.
@(private)
Dir :: struct {
	index:      u32,
	path:       string, // owned; freed once walked
	base:       u32, // the same directory in the tree updated, for a job other than Walk
	job:        Job,
	// The device and filesystem holding it, as the reader that found it learned
	// them; 0 where it did not, and the directory is asked when read. Only the
	// Linux reader uses them, to tell where a walk crosses onto another filesystem.
	device:     u64,
	filesystem: u128,
	btrfs:      bool, // filesystem is a btrfs pool's UUID
	// The directories it lies under where the reader keeps them (Ancestor); nil
	// where it does not.
	ancestors:  ^Ancestor,
}

/*
One directory on the way down to another, by device and inode, and the one above
it. A directory whose own device and inode are among those above it holds itself,
as a bind of a directory onto one below it does, so a reader that keeps these
records it as a mount instead of reading it again (enter in mounts_linux.odin).
Every directory below shares the one chain, so a level that adds nothing to it
copies nothing.
*/
@(private)
Ancestor :: struct {
	id: File_Id,
	up: ^Ancestor,
}

// What becomes of a directory waiting to be read.
@(private)
Job :: enum u8 {
	Walk, // read it and everything under it
	Copy, // unchanged: copy its entries from the tree updated
	List, // its entries changed: read it, and keep what under it is unchanged
}

@(private)
Worker :: struct {
	writer:    scan.Writer,
	found:     [dynamic]Dir,
	follow:    bool,
	linked:    ^Linked_Files, // shared by every worker
	btrfs:     ^Btrfs_Search, // shared by every worker
	clones:    ^Clones, // pure data streams, shared by every worker
	err:       Error, // why this worker gave up, which only the manager acts on
	scratch:   Scratch, // reused by the platform's reader between directories
	// An update's, shared by every worker and read only. nil for a walk.
	update:    ^Update,
	// Shared by every worker when the walk is folding totals. Nil otherwise.
	fold:      ^Fold,
	// Containers this worker recorded: child directories as it linked them, and
	// a root or a followed link when it finished the directory.
	dirs:      [dynamic]u32,
	// While a List job reads its directory: the entries the tree updated had in it,
	// by name, so a name it still has keeps the decision made about it there.
	siblings:  map[string]u32,
	listing:   bool,
	// Names this worker charged for a file with more than one (counts), the tree's
	// once the walk is done (scan.Tree.linked).
	paid:      [dynamic]scan.Link,
	// Directories this worker could not read whole, and whether any of them
	// refused for want of permission. Summed into the tree once the walk is done.
	unread:    u64,
	denied:    bool,
	allocator: mem.Allocator,
}

/*
Record that the directory at `index` could not be opened or listed, or that an
entry in it could not be asked about (kind_of in read_linux.odin), `denied` when
permission was what it lacked (EACCES, EPERM, ERROR_ACCESS_DENIED).

The node stays in the tree with whatever entries were recorded before the failure,
flagged Unread so an update reads it again instead of copying it as whole, and the
walk's total of such directories says at the end that the tree is short. Without
either, a directory the user cannot open counts as empty, and a baseline kept from
that scan passes it off as empty to every update after, with the permission or not.
*/
@(private)
mark_unread :: proc(w: ^Worker, index: u32, denied: bool) {
	scan.node_mark(scan.node(w.writer.tree, index), {.Unread})
	w.unread += 1
	w.denied ||= denied
}

@(private)
walk_dir :: proc(d: Dir, w: ^Worker) -> bool {
	defer delete(d.path, w.allocator)
	if scan.cancelled(w.writer.tree) {
		return false
	}
	nodes, bytes: u64
	ok: bool
	switch d.job {
	case .Walk:
		if w.update != nil {
			sync.atomic_add(&w.update.read, 1)
		}
		nodes, bytes, ok = read_dir(d, w)
	case .Copy:
		nodes, bytes, ok = copy_dir(d, w)
	case .List:
		nodes, bytes, ok = list_dir(d, w)
	}
	// Settle even when the directory would not open: it is in the tree with
	// whatever entries were recorded, and its parent is waiting on it. A worker
	// that has failed leaves the fold unfinished instead, and the rollup charges
	// the tree itself.
	if w.fold != nil {
		if w.err != nil || scan.cancelled(w.writer.tree) {
			sync.atomic_store(&w.fold.bad, true)
		} else if !fold_settle(w, d.index, bytes) {
			return false
		}
	}
	scan.progress(w.writer.tree, nodes, bytes)
	return ok
}

// One entry as a directory read describes it, before it becomes a node. `disk` is
// whatever the platform could learn about allocation; every reader fills it, since
// only the reader knows how good its own answer is. `links` is how many names the
// file has, left 0 by a reader that cannot tell, which charges every name.
@(private)
Entry :: struct {
	darwin:    Darwin_Measurement,
	name:      string,
	disk:      u64,
	directory: bool,
	symlink:   bool,
	links:     u32,
	id:        File_Id,
	mount:     bool, // a directory another volume is mounted on
	shared:    bool, // a file charged only what it does not share (scan.Node_Flag.Shared)
	extra:     bool, // a name of a file charged under another (`counts`)
	account:   scan.Account, // empty known: nothing measured; record_at does not store it
}

@(private)
File_Id :: scan.File_Id

/*
The files with more than one name that some worker has already charged.

A hard-linked file is charged once, to the first of its names a worker reaches, and
every later name is an Extra_Name: in the tree so the file can be found at each path,
but not counted again, as the NTFS reader does with its extra names. Which name is
first depends on how the workers' directories happened to interleave, so a file
linked from two directories can be charged to either from one scan to the next. A
rollup charges a node once and for good, so the choice has to be made when the node is
published and cannot wait until every name is known. Only files with more than one
name come here, which keeps the lock off the path almost every file takes.

An update starts with the files its base charged already marked, each by the name
the base charged it under (mark_base_paid in update.odin).
*/
@(private)
Linked_Files :: struct {
	mutex:  sync.Mutex,
	payers: map[File_Id]Payer,
}

/*
Which name a file with more than one is charged under: the base's node `base`, for
an update, which `present` says was found still on disk, or, at NO_NODE, a name
this walk read.
*/
@(private)
Payer :: struct {
	base:    u32,
	present: bool,
}

/*
Whether this name of a file with more than one is the one its file is charged to,
and if so, kept as the tree's at `index`.

A reader asks before it charges the file anything, and only the name counted may
claim the file's btrfs extents. Asked after, two workers could each search the
file: the first claims every extent, the second finds them paid by the same owner
and is charged nothing without being Shared, and then the second could win the
count, so the file was charged 0 and the name that paid dropped as an extra.

A file an update's base charged stays charged to the base's name while that name is
still there, read or copied; another name of it is an extra.
*/
@(private)
counts :: proc(w: ^Worker, index, parent: u32, e: Entry) -> (counted, ok: bool) {
	counted, ok = settle(w, parent, e)
	if ok && counted {
		ok = keep_paid(w, index, e.id)
	}
	return
}

// Whether this name pays for its file, settled under the map's lock (counts).
@(private)
settle :: proc(w: ^Worker, parent: u32, e: Entry) -> (counted, ok: bool) {
	l := w.linked
	sync.mutex_lock(&l.mutex)
	defer sync.mutex_unlock(&l.mutex)
	_, value, inserted, err := map_entry(&l.payers, e.id)
	if err != nil {
		w.err = .Out_Of_Memory
		return false, false
	}
	if inserted {
		value^ = {
			base = scan.NO_NODE,
		}
		// A base that kept no file ids still says, for a name a List job reads,
		// which name it charged, and the one charged in its place may be in a
		// directory this update copies rather than reads.
		if was, known := kept_choice(w, e.name); known {
			return was, true
		}
		return true, true
	}
	payer := value^
	switch {
	case payer.base == scan.NO_NODE:
		return false, true
	case same_place(w, payer.base, parent, e.name):
		value^ = {
			base = scan.NO_NODE,
		}
		return true, true
	case payer.present:
		return false, true
	}
	// Asked with the lock let go, since a stat may wait on the disk. Whichever name
	// settles the file first is believed.
	sync.mutex_unlock(&l.mutex)
	gone := base_name_gone(w, payer.base, e.id)
	sync.mutex_lock(&l.mutex)
	if l.payers[e.id] != payer {
		return false, true
	}
	l.payers[e.id] = {
		base    = scan.NO_NODE if gone else payer.base,
		present = !gone,
	}
	return gone, true
}

// Keep the name at `index` as the one `id` is charged under, in this worker's own
// list so no lock is held for it, for counts and for a name an update copies.
@(private)
keep_paid :: proc(w: ^Worker, index: u32, id: File_Id) -> bool {
	if _, err := append(&w.paid, scan.Link{node = index, id = id}); err != nil {
		w.err = .Out_Of_Memory
		return false
	}
	return true
}

// Every name the workers kept as charged for a file with more than one, as one list
// for the tree (scan.Tree.linked).
@(private)
gather_paid :: proc(states: []Worker, allocator: mem.Allocator) -> ([dynamic]scan.Link, bool) {
	count := 0
	for &s in states {
		count += len(s.paid)
	}
	all, err := make([dynamic]scan.Link, 0, count, allocator)
	if err != nil {
		return nil, false
	}
	for &s in states {
		append(&all, ..s.paid[:])
	}
	return all, true
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
	e := e
	if e.links > 1 && !e.directory && !e.symlink {
		counted, counted_ok := counts(w, slot, parent, e)
		if !counted_ok {
			return 0, false, 0, false
		}
		e.extra = !counted
	}
	when ODIN_OS == .Darwin {
		if !charge_darwin(w, &e) {
			return 0, false, 0, false
		}
	}
	descend, charged, ok = record_at(w, slot, parent, e, scan.intern(&w.writer, e.name))
	return slot, descend, charged, ok
}

/*
Fill one slot this worker already claimed, with a name it already stored.

The Linux reader claims a directory's slots and copies its names once, then fills
each entry here. Readers that learn an entry only as its buffer arrives still go
through `record`, one claim and one copy at a time. Either way, whether a name of a
file with more than one is an extra (`counts`) is decided before this is called.
*/
@(private)
record_at :: proc(
	w: ^Worker,
	index: u32,
	parent: u32,
	e: Entry,
	name: scan.Name,
) -> (
	descend: bool,
	charged: u64,
	ok: bool,
) {
	n := scan.node(w.writer.tree, index)
	n.parent = parent
	n.name = name
	if e.account.known != nil && !scan.account_set(w.writer.tree, index, e.account) {
		w.err = .Out_Of_Memory
		return false, 0, false
	}

	// A walker reaches a child through its parent, so the link is never in doubt.
	flags := scan.Node_Flags{.Used, .Settled}
	switch {
	case e.directory:
		flags |= {.Directory}
		descend = !e.mount
		if e.mount {
			flags |= {.Mount}
		}
	case e.symlink:
		flags |= {.Reparse}
		descend = w.follow
	case:
		n.disk = e.disk
		charged = e.disk
		if e.shared {
			flags |= {.Shared}
		}
		if e.extra {
			flags |= {.Extra_Name}
			charged = 0
		}
	}
	when ODIN_OS == .Darwin {
		if !record_darwin_account(w, index, e) {
			return false, 0, false
		}
	}
	// Last, so a builder watching this tree never sees a node before its size.
	scan.node_publish(n, flags)
	if w.fold != nil && !fold_link(w, parent, index, flags) {
		return false, 0, false
	}
	return descend, charged, true
}
