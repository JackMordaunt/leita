/*
Package app is sonar's host: the pipeline that joins the window to a scan, and the
threads it runs on. It takes a frame loop's needs and commands through data_host
and answers through the inbox; it never imports the view, so app_test.odin drives
it with a ui.Probe and no window.

The threads, and what crosses between them:

	main      ui/shell's loop: input in, scene out. After each frame the frame's
	          needs and commands go to the pipeline through ports; answers come
	          back through an Inbox, and wake runs a frame.
	desk      the one thread that owns a scan's derived state. The pipeline's desk
	          stage is pinned to it (stream.pin), so the totals have a single
	          writer, as the command line's builder does: ancestors are shared
	          between readers, and charging them from several threads would need
	          atomics on every total.
	reader    survey.fill_run, filling the tree. It knows nothing of the window.
	pool      stream.run on one thread: the ports, the clock and the merge.

The graph:

	needs ────┐
	commands ─┼─ merge ─ desk ─▶ inbox
	clock ────┘

A need is answered the moment it appears, from whatever the scan holds then, and
stays live until the frame stops asking. Each tick of the clock charges what the
reader has settled since the last and answers every live need again, so a
directory's listing fills in and reorders as the scan reaches into it. Once a scan
is over the clock still ticks, but nothing moves, so nothing is sent.
*/
package sonar_app

import "base:runtime"

import "core:encoding/cbor"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "jm:stream"
import "jm:ui"

import "../../ntfs"
import "../../reclaim"
import "../../scan"
import "../../survey"
import "../../walk"
import "../command"
import "../files"
import "../history"
import "../query"

// TICK is how often a running scan is folded and its answers sent: often enough
// to look live. Each tick ranks the whole tree for the largest files, which is why
// it is not every frame.
TICK :: 100 * time.Millisecond

// WRITERS is how many reader threads may write the tree at once.
WRITERS :: 8

// Query is every need the host answers.
Query :: union {
	query.Progress,
	query.Listing,
	query.Largest,
	query.Rings,
	query.Reclaim,
	query.History,
}

// Need_Event is a need appearing or going, as the main thread hands it on.
Need_Event :: struct {
	added: bool,
	key:   ui.Need_Key,
	q:     Query,
}

Tick :: struct {}

// Desk_In is everything the desk stage takes.
Desk_In :: union {
	Need_Event,
	command.Command,
	Tick,
}

// Scan is one run of a reader and everything derived from it. It is heap
// allocated because the reader thread holds pointers into it.
Scan :: struct {
	path:                  string,
	engine:                scan.Engine,
	slow:                  bool,
	state:                 query.State,
	problem:               string,
	started:               time.Tick,
	seconds:               f64, // frozen once the scan is over
	stopped:               bool, // the window called it off
	resolved:              bool, // fill.target holds a target to destroy
	tree:                  scan.Tree,
	grown:                 bool, // tree was initialised
	fill:                  survey.Fill,
	roll:                  survey.Rollup,
	reader:                ^thread.Thread,
	names:                 [dynamic]string, // new names given by a rename, which the tree borrows
	// The filesystem the target is on, as of the last measure.
	disk_total, disk_free: u64,
}

// Desk is the stage pinned to the desk thread: the current scan and every live
// need, so each tick can answer them all again.
Desk :: struct {
	inbox:       ^ui.Inbox,
	wake:        proc(),
	generation:  u32,
	scan:        ^Scan,
	live:        map[ui.Need_Key]Query,
	notice:      query.Notice, // its text owned
	// What Reclaim last offered, by node: Clean deletes only these.
	reclaimable: map[u32]reclaim.Category,
	// The scans kept (history.odin), nil when none are; the snapshot this scan
	// was kept as, the one it is compared with, and what each node held in that.
	history:     ^history.Store,
	snapshot:    i64,
	compared:    query.Snapshot,
	was:         map[u32]u64,
}

