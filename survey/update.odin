package survey

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "jm:timefmt"

import "../changes"
import "../gui/query"
import "../journal"
import "../scan"
import "../walk"

/*
How a Fill with a baseline read its place: whole, or by updating the last tree of it
from what the system says changed since.
*/
Fill_Kind :: enum u8 {
	Full,
	Updated,
}

/*
What an update learnt what changed from: the system's own change journal (macOS,
Windows), leita's recorder on Linux (package journal), or, with neither, each
directory's modification time.
*/
Read_Source :: enum u8 {
	System,
	Recorded,
	Times,
}

/*
RESTAT is the least a file of a copied directory holds for an update to ask its size
again, on macOS and Linux (walk.RESTATS; Windows keeps the size copied): history's
KEPT_MIN, so every file history keeps is current there. Neither a probe nor FSEvents
sees a file written while held open (walk.Update); on a home directory such files (a
VM's disk image, logs, a database's write-ahead log) left an update 10.1 GB short
(2026-10-13). A smaller file written in place, in a directory that did not change,
keeps its old size until the next whole scan; over a day of a home directory that was
8.7 MiB in 110.8 GiB (measured 2026-10-12, 162 files).
*/
RESTAT :: query.KEPT_MIN

/*
Read the place, from its baseline when that can be trusted, and keep the result as
the next baseline. A place is read whole when f.whole asks, it has no baseline, the
baseline is of another place or cannot be read, or the system cannot say what changed
(changes.since says why); f.why says which. Only a walk's or the MFT's tree is
kept: a made-up disk is always read whole, and fill_run never brings one here.
*/
@(private)
fill_from_baseline :: proc(f: ^Fill) {
	place := scan.location(f.target, context.allocator)
	defer delete(place)

	base: scan.Tree
	cursor: changes.Cursor
	why := "asked to read it whole"
	loaded: bool
	if !f.whole {
		f.taken, _ = os.modification_time_by_path(f.baseline)
		cursor, why, loaded = baseline_load(f.baseline, place, &base)
	}
	if loaded {
		defer scan.tree_destroy(&base)
		set, next, err := changes.since(place, cursor)
		defer changes.change_set_destroy(&set)
		switch {
		case err != nil:
			why = "no room to read what changed"
		case set.rescan:
			why = set.why
		case:
			// An update fails as a walk does, short of room or called off, and
			// what it read is left as a walk's would be.
			f.walk_err = apply(f, place, &base, set)
			f.how = .Updated
			f.by = .Recorded if set.by_hash else .Times if set.probe else .System
			if f.walk_err == .None {
				f.saved = baseline_save(f.baseline, place, f.tree, next)
			}
			return
		}
	}

	f.how = .Full
	f.why = why
	now, have := changes.now(place)
	switch f.engine {
	case .Mft:
		fill_mft(f)
	case .Walk:
		fill_walk(f)
	case .Synthetic, .None:
	}
	if !have {
		f.why = "the system cannot say what changes in this place"
		return
	}
	if f.mft_err == nil && f.walk_err == nil && f.tree_err == nil {
		f.saved = baseline_save(f.baseline, place, f.tree, now)
	}
}

/*
Read `place` into f.tree from `base`, reading again what `set` says changed: each
directory named shallow listed, each named deep walked, each whose path hashes to
one the set names listed, and with a probe every directory asked. A path the base
does not have marks the nearest directory above it that it does, which then finds
what is new.
*/
@(private)
apply :: proc(f: ^Fill, place: string, base: ^scan.Tree, set: changes.Change_Set) -> walk.Error {
	ix, ix_err := scan.index_make(base)
	if ix_err != nil {
		return .Out_Of_Memory
	}
	defer scan.index_destroy(&ix)
	u := walk.Update {
		base   = base,
		index  = ix,
		probe  = set.probe,
		since  = set.since,
		restat = RESTAT,
	}
	defer delete(u.marks)
	if set.by_hash {
		mark_hashed(&u, base, ix, set)
	}
	for path in set.shallow {
		if n := locate(base, ix, place, path); n != scan.NO_NODE && u.marks[n] != .Deep {
			u.marks[n] = .List
		}
	}
	for path in set.deep {
		n, exact := locate_exact(base, ix, place, path)
		if n == scan.NO_NODE {
			continue
		}
		// Not in the base: new, so the directory above it finds it and walks it.
		u.marks[n] = .Deep if exact else max(u.marks[n], walk.Mark.List)
	}
	cfg := f.wcfg
	// The watcher charges on its own thread. Folding here too would count twice.
	cfg.fold = !f.watched
	err := walk.update(place, &u, f.tree, cfg)
	f.reread = u.read
	return err
}

