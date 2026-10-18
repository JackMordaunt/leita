package walk

import "base:runtime"
import "core:hash"
import "core:sync"

import "../scan"

/*
What an update does with one directory of the tree it updates. A directory with no
mark is Keep.
*/
Mark :: enum u8 {
	Keep, // unchanged: its entries are copied, unless Update.probe finds otherwise
	List, // its own entries changed: read it again, and keep what below it did not
	Deep, // anything below it may have changed: read all of it again
}

/*
How to bring an earlier tree of the same place up to date: which of its directories
changed, as a change journal or a probe of them found.

`probe` is for a platform with no journal to ask. Every directory not marked is then
asked when it last changed, and one changed at or after `since`, in nanoseconds since
the epoch, is read again rather than copied. An entry a directory gains, loses or
renames moves the directory's modification time.

A file written in place moves only its own modification time (POSIX sys/stat.h,
stat(2)), and a journal may not name it either: FSEvents names a written file's
directory only once the file is closed (macOS 15.7, 2026-10-13: a file appended to
and fsynced while held open gave no event until close), so a disk image, a log or a
database's write-ahead log held open keeps growing unseen. Every copied directory's files of
at least `restat` bytes are therefore asked their size again, probe or journal, where
RESTATS says the platform asks (not Windows: stamp_other.odin); 0 asks none.

Asking every smaller file too would cost an update what a walk costs on a home of
millions of them, so each update asks one slice of them, of `slices`, the one `turn`
names: a file written in place is measured again within `slices` updates. A slice is
a hash of the file's path, which stays put while the turn moves on.
*/
// What asking a copied file its size again (disk_of) found.
@(private)
Verdict :: enum u8 {
	Sized, // the file answered: charge the size it gave
	Gone, // no such file, or its directory went or is no longer one: drop it
	Unknown, // it could not be asked (no permission, a path too long, I/O): keep the copy
}

Update :: struct {
	base:   ^scan.Tree,
	marks:  map[u32]Mark, // by node of base
	probe:  bool,
	since:  i64,
	restat: u64,
	slices: u64, // 0 asks no file under `restat` bytes
	turn:   u64,
	// How many directories the update read rather than copied, counted as it goes.
	read:   u64,
	// base's children, built by `update` if left empty. A caller that has built it
	// already, to find what changed in base, passes it and keeps it.
	index:  scan.Index,
	// The file each name base charged for one with more than one names, by node of
	// base (scan.Tree.linked), built by `update` so a copy keeps it.
	linked: map[u32]scan.File_Id,
}

/*
Read `root` into `t` as `u.base` says it was, reading again only what changed.

`u.base` is a finished tree of the same place, read before. A directory it marks
List is read from disk; one it marks Deep is walked; any other is copied from it,
entries, sizes and all, and its subdirectories are dealt with by their own marks. A
directory that a read finds and the base does not have is walked; one the base has
under the same name keeps its own mark. A directory the base could not read is
walked whatever its mark, since the base holds nothing of it. The result is the
tree a walk would have read, as far as the marks were right.

A file with more than one name stays charged to the name the base charged it under
while that name is still there, read or copied, by the file id the base kept for it
(scan.Tree.linked): another name of it, in a directory the update reads, Deep, listed,
unread in the base or new, is an extra. Without that, a name in a directory walked
again was charged beside the copied one, and the next baseline kept the total that
much too high. A base that kept no ids keeps its choice for a name a List job reads.
*/
update :: proc(root: string, u: ^Update, t: ^scan.Tree, cfg := Config{}) -> Error {
	when ODIN_OS == .Linux {
		if btrfs_update_needs_read(root, cfg.follow) {
			return read(root, t, cfg)
		}
	}
	if u.base.root >= scan.slots(u.base) {
		return read(root, t, cfg)
	}
	built := u.index.first == nil
	if built {
		ix, ix_err := scan.index_make(u.base)
		if ix_err != nil {
			return .Out_Of_Memory
		}
		u.index = ix
	}
	defer if built {
		scan.index_destroy(&u.index)
	}

	u.linked = make(map[u32]scan.File_Id, len(u.base.linked))
	defer {
		delete(u.linked)
		u.linked = nil
	}
	for named in u.base.linked {
		u.linked[named.node] = named.id
	}

	first, ok := claim_root(root, t)
	if !ok {
		return .Out_Of_Memory
	}
	return run(
		{index = first, path = root, base = u.base.root, job = job_of(u, u.base.root)},
		t,
		cfg,
		u,
	)
}

