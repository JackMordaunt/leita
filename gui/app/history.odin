package estoile_app

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

import "../../scan"
import "../../survey"
import "../history"
import "../query"

/*
The scans kept, on the desk: each finished scan is kept in the history store,
and compared with the last kept before it of the same place until the window
asks for another. Comparing finds what each node held in that snapshot, once,
into Desk.was; every answer after reads it from there.

A store that cannot be opened turns history off for the session, rather than
the window: everything else works without it.
*/

// history_open opens the store at path, or leaves history off for "".
history_open :: proc(d: ^Desk, path: string) {
	if path == "" {
		return
	}
	st := new(history.Store)
	if err := history.open(st, path); err != nil {
		fmt.eprintln("estoile: scans will not be kept:", path, err)
		free(st)
		return
	}
	d.history = st
}

history_close :: proc(d: ^Desk) {
	if d.history != nil {
		history.close(d.history)
		free(d.history)
		d.history = nil
	}
	delete(d.was)
}

// keep keeps the scan just finished, and compares it with the last kept before
// it of the same place.
keep :: proc(d: ^Desk) {
	s := d.scan
	top, ok := root(s)
	if d.history == nil || !ok {
		return
	}
	entries := make([dynamic]history.Entry, context.temp_allocator)
	append(&entries, history.Entry{"", survey.total(&s.roll, top)})
	collect_kept(s, &entries, top, "")
	place := place_of(s, top)
	id, err := history.save(
		d.history,
		place,
		time.time_to_unix(time.now()),
		survey.total(&s.roll, top),
		sync.atomic_load(&s.tree.nodes_done),
		entries[:],
	)
	if err != nil {
		fmt.eprintln("estoile: could not keep the scan:", err)
		return
	}
	d.snapshot = id
	snapshots, _ := history.list(d.history, place)
	for snap in snapshots {
		if snap.id != id {
			compare(d, snap.id)
			break
		}
	}
}

// collect_kept adds what dir holds of at least history.KEPT_MIN, all the way down,
// each named by its path under the top: dir's own is at.
collect_kept :: proc(s: ^Scan, into: ^[dynamic]history.Entry, dir: u32, at: string) {
	it := survey.children(&s.roll, dir)
	for c in survey.next_child(&it) {
		n := scan.node(&s.tree, c)
		directory := .Directory in scan.node_flags(n)
		bytes := survey.total(&s.roll, c) if directory else n.disk
		if bytes < history.KEPT_MIN {
			continue
		}
		path := path_under(at, scan.name_of(&s.tree, c))
		append(into, history.Entry{path, bytes})
		if directory {
			collect_kept(s, into, c, path)
		}
	}
}

// path_under is the path of name in the directory at path at, under the top.
path_under :: proc(at, name: string) -> string {
	if at == "" {
		return strings.clone(name, context.temp_allocator)
	}
	return strings.concatenate({at, "/", name}, context.temp_allocator)
}

// place_of is what a scan's snapshots are kept under: the path of its top, and a
// made-up disk's apart from the real one at the same path.
place_of :: proc(s: ^Scan, top: u32) -> string {
	path := scan.path(&s.tree, top, context.temp_allocator)
	if s.engine == .Synthetic {
		return strings.concatenate({"synthetic:", path}, context.temp_allocator)
	}
	return path
}

// compare compares the scan with snapshot id of its place, or with none for 0 or
// for a snapshot of somewhere else.
compare :: proc(d: ^Desk, id: i64) {
	clear(&d.was)
	d.compared = {}
	s := d.scan
	top, ok := u32(0), false
	if s != nil {
		top, ok = root(s)
	}
	if id == 0 || d.history == nil || !ok {
		return
	}
	snapshots, _ := history.list(d.history, place_of(s, top))
	for snap in snapshots {
		if snap.id == id {
			d.compared = {snap.id, snap.taken, snap.bytes, snap.items}
		}
	}
	if d.compared.id == 0 {
		return
	}
	then, err := history.load(d.history, id, context.temp_allocator)
	if err != nil {
		fmt.eprintln("estoile: could not read the snapshot:", err)
		d.compared = {}
		return
	}
	if bytes, found := then[""]; found {
		d.was[top] = bytes
		note_was(s, d, then, top, "")
	}
}

// note_was notes what each entry under dir held in then, into Desk.was. Only a
// directory kept can hold an entry kept, so the walk goes no deeper than then does.
note_was :: proc(s: ^Scan, d: ^Desk, then: map[string]u64, dir: u32, at: string) {
	it := survey.children(&s.roll, dir)
	for c in survey.next_child(&it) {
		n := scan.node(&s.tree, c)
		path := path_under(at, scan.name_of(&s.tree, c))
		bytes, found := then[path]
		if !found {
			continue
		}
		d.was[c] = bytes
		if .Directory in scan.node_flags(n) {
			note_was(s, d, then, c, path)
		}
	}
}

// was_of is what node held in the snapshot compared with, or -1: none is, or it
// was not kept.
was_of :: proc(d: ^Desk, node: u32) -> i64 {
	if d.compared.id == 0 {
		return -1
	}
	bytes, found := d.was[node]
	return i64(bytes) if found else -1
}

history_answer :: proc(d: ^Desk, q: query.History) -> query.History_Result {
	r := query.History_Result {
		generation = d.generation,
		kept       = d.history != nil,
		ready      = d.snapshot != 0,
		compared   = d.compared,
	}
	s := d.scan
	top, ok := u32(0), false
	if s != nil {
		top, ok = root(s)
	}
	if q.generation != d.generation || d.history == nil || !ok {
		return r
	}
	snapshots, _ := history.list(d.history, place_of(s, top))
	earlier := make([dynamic]query.Snapshot, context.temp_allocator)
	for snap in snapshots {
		if snap.id != d.snapshot {
			append(&earlier, query.Snapshot{snap.id, snap.taken, snap.bytes, snap.items})
		}
	}
	r.snapshots = earlier[:]
	return r
}