Host :: struct {
	p:         ^stream.Pipeline,
	cmd_port:  stream.Port(command.Command),
	need_port: stream.Port(Need_Event),
	inbox:     ui.Inbox,
	desk:      Desk,
	pool:      ^thread.Thread,
	// The desk thread: woken by the pipeline when the pinned stage has work.
	desk_wake: sync.Sema,
	stopping:  bool, // atomic
	desk_main: ^thread.Thread,
}

/*
Build the pipeline and start the threads, then scan path if it is not empty.

wake is called, from the desk thread, whenever an answer has been put in the inbox:
a frame loop runs a frame on it.
*/
init :: proc(h: ^Host, path: string, wake: proc() = nil, kept := "") {
	allocator := context.allocator
	ui.inbox_init(&h.inbox, allocator)
	h.desk = {
		inbox = &h.inbox,
		wake  = wake,
		live  = make(map[ui.Need_Key]Query, allocator),
	}
	history_open(&h.desk, kept)

	p := stream.make_pipeline(allocator, cap = 64)
	h.p = p
	p.wake = desk_wake
	p.wake_data = h

	commands: stream.Stream(command.Command)
	commands, h.cmd_port = stream.port(p, command.Command, name = "commands")
	needs: stream.Stream(Need_Event)
	needs, h.need_port = stream.port(p, Need_Event, name = "needs")
	clock := stream.interval(p, TICK, name = "clock")

	desk_in := stream.merge(
		[]stream.Stream(Desk_In) {
			stream.transform(needs, need_in),
			stream.transform(commands, command_in),
			stream.transform(clock, tick_in),
		},
		name = "desk in",
	)
	desk := stream.for_each_with(desk_in, &h.desk, desk_step, name = "desk")
	stream.pin(p, desk)

	if path != "" {
		stream.port_send(h.cmd_port, command.Command(command.Scan{path = command.text_make(path)}))
	}

	h.desk_main = thread.create_and_start_with_poly_data(h, desk_main, init_context = context)
	h.pool = thread.create_and_start_with_poly_data(h, pool_main, init_context = context)
}

// data_host is what the frame loop takes: the callbacks and the inbox.
data_host :: proc(h: ^Host) -> ui.Data_Host {
	return {user = h, on_need = on_need, on_command = on_command, inbox = &h.inbox}
}

// stop ends the threads in the order they depend on each other, calls off the
// scan and frees everything.
stop :: proc(h: ^Host) {
	stream.stop(h.p)
	thread.join(h.pool)
	thread.destroy(h.pool)
	sync.atomic_store(&h.stopping, true)
	sync.sema_post(&h.desk_wake)
	thread.join(h.desk_main)
	thread.destroy(h.desk_main)
	scan_end(&h.desk)
	stream.destroy(h.p)
	delete(h.desk.live)
	delete(h.desk.reclaimable)
	delete(h.desk.notice.text)
	history_close(&h.desk)
	ui.inbox_destroy(&h.inbox)
}

// --- the main thread: what the frame loop hands on -----------------------------

on_need :: proc(user: rawptr, need: ui.Need, added: bool) {
	h := (^Host)(user)
	q: Query
	switch {
	case ui.need_is(need, query.Progress):
		q = query.Progress{}
	case ui.need_is(need, query.Listing):
		q, _ = ui.need_as(need, query.Listing)
	case ui.need_is(need, query.Largest):
		q, _ = ui.need_as(need, query.Largest)
	case ui.need_is(need, query.Reclaim):
		q, _ = ui.need_as(need, query.Reclaim)
	case ui.need_is(need, query.Rings):
		q, _ = ui.need_as(need, query.Rings)
	case ui.need_is(need, query.History):
		q, _ = ui.need_as(need, query.History)
	case:
		return
	}
	stream.port_send(h.need_port, Need_Event{added, need.key, q})
}