// The job a directory of the base is given by its mark. One the base could not
// read (scan.Node_Flag.Unread) has nothing to copy, so it is walked whatever its
// mark: the next scan may have the permission the last one lacked.
@(private)
job_of :: proc(u: ^Update, base: u32) -> Job {
	if .Unread in scan.node_flags(scan.node(u.base, base)) {
		return .Walk
	}
	switch u.marks[base] {
	case .Keep:
		return .Copy
	case .List:
		return .List
	case .Deep:
		return .Walk
	}
	return .Walk
}

// Whether a node of the base stands for a directory that is read through: a
// directory nothing else is mounted on, or a link the walk was told to follow.
@(private)
descends :: proc(flags: scan.Node_Flags, follow: bool) -> bool {
	if .Directory in flags {
		return .Mount not_in flags
	}
	return .Reparse in flags && follow
}

/*
Copy a directory's entries from the base, unchanged.

Under a probe it is first asked whether it changed, and read instead if it did or
cannot say. Under a probe or a journal its files of at least `restat` bytes are
asked their sizes, and its smaller files whose slice's turn it is, a file that is
gone dropped, since neither sees a file written while held open (Update). The copies
run on the workers, so these stats do too: on a home directory of 2.57M entries that
was 17,617 files, 45 ms warm and 1.9 s cold from one thread (2026-10-13).
*/
@(private)
copy_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	u := w.update
	if u.probe && changed_since(d.path, u.since) {
		return list_dir(d, w)
	}
	base := u.base
	// Every slot at once: one atomic add on the tree's counter a directory rather
	// than one a node. A slot left over by a file a probe found gone stays unused, as
	// a slot a reader claimed and never wrote does.
	count: u32
	for c := u.index.first[d.base]; c != scan.NO_NODE; c = u.index.next[c] {
		count += 1
	}
	if count == 0 {
		return 0, 0, true
	}
	slot, claim_err := scan.claim(&w.writer, count)
	if claim_err != nil {
		w.err = .Out_Of_Memory
		return 0, 0, false
	}
	when RESTATS {
		// Each file's slice is hashed on from its directory's path, hashed once here.
		dir := hash.fnv64a(transmute([]byte)d.path)
	}
	for c := u.index.first[d.base]; c != scan.NO_NODE; c = u.index.next[c] {
		b := scan.node(base, c)
		flags := scan.node_flags(b) & {.Directory, .Reparse, .Extra_Name, .Mount, .Shared}
		name := scan.name_of(base, c)
		disk := b.disk
		file := flags & {.Directory, .Reparse} == {}
		when RESTATS {
			if file && restat_due(u, disk, dir, name) {
				runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
				path, err := join(d.path, name, context.temp_allocator)
				if err != nil {
					w.err = .Out_Of_Memory
					return nodes, bytes, false
				}
				now, verdict := disk_of(path)
				switch verdict {
				case .Sized:
					// st_blocks, not what the file holds alone, so no longer Shared.
					disk = now
					flags -= {.Shared}
				case .Gone:
					continue
				case .Unknown:
				}
			}
		}

		n := scan.node(w.writer.tree, slot)
		n.parent = d.index
		n.name = scan.intern(&w.writer, name)
		n.disk = disk
		scan.node_publish(n, flags | {.Used, .Settled})
		if w.fold != nil && !fold_link(w, d.index, slot, flags) {
			return nodes, bytes, false
		}
		nodes += 1
		if file && .Extra_Name not_in flags {
			bytes += disk
			if id, linked := u.linked[c]; linked && !keep_paid(w, slot, id) {
				return nodes, bytes, false
			}
		}

		if descends(flags, w.follow) {
			child, join_err := join(d.path, name, w.allocator)
			if join_err != nil {
				w.err = .Out_Of_Memory
				return nodes, bytes, false
			}
			append(&w.found, Dir{index = slot, path = child, base = c, job = job_of(u, c)})
		}
		slot += 1
	}
	return nodes, bytes, true
}

