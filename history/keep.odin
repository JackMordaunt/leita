package estoile_history

import "core:strings"
import "core:time"

import "jm:sqlite3"

import "../scan"
import "../survey"

/*
What a finished scan keeps, the same whichever binary ran it, so the window's
scans and the command line's make one timeline of each place.
*/

/*
keep keeps the finished scan in t from its top: under place, taken now, its
totals, and every entry under top holding at least KEPT_MIN. items is how many
nodes the scan found. The rollup must be linked (survey.Rollup.linked) and
advanced over all of t.
*/
keep :: proc(
	st: ^Store,
	place: string,
	t: ^scan.Tree,
	roll: ^survey.Rollup,
	top: u32,
	items: u64,
) -> (
	id: i64,
	err: sqlite3.Error,
) {
	assert(roll.linked, "keeping a scan needs a linked rollup")
	entries := make([dynamic]Entry, context.temp_allocator)
	append(&entries, Entry{"", survey.total(roll, top)})
	collect(t, roll, &entries, top, "")
	return save(
		st,
		place,
		time.time_to_unix(time.now()),
		survey.total(roll, top),
		items,
		entries[:],
	)
}

// collect adds what dir holds of at least KEPT_MIN, all the way down, each named
// by its path under the top: dir's own is at.
@(private)
collect :: proc(t: ^scan.Tree, roll: ^survey.Rollup, into: ^[dynamic]Entry, dir: u32, at: string) {
	it := survey.children(roll, dir)
	for c in survey.next_child(&it) {
		n := scan.node(t, c)
		directory := .Directory in scan.node_flags(n)
		bytes := survey.total(roll, c) if directory else n.disk
		if bytes < KEPT_MIN {
			continue
		}
		path := path_under(at, scan.name_of(t, c))
		append(into, Entry{path, bytes})
		if directory {
			collect(t, roll, into, c, path)
		}
	}
}

// path_under is the path of name in the directory at path at, under the top, in
// the temp allocator.
path_under :: proc(at, name: string) -> string {
	if at == "" {
		return strings.clone(name, context.temp_allocator)
	}
	return strings.concatenate({at, "/", name}, context.temp_allocator)
}

// place_of is what a scan's snapshots are kept under: the path of its top, and a
// made-up disk's apart from the real one at the same path. In the temp allocator.
place_of :: proc(t: ^scan.Tree, top: u32, engine: scan.Engine) -> string {
	path := scan.path(t, top, context.temp_allocator)
	if engine == .Synthetic {
		return strings.concatenate({"synthetic:", path}, context.temp_allocator)
	}
	return path
}

// latest is the newest snapshot of place other than id, and whether there is one.
latest :: proc(st: ^Store, place: string, except: i64 = 0) -> (Snapshot, bool) {
	snapshots, _ := list(st, place)
	for snap in snapshots {
		if snap.id != except {
			return snap, true
		}
	}
	return {}, false
}