// on_command decodes the window's command. A Command holds no pointers, so the
// decoded value is whole and crosses the port by copy.
on_command :: proc(user: rawptr, c: ui.Command) {
	h := (^Host)(user)
	if cmd, ok := ui.command_as(c, command.Command); ok {
		stream.port_send(h.cmd_port, cmd)
	}
}

// --- the threads ---------------------------------------------------------------

@(private)
pool_main :: proc(h: ^Host) {
	defer release_temp()
	stream.run(h.p, 1)
}

@(private)
desk_wake :: proc(data: rawptr) {
	sync.sema_post(&(^Host)(data).desk_wake)
}

@(private)
desk_main :: proc(h: ^Host) {
	defer release_temp()
	for {
		sync.sema_wait(&h.desk_wake)
		if sync.atomic_load(&h.stopping) {
			return
		}
		stream.drain_pinned(h.p)
		free_all(context.temp_allocator)
	}
}

@(private)
reader_main :: proc(f: ^survey.Fill) {
	defer release_temp()
	survey.fill_run(f)
}

// release_temp frees the temp allocator a thread started with init_context was
// given: core:thread leaves that to the thread (_maybe_destroy_default_temp_allocator
// in core/thread/thread.odin returns early when a context was passed), and
// LeakSanitizer reported it outliving the desk and reader threads.
@(private)
release_temp :: proc() {
	if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}
}

// --- the pipeline's stages -----------------------------------------------------

need_in :: proc(e: Need_Event) -> Desk_In {
	return e
}

command_in :: proc(c: command.Command) -> Desk_In {
	return c
}

tick_in :: proc(_: time.Duration) -> Desk_In {
	return Tick{}
}

// desk_step is the desk: one need, command or tick at a time, on the desk thread.
desk_step :: proc(d: ^Desk, v: Desk_In) {
	v := v
	switch &e in v {
	case Need_Event:
		if !e.added {
			delete_key(&d.live, e.key)
			return
		}
		d.live[e.key] = e.q
		answer(d, e.key, e.q)
		notify(d)
	case command.Command:
		switch &c in e {
		case command.Scan:
			scan_end(d)
			scan_begin(d, command.text_of(&c.path))
			answer_all(d)
		case command.Stop:
			if s := d.scan; s != nil && s.state == .Scanning {
				s.stopped = true
				scan.cancel(&s.tree)
			}
		case command.Baseline:
			if c.generation == d.generation {
				compare(d, c.snapshot)
				answer_all(d)
			}
		case command.Locate, command.Trash, command.Rename, command.Clean, command.Empty_Trash:
			act(d, &e)
			if d.scan != nil {
				measure(d.scan)
			}
			answer_all(d)
		}
	case Tick:
		if advance(d) {
			answer_all(d)
		}
	}
}

// --- the scan ------------------------------------------------------------------

// scan_begin starts a reader on path. A target that cannot be scanned still makes
// a scan, a failed one, so the window can say why.
scan_begin :: proc(d: ^Desk, path: string) {
	d.generation += 1
	d.snapshot, d.compared = 0, {}
	clear(&d.was)
	s := new(Scan)
	d.scan = s
	s.path = strings.clone(path)
	s.started = time.tick_now()
	s.state = .Failed

	target, choice, err := scan.resolve(path)
	if err != nil {
		s.problem = fmt.aprintf("cannot scan %s: %v", path, err)
		return
	}
	s.resolved = true
	s.fill.target = target
	s.engine = choice.engine
	s.slow = choice.permission_would_help
	if choice.engine == .None {
		s.problem = strings.clone("nothing here can be scanned")
		return
	}
	if tree_err := scan.tree_init(&s.tree, WRITERS); tree_err != nil {
		s.problem = fmt.aprintf("%v", tree_err)
		return
	}
	s.grown = true
	s.roll.linked = true
	s.fill.engine = choice.engine
	s.fill.opts = ntfs.Read_Options{}
	s.fill.wcfg = walk.Config{}
	s.fill.watched = true
	s.fill.tree = &s.tree
	sync.atomic_store(&s.fill.scanning, true)

	s.reader = thread.create_and_start_with_poly_data(&s.fill, reader_main, init_context = context)
	if s.reader == nil {
		sync.atomic_store(&s.fill.scanning, false)
		s.problem = strings.clone("could not start the reader")
		return
	}
	s.state = .Scanning
	measure(s)
}

