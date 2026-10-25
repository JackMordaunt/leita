package leita_app

import "core:strings"
import "core:thread"

import "jm:stream"
import "jm:ui"

import "../../scan"
import "../../search"
import "../../survey"
import "../query"

/*
Searching the scan (package search), for query.Search.

Each live Search need is a Finding: a search over the scan's tree, grown a pass
at a time. A pass runs in chunks on the host's workers, never on the desk, which
keeps answering while it runs; whichever worker finishes the last chunk hands the
pass back through a port, and the desk takes it in and answers the need. A need
is first answered once its first pass is in: until then the view shows what it
had.

While the scan runs, each tick starts another pass over what it has found since,
for every finding without one running, so results refine at the rate the rest of
the window does. Once the scan is over a last pass makes the search complete,
and nothing more runs for it.

A need that goes calls off its pass. Anything that changes the tree under a pass
(a new scan, a rename, the window closing) halts every pass first: each is called
off, and the desk waits the moment until its chunks have stopped.
*/

// Finding is one live Search need and its search.
Finding :: struct {
	key:       ui.Need_Key,
	q:         query.Search, // its term owned
	s:         search.Search, // over the tree of q.generation, while that is the scan's
	searching: bool, // s is initialised
	pass:      ^search.Pass, // the one running, or nil
	answered:  bool, // a pass has finished, so there is something to send
	gone:      bool, // the need went while a pass ran; freed when the pass is in
}

// Finished_Pass is a pass whose chunks have all finished, back from the workers.
Finished_Pass :: struct {
	pass: ^search.Pass,
}

finished_in :: proc(e: Finished_Pass) -> Desk_In {
	return e
}

// find_open starts searching for a Search need that has appeared.
find_open :: proc(d: ^Desk, key: ui.Need_Key, q: query.Search) {
	f := new(Finding)
	f.key = key
	f.q = q
	f.q.term = strings.clone(q.term)
	d.findings[key] = f
	s := d.scan
	if s != nil && s.grown && q.generation == d.generation {
		search.search_init(&f.s, &s.tree, f.q.term, query.SEARCH_LIMIT)
		f.searching = true
		find_more(d, f)
	}
}

// find_close forgets a Search need that has gone, calling off its pass.
find_close :: proc(d: ^Desk, key: ui.Need_Key) {
	f, ok := d.findings[key]
	if !ok {
		return
	}
	delete_key(&d.findings, key)
	if f.pass != nil {
		search.pass_cancel(f.pass)
		f.gone = true // the pass still reads it; freed when it is in
		return
	}
	find_free(f)
}

find_free :: proc(f: ^Finding) {
	if f.searching {
		search.search_destroy(&f.s)
	}
	delete(f.q.term)
	free(f)
}

// find_more starts a pass for f over whatever the scan has found that it has not
// looked at, unless one is running or there is nothing new.
find_more :: proc(d: ^Desk, f: ^Finding) {
	s := d.scan
	if f.pass != nil || !f.searching || s == nil {
		return
	}
	p := search.pass_begin(&f.s, s.roll.seen, s.state != .Scanning)
	if p == nil {
		return
	}
	p.on_done = hand_back
	p.user = d.searched
	f.pass = p
	d.passes[p] = f
	for &c in p.chunks {
		stream.submit(d.workers, run_chunk, &c)
	}
}

@(private)
run_chunk :: proc(data: rawptr) {
	search.pass_run((^search.Chunk)(data))
}

// hand_back gives a pass back to the desk, on the worker that finished its last
// chunk.
@(private)
hand_back :: proc(p: ^search.Pass) {
	stream.port_send((^stream.Port(Finished_Pass))(p.user)^, Finished_Pass{p})
}

// take_pass takes a finished pass in, and answers its need.
take_pass :: proc(d: ^Desk, p: ^search.Pass) {
	f := d.passes[p]
	delete_key(&d.passes, p)
	if f == nil {
		// Halted: what it found is about a tree that has changed since.
		search.pass_free(p)
		return
	}
	f.pass = nil
	if f.gone {
		search.pass_free(p)
		find_free(f)
		return
	}
	search.pass_end(&f.s, p)
	f.answered = true
	answer(d, f.key, f.q)
	notify(d)
}