/*
Whether a copied file of `disk` bytes, `name` in the directory whose path hashes to
`dir`, is asked its size again: one of at least `restat` bytes every update, a
smaller one when its slice's turn comes (Update).
*/
@(private)
restat_due :: proc(u: ^Update, disk, dir: u64, name: string) -> bool {
	switch {
	case u.restat == 0:
		return false
	case disk >= u.restat:
		return true
	case u.slices == 0:
		return false
	}
	return hash.fnv64a(transmute([]byte)name, dir) % u.slices == u.turn % u.slices
}

/*
Read a directory whose entries changed, as a walk would, then give each directory
it holds the job its namesake in the base has. One the base does not have is new,
and walked whole.
*/
@(private)
list_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	u := w.update
	sync.atomic_add(&u.read, 1)
	clear(&w.siblings)
	for c := u.index.first[d.base]; c != scan.NO_NODE; c = u.index.next[c] {
		w.siblings[scan.name_of(u.base, c)] = c
	}
	from := len(w.found)
	w.listing = true
	nodes, bytes, ok = read_dir(d, w)
	w.listing = false

	for &f in w.found[from:] {
		f.job = .Walk
		name := scan.name_of(w.writer.tree, f.index)
		was, known := w.siblings[name]
		if known && descends(scan.node_flags(scan.node(u.base, was)), w.follow) {
			f.base = was
			f.job = job_of(u, was)
		}
	}
	return
}

/*
For a file with more than one name that a List job reads: whether the base charged
it under this name, and whether the base had this name as a file at all.
*/
@(private)
kept_choice :: proc(w: ^Worker, name: string) -> (charged, known: bool) {
	if !w.listing {
		return false, false
	}
	was, found := w.siblings[name]
	if !found {
		return false, false
	}
	flags := scan.node_flags(scan.node(w.update.base, was))
	if flags & {.Directory, .Reparse} != {} {
		return false, false
	}
	return .Extra_Name not_in flags, true
}

/*
Mark each file with more than one name that the base charged as charged to the name
the base charged it under, before any directory is read, so counts holds to the
base's choice whichever directory the update reaches another name of it in first.
A name the update copies cannot say what file it names: the tree keeps no ids but
these. False when out of memory.
*/
@(private)
mark_base_paid :: proc(l: ^Linked_Files, base: ^scan.Tree) -> bool {
	for named in base.linked {
		if named.node >= scan.slots(base) {
			continue
		}
		_, value, inserted, err := map_entry(&l.payers, named.id)
		if err != nil {
			return false
		}
		if inserted {
			value^ = {
				base = named.node,
			}
		}
	}
	return true
}

// How far up a tree same_place and base_path go before taking a chain for a cycle,
// which only a corrupt base could hold.
@(private)
MAX_DEPTH :: 4096

/*
Whether `name` in the directory `parent` of the tree being read lies where the base's
node `was` did: the same name, in directories of the same names, up to each root.
*/
@(private)
same_place :: proc(w: ^Worker, was, parent: u32, name: string) -> bool {
	base, tree := w.update.base, w.writer.tree
	if scan.name_of(base, was) != name {
		return false
	}
	b, n := scan.node(base, was).parent, parent
	for _ in 0 ..< MAX_DEPTH {
		if b == base.root || n == tree.root {
			return b == base.root && n == tree.root
		}
		if scan.name_of(base, b) != scan.name_of(tree, n) {
			return false
		}
		b, n = scan.node(base, b).parent, scan.node(tree, n).parent
	}
	return false
}

/*
Whether the base's node `was` no longer names the file `id` on disk, so another name
of it has to pay for it: deleted or renamed since, in a directory this update reads.
A path that cannot be built or asked is taken to name it still.
*/
@(private)
base_name_gone :: proc(w: ^Worker, was: u32, id: File_Id) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	path, ok := base_path(w.update.base, was, context.temp_allocator)
	return ok && !still_names(path, id)
}

// The path of the base's node `was`, from the base's root, which names the place.
// scan.path stops at 64 directories, and a deeper name is still a name.
@(private)
base_path :: proc(base: ^scan.Tree, was: u32, allocator: runtime.Allocator) -> (string, bool) {
	chain := make([dynamic]u32, allocator)
	for at := was; at != base.root; at = scan.node(base, at).parent {
		if len(chain) >= MAX_DEPTH {
			return "", false
		}
		append(&chain, at)
	}
	path := scan.name_of(base, base.root)
	#reverse for at in chain {
		joined, err := join(path, scan.name_of(base, at), allocator)
		if err != nil {
			return "", false
		}
		path = joined
	}
	return path, true
}