// measure asks the platform how big the target's filesystem is and how much of it
// is free. Only a mounted target has one to ask about: a raw device or an image
// would answer for whatever filesystem holds the device node or the file.
measure :: proc(s: ^Scan) {
	if !s.resolved || s.fill.target.mount == "" {
		return
	}
	where_ := scan.location(s.fill.target, context.temp_allocator)
	if total, free, ok := files.space(where_); ok {
		s.disk_total, s.disk_free = total, free
	}
}

// scan_end calls off the current scan, waits for its reader and frees it.
scan_end :: proc(d: ^Desk) {
	s := d.scan
	if s == nil {
		return
	}
	d.scan = nil
	if s.reader != nil {
		if s.grown {
			scan.cancel(&s.tree)
		}
		thread.join(s.reader)
		thread.destroy(s.reader)
	}
	survey.rollup_destroy(&s.roll)
	survey.fill_destroy(&s.fill)
	if s.grown {
		scan.tree_destroy(&s.tree)
	}
	if s.resolved {
		scan.target_destroy(&s.fill.target)
	}
	for n in s.names {
		delete(n)
	}
	delete(s.names)
	delete(s.path)
	delete(s.problem)
	free(s)
}

/*
Charge what the reader has settled since the last tick, and say whether there is
anything new to answer with. Called with the scan over, it does nothing.

Whether the reader has finished is read before the pass, as the command line's
builder does: if it finishes in between, this pass still sees everything and the
next tick takes one more turn rather than missing the last of it.
*/
advance :: proc(d: ^Desk) -> bool {
	s := d.scan
	if s == nil || s.state != .Scanning {
		return false
	}
	finished := !bool(sync.atomic_load(&s.fill.scanning))
	if scan.taken_restated(&s.tree) {
		survey.rollup_restate(&s.roll)
	}
	survey.rollup_advance(&s.roll, &s.tree)
	s.seconds = time.duration_seconds(time.tick_since(s.started))
	if finished {
		thread.join(s.reader)
		thread.destroy(s.reader)
		s.reader = nil
		switch {
		case s.stopped:
			s.state = .Stopped
		case:
			s.problem = survey.problem(&s.fill, context.allocator)
			s.state = s.problem == "" ? .Done : .Failed
		}
		measure(s)
		if s.state == .Done {
			keep(d)
		}
	}
	return true
}

// --- answers -------------------------------------------------------------------

answer_all :: proc(d: ^Desk) {
	for key, q in d.live {
		answer(d, key, q)
	}
	notify(d)
}

answer :: proc(d: ^Desk, key: ui.Need_Key, q: Query) {
	switch q in q {
	case query.Progress:
		put(d, key, progress(d))
	case query.Listing:
		put(d, key, listing(d, q))
	case query.Largest:
		put(d, key, largest(d, q))
	case query.Reclaim:
		put(d, key, reclaim_answer(d, q))
	case query.Rings:
		put(d, key, rings(d, q))
	case query.History:
		put(d, key, history_answer(d, q))
	}
}

put :: proc(d: ^Desk, key: ui.Need_Key, v: $T) {
	bytes, err := cbor.marshal_into_bytes(
		v,
		allocator = context.temp_allocator,
		temp_allocator = context.temp_allocator,
	)
	if err == nil {
		ui.inbox_put(d.inbox, key, bytes)
	}
}

notify :: proc(d: ^Desk) {
	if d.wake != nil {
		d.wake()
	}
}