// find_tick starts the next pass of every search the scan has moved on for.
find_tick :: proc(d: ^Desk) {
	for _, f in d.findings {
		find_more(d, f)
	}
}

/*
find_halt calls off every pass and waits until none is reading the tree, for
whatever is about to change it. What each pass found is dropped when it comes
in; the searches it ran for start again with forget, or with the tree as it is.
*/
find_halt :: proc(d: ^Desk) {
	for p, f in d.passes {
		if f != nil {
			search.pass_cancel(p)
		}
	}
	for p, f in d.passes {
		if f == nil {
			continue
		}
		for search.pass_running(p) {
			thread.yield()
		}
		d.passes[p] = nil
		f.pass = nil
		if f.gone {
			find_free(f)
		}
	}
}

/*
find_restart searches again, from the start, everything being searched for: the
tree has changed under the searches, by a rename or a restatement. What each had
found is still answered until its first new pass is in.
*/
find_restart :: proc(d: ^Desk) {
	find_halt(d)
	for _, f in d.findings {
		if f.searching {
			tree := f.s.tree
			search.search_destroy(&f.s)
			search.search_init(&f.s, tree, f.q.term, query.SEARCH_LIMIT)
			f.answered = false
		}
	}
	find_tick(d)
}

// find_forget drops every search's hold on the scan's tree, for a scan about to
// end: their needs name a generation that is gone, and are answered empty.
find_forget :: proc(d: ^Desk) {
	find_halt(d)
	for _, f in d.findings {
		if f.searching {
			search.search_destroy(&f.s)
			f.searching = false
		}
	}
}

// find_answer is what a search has found, as the window is shown it. Nothing
// until its first pass is in.
find_answer :: proc(
	d: ^Desk,
	key: ui.Need_Key,
	q: query.Search,
	allocator := context.temp_allocator,
) -> (
	query.Search_Result,
	bool,
) {
	r := query.Search_Result {
		generation = d.generation,
		term       = q.term,
	}
	f := d.findings[key]
	s := d.scan
	if f == nil || !f.searching || s == nil || q.generation != d.generation {
		r.complete = true
		return r, true
	}
	if !f.answered {
		return r, false
	}
	r.total = f.s.total
	r.complete = f.s.final
	hits := make([dynamic]query.Hit, 0, len(f.s.top), allocator)
	for h in f.s.top {
		if survey.removed(&s.roll, &s.tree, h.node) {
			r.total -= 1
			continue
		}
		n := scan.node(&s.tree, h.node)
		directory := .Directory in scan.node_flags(n)
		found := search.describe(&f.s, h.node, d.scratch, allocator)
		// A made-up disk's path is shown as the Mac writes it, which drops a
		// separator after the root on Windows: the name and the marks in it
		// move back by as many bytes.
		full := len(found.path)
		found.path = shown_path(s, found.path, allocator)
		dropped := full - len(found.path)
		marks := make([]query.Mark, len(found.spans), allocator)
		for sp, i in found.spans {
			marks[i] = {u32(sp.from - dropped), u32(sp.to - dropped)}
		}
		append(
			&hits,
			query.Hit {
				node = h.node,
				parent = n.parent,
				path = found.path,
				name_at = u32(found.name_at - dropped),
				marks = marks,
				bytes = directory ? survey.total(&s.roll, h.node) : n.disk,
				directory = directory,
			},
		)
	}
	r.hits = hits[:]
	return r, true
}

// find_stop frees every search and pass, for a host whose workers have stopped.
find_stop :: proc(d: ^Desk) {
	for p in d.passes {
		search.pass_free(p)
	}
	delete(d.passes)
	for _, f in d.findings {
		find_free(f)
	}
	delete(d.findings)
	free(d.scratch)
}
