package leita_app

import "core:fmt"
import "core:strings"
import "core:sync"

import "../../history"
import "../../scan"
import "../../survey"
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
		fmt.eprintln("leita: scans will not be kept:", path, err)
		storage_problem_set(&d.history_problem, history.describe(err))
		free(st)
		return
	}
	d.history = st
	d.history_path = strings.clone(path)
}

history_close :: proc(d: ^Desk) {
	delete(d.history_problem)
	d.history_problem = ""
	if d.history != nil {
		history.close(d.history)
		free(d.history)
		d.history = nil
	}
	delete(d.history_path)
	d.history_path = ""
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
	place := history.place_of(&s.tree, top, s.engine)
	if d.history.read_only {
		if then, found := history.latest(d.history, place, 0); found {
			compare(d, then.id)
		}
		return
	}
	id, err := history.keep(
		d.history,
		place,
		&s.tree,
		&s.roll,
		top,
		sync.atomic_load(&s.tree.nodes_done),
		{s.disk_total, s.disk_free},
	)
	if err != nil {
		fmt.eprintln("leita: could not keep the scan:", err)
		storage_problem_set(&d.history_problem, history.describe(err))
		fault := err.? or_else {}
		delete(fault.text, d.history.db.allocator)
		if then, found := history.latest(d.history, place, 0); found {
			compare(d, then.id)
		}
		return
	}
	storage_problem_set(&d.history_problem, "")
	d.snapshot = id
	if then, found := history.latest(d.history, place, id); found {
		compare(d, then.id)
	}
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
	snapshots, _ := history.list(d.history, history.place_of(&s.tree, top, s.engine))
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
		fmt.eprintln("leita: could not read the snapshot:", err)
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
		path := history.path_under(at, scan.name_of(&s.tree, c))
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
	snapshots, _ := history.list(d.history, history.place_of(&s.tree, top, s.engine))
	earlier := make([dynamic]query.Snapshot, context.temp_allocator)
	for snap in snapshots {
		if snap.id != d.snapshot {
			append(&earlier, query.Snapshot{snap.id, snap.taken, snap.bytes, snap.items})
		}
	}
	r.snapshots = earlier[:]
	return r
}

// record_answer is the audit trail, the newest RECORD_LIMIT of it. A rename that
// went through keeps its new name where a failed one keeps its reason.
record_answer :: proc(d: ^Desk) -> query.Record_Result {
	if d.history == nil {
		return {}
	}
	done, err := history.actions(d.history, limit = query.RECORD_LIMIT)
	if err != nil {
		fmt.eprintln("leita: could not read the audit trail:", err)
		return {}
	}
	actions := make([]query.Action, len(done), context.temp_allocator)
	for a, i in done {
		actions[i] = {
			taken  = a.taken,
			path   = a.path,
			bytes  = a.bytes,
			failed = a.failed,
		}
		switch {
		case a.failed:
			actions[i].why = a.detail
		case a.kind == .Rename:
			actions[i].renamed_to = a.detail
		}
	}
	return {kept = true, actions = actions}
}