progress :: proc(d: ^Desk) -> query.Progress_Result {
	r := query.Progress_Result {
		generation = d.generation,
	}
	s := d.scan
	if s == nil {
		return r
	}
	r.notice = d.notice
	r.disk_total = s.disk_total
	r.disk_free = s.disk_free
	r.state = s.state
	r.target = s.path
	r.slow = s.slow
	r.problem = s.problem
	r.seconds = s.seconds
	r.pending = s.roll.pending
	switch s.engine {
	case .Mft:
		r.engine = "MFT"
	case .Walk:
		r.engine = "walk"
	case .None:
	}
	if s.grown {
		r.nodes = sync.atomic_load(&s.tree.nodes_done)
		r.bytes = sync.atomic_load(&s.tree.bytes_done)
	}
	return r
}

// root is the top of the scan, once the reader has written it.
root :: proc(s: ^Scan) -> (u32, bool) {
	if !s.grown {
		return 0, false
	}
	i := sync.atomic_load(&s.tree.root)
	if i >= u32(len(s.roll.totals)) || .Used not_in scan.node_flags(scan.node(&s.tree, i)) {
		return 0, false
	}
	return i, true
}

listing :: proc(d: ^Desk, q: query.Listing) -> query.Listing_Result {
	r := query.Listing_Result {
		generation = d.generation,
		dir        = q.dir,
	}
	s := d.scan
	if s == nil || q.generation != d.generation {
		return r
	}
	top, ok := root(s)
	if !ok {
		return r
	}
	dir := q.dir == query.ROOT ? top : q.dir
	if dir >= u32(len(s.roll.totals)) {
		return r
	}
	r.dir = dir
	r.bytes = s.roll.totals[dir]
	r.was = was_of(d, dir)
	r.compared = d.compared.id != 0
	r.crumbs = crumbs(s, dir, top)

	entries := sorted_children(d, dir)
	shown := min(len(entries), query.LISTING_LIMIT)
	r.entries = entries[:shown]
	r.more = len(entries) - shown
	for e in entries[shown:] {
		r.more_bytes += e.bytes
	}
	return r
}

// sorted_children is what dir holds so far, largest first, in the temp allocator.
sorted_children :: proc(d: ^Desk, dir: u32) -> []query.Entry {
	s := d.scan
	entries := make([dynamic]query.Entry, context.temp_allocator)
	it := survey.children(&s.roll, dir)
	for c in survey.next_child(&it) {
		n := scan.node(&s.tree, c)
		directory := .Directory in scan.node_flags(n)
		append(
			&entries,
			query.Entry {
				node = c,
				name = n.name,
				bytes = directory ? s.roll.totals[c] : n.disk,
				directory = directory,
				was = was_of(d, c),
			},
		)
	}
	slice.sort_by(entries[:], proc(a, b: query.Entry) -> bool {
		if a.bytes != b.bytes {
			return a.bytes > b.bytes
		}
		return a.name < b.name
	})
	return entries[:]
}

rings :: proc(d: ^Desk, q: query.Rings) -> query.Rings_Result {
	r := query.Rings_Result {
		generation = d.generation,
		dir        = q.dir,
	}
	s := d.scan
	if s == nil || q.generation != d.generation {
		return r
	}
	top, ok := root(s)
	if !ok {
		return r
	}
	dir := q.dir == query.ROOT ? top : q.dir
	if dir >= u32(len(s.roll.totals)) {
		return r
	}
	r.dir = dir
	r.bytes = s.roll.totals[dir]
	r.was = was_of(d, dir)
	r.compared = d.compared.id != 0
	r.crumbs = crumbs(s, dir, top)
	arcs := make([dynamic]query.Arc, context.temp_allocator)
	if r.bytes > 0 {
		lay_ring(d, &arcs, dir, r.bytes, 1, 0, 0, 1)
	}
	r.arcs = arcs[:]
	return r
}