/*
mark_hashed marks List each directory of `base` whose path, spelt from set.root,
hashes to one set.hashes names, as the recorder hashes paths (package journal). The
paths are hashed as the tree is gone down, each from its parent's, so none is made.

Each node is stacked once. A parent cycle would otherwise list a directory as a
child of its descendant and the stack would grow forever; a sibling link that
repeats is the same, and the walk stops after every node once.
*/
@(private)
mark_hashed :: proc(u: ^walk.Update, base: ^scan.Tree, ix: scan.Index, set: changes.Change_Set) {
	Dir :: struct {
		node: u32,
		hash: u64,
	}
	count := scan.slots(base)
	seen := make([]bool, count, context.temp_allocator)
	if int(count) != len(seen) || base.root >= count {
		return
	}
	stack := make([dynamic]Dir, context.temp_allocator)
	seen[base.root] = true
	append(&stack, Dir{base.root, journal.hash_path(set.root)})
	for len(stack) > 0 {
		d := pop(&stack)
		if d.hash in set.hashes && u.marks[d.node] != .Deep {
			u.marks[d.node] = .List
		}
		if int(d.node) >= len(ix.first) {
			continue
		}
		// The root's path may end in a slash already, as "/" does.
		slash := d.node != base.root || !strings.has_suffix(set.root, "/")
		c := ix.first[d.node]
		for left := count; left > 0 && c != scan.NO_NODE; left -= 1 {
			if c >= count || int(c) >= len(ix.next) {
				break
			}
			next := ix.next[c]
			// Already stacked. Skip it and keep the rest of the list; a link
			// that repeats runs out of `left` and the walk ends.
			if seen[c] {
				c = next
				continue
			}
			seen[c] = true
			flags := scan.node_flags(scan.node(base, c))
			if .Directory in flags && .Mount not_in flags {
				append(&stack, Dir{c, journal.hash_child(d.hash, scan.name_of(base, c), slash)})
			}
			c = next
		}
	}
}

/*
how_read says in words how a fill with a baseline read its place, in the temp
allocator: "updated: N directories read again since <time>", or "read whole: <why>".
On Linux an update says what it learnt the changes from: "(recorded changes)" from
the recorder's log, "(folder times)" from each directory's modification time. An
update with no time to give, as a run the monitor recorded before it kept the count
and the time, is "updated from the last scan".
*/
how_read :: proc(
	updated: bool,
	why: string,
	reread: u64 = 0,
	taken := time.Time{},
	by := Read_Source.System,
) -> string {
	from := ""
	switch by {
	case .System:
	case .Recorded:
		from = " (recorded changes)"
	case .Times:
		from = " (folder times)"
	}
	switch {
	case updated && taken == {}:
		return "updated from the last scan"
	case updated:
		return fmt.tprintf(
			"updated: %d %s read again since %s%s",
			reread,
			"directory" if reread == 1 else "directories",
			timefmt.local(taken, "%Y-%m-%d %H:%M", context.temp_allocator),
			from,
		)
	case why != "":
		return fmt.tprintf("read whole: %s", why)
	}
	return "read whole"
}

// The directory of `base` that `path` names, or the nearest above it that the base
// has; NO_NODE for a path outside the place.
@(private)
locate :: proc(base: ^scan.Tree, ix: scan.Index, place, path: string) -> u32 {
	n, _ := locate_exact(base, ix, place, path)
	return n
}

@(private)
locate_exact :: proc(
	base: ^scan.Tree,
	ix: scan.Index,
	place, path: string,
) -> (
	n: u32,
	exact: bool,
) {
	rest, inside := changes.under(place, path)
	if !inside {
		return scan.NO_NODE, false
	}
	fold := ODIN_OS == .Windows || ODIN_OS == .Darwin
	n = base.root
	exact = true
	for name in strings.split_iterator(&rest, scan.SEPARATOR) {
		if name == "" {
			continue
		}
		child := scan.child_named(base, ix, n, name, fold)
		if child == scan.NO_NODE {
			exact = false
			break
		}
		n = child
	}
	// A path that names a file changed what its directory holds.
	if .Directory not_in scan.node_flags(scan.node(base, n)) && n != base.root {
		n = scan.node(base, n).parent
		exact = false
	}
	return n, exact
}