/*
lay_ring lays dir's contents into ring depth, between start and start + sweep,
each in proportion to its share of total, and recurses into each directory big
enough to see. Contents come largest first, so the first too narrow to draw ends
the ring: everything after it is narrower still.
*/
lay_ring :: proc(
	d: ^Desk,
	arcs: ^[dynamic]query.Arc,
	dir: u32,
	total: u64,
	depth: u8,
	branch: u8,
	start, sweep: f32,
	up: i32 = -1,
) {
	at := start
	for e, i in sorted_children(d, dir) {
		if len(arcs) >= query.MAX_ARCS {
			return
		}
		w := sweep * f32(f64(e.bytes) / f64(total))
		if w < query.MIN_SWEEP {
			return
		}
		b := depth == 1 ? u8(min(i, 255)) : branch
		append(
			arcs,
			query.Arc {
				node = e.node,
				name = e.name,
				bytes = e.bytes,
				directory = e.directory,
				depth = depth,
				branch = b,
				start = at,
				sweep = w,
				up = up,
				was = e.was,
			},
		)
		if e.directory && depth < query.RING_DEPTH {
			lay_ring(d, arcs, e.node, e.bytes, depth + 1, b, at, w, i32(len(arcs) - 1))
		}
		at += w
	}
}

// ancestors are the directories node lies in, nearest first, up to the top of the
// scan; at most 64, the depth scan.path follows a chain to.
ancestors :: proc(s: ^Scan, node: u32, allocator := context.temp_allocator) -> []u32 {
	out := make([dynamic]u32, allocator)
	cur := node
	for len(out) < 64 {
		n := scan.node(&s.tree, cur)
		if n.parent == cur || n.parent >= u32(len(s.roll.totals)) {
			break
		}
		cur = n.parent
		append(&out, cur)
	}
	return out[:]
}

// crumbs is the way from the top of the scan down to dir. A chain that never
// reaches top, an orphan's, starts where it ends.
crumbs :: proc(s: ^Scan, dir, top: u32) -> []query.Crumb {
	chain: [64]u32
	depth := 0
	cur := dir
	for depth < len(chain) {
		chain[depth] = cur
		depth += 1
		n := scan.node(&s.tree, cur)
		if cur == top || n.parent == cur || n.parent >= u32(len(s.roll.totals)) {
			break
		}
		cur = n.parent
	}
	out := make([]query.Crumb, depth, context.temp_allocator)
	for i in 0 ..< depth {
		c := chain[depth - 1 - i]
		out[i] = {c, scan.node(&s.tree, c).name}
	}
	return out
}

// largest ranks every settled file. The paths are the answer, so they are made in
// allocator and live until it is sent.
largest :: proc(
	d: ^Desk,
	q: query.Largest,
	allocator := context.temp_allocator,
) -> query.Largest_Result {
	s := d.scan
	if s == nil || q.generation != d.generation || !s.grown {
		return {}
	}
	top: [query.LARGEST_LIMIT]query.File
	count := 0
	for i in 0 ..< u32(len(s.roll.totals)) {
		n := scan.node(&s.tree, i)
		f := scan.node_flags(n)
		if .Used not_in f || .Settled not_in f || .Directory in f || .Extra_Name in f {
			continue
		}
		if n.disk == 0 || (count == len(top) && n.disk <= top[count - 1].bytes) {
			continue
		}
		if survey.removed(&s.roll, &s.tree, i) {
			continue
		}
		at := min(count, len(top) - 1)
		for at > 0 && top[at - 1].bytes < n.disk {
			top[at] = top[at - 1]
			at -= 1
		}
		top[at] = {
			node   = i,
			parent = n.parent,
			bytes  = n.disk,
		}
		count = min(count + 1, len(top))
	}
	files := make([]query.File, count, allocator)
	for i in 0 ..< count {
		files[i] = top[i]
		files[i].path = scan.path(&s.tree, top[i].node, allocator)
		files[i].within = ancestors(s, top[i].node, allocator)
		files[i].was = was_of(d, top[i].node)
	}
	return {files = files, compared = d.compared.id != 0}
}
