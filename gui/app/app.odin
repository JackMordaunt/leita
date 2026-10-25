/*
Package app is leita's host: the pipeline that joins the window to a scan, and the
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
	workers   stream.Workers: each search's passes, cut into chunks, and the
	          thumbnails (search.odin, thumbs.odin). A search reads the tree as
	          the reader fills it and never the totals, which are the desk's.

The graph:

	needs ────┐
	commands ─┤
	clock ────┼─ merge ─ desk ─▶ inbox
	searched ─┘   (passes back from the workers)

	thumbs ─ debounce_by ─ async_map (workers) ─ deliver ─▶ inbox

A need is answered the moment it appears, from whatever the scan holds then, and
stays live until the frame stops asking. Each tick of the clock charges what the
reader has settled since the last and answers every live need again, so a
directory's listing fills in and reorders as the scan reaches into it. Once a scan
is over the clock still ticks. An opted-in release check is the one other thing
a tick may start, and it never installs.
*/
package leita_app

import "base:runtime"

import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "jm:http"
import "jm:stream"
import "jm:ui"

import "../../history"
import "../../licence"
import "../../ntfs"
import "../../reclaim"
import "../../scan"
import "../../schedule"
import "../../search"
import "../../settings"
import "../../survey"
import "../../synth"
import "../../update"
import "../../walk"
import "../command"
import "../files"
import "../msg"
import "../query"

// TICK is how often a running scan is folded and its answers sent: often enough
// to look live. Each tick ranks the whole tree for the largest files, which is why
// it is not every frame.
TICK :: 100 * time.Millisecond

// Query is every need the host answers.
Query :: union {
	query.Progress,
	query.Listing,
	query.Largest,
	query.Rings,
	query.Reclaim,
	query.History,
	query.Record,
	query.Licence,
	query.Settings,
	query.Search,
	query.Monitor,
	query.Update,
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
	Activated,
	Updated,
	Finished_Pass,
	Open_Failure,
	Recorder_Change,
	Test_Done,
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
	begun:                 time.Time, // started, as a date
	seconds:               f64, // frozen once the scan is over
	stopped:               bool, // the window called it off
	resolved:              bool, // fill.target holds a target to destroy
	tree:                  scan.Tree,
	grown:                 bool, // tree was initialised
	fill:                  survey.Fill,
	baseline:              string, // the fill's, owned: where the place's tree is kept
	roll:                  survey.Rollup,
	reader:                ^thread.Thread,
	// The directories the walk left incomplete, built once the scan is over, and
	// whether it has been (incomplete).
	incomplete_dirs:       map[u32]struct{},
	incomplete_built:      bool,
	// The filesystem the target is on, as of the last measure.
	disk_total, disk_free: u64,
}

// Desk is the stage pinned to the desk thread: the current scan and every live
// need, so each tick can answer them all again.
Desk :: struct {
	inbox:               ^ui.Inbox,
	wake:                proc(),
	generation:          u32,
	scan:                ^Scan,
	made_up:             Maybe(int), // the made-up disk's day to scan in place of any path, nil for real ones
	live:                map[ui.Need_Key]Query,
	notice:              query.Notice, // its text owned
	words:               ^msg.Strings, // what the host says, in the window's language (words.odin)
	// What Reclaim last offered, by node: Clean deletes only these.
	reclaimable:         map[u32]reclaim.Category,
	// Recycle Bin paths Reclaim last offered, by node: Empty Trash asks the
	// shell, never delete_tree. A node not in the scan tree is recycle_bin_node.
	recycle_paths:       map[u32]string,
	// The scans kept (history.odin), nil when none are, and the path of the store
	// opened, whose folder holds each place's baseline; the snapshot this scan was
	// kept as, the one it is compared with, and what each node held in that.
	history:             ^history.Store,
	history_path:        string,
	snapshot:            i64,
	compared:            query.Snapshot,
	was:                 map[u32]u64,
	// What the person chose, kept between runs (settings.odin); nil when not.
	settings:            ^settings.Store,
	// Where reports are exported to when the window names no file, and where
	// its save dialog opens: files.reports_folder unless init was given one, ""
	// for neither; and each one saved, by the notice that said so (export.odin).
	reports:             string,
	saved:               map[u32]string,
	// A report is being written, for Progress to say so while the desk is busy.
	exporting:           bool,
	// The licence in use (licence.odin), where it is kept, the key it is checked
	// against, and how the last one the window offered went. renew_key is a
	// receipt key to exchange once the answer port exists. receipt_pending is
	// the key of the exchange under way. refreshing is that automatic exchange,
	// as against one the window asked for. licence_renewal is why it failed.
	licence:             licence.Licence,
	licensed:            bool,
	licence_path:        string,
	licence_key:         []byte, // the caller's, or nil for the keys built in
	licence_offered:     u32,
	licence_problem:     string,
	licence_renewal:     string,
	renew_key:           string,
	receipt_pending:     string,
	refreshing:          bool,
	// Exchanging a key for its licence: the client, started on the first key,
	// where it sends to, the port its answer comes back through, and whether one
	// is under way.
	client:              ^http.Client,
	activate_url:        string,
	activations:         ^stream.Port(Activated),
	activating:          bool,
	// Updates (update.odin): the release to ask, "" for update's own; the
	// last check or update, and what it found; the thread one is on, and the
	// port it answers through.
	update_base:         string,
	update_state:        query.Update_State,
	update_result:       update.Result,
	update_can_apply:    bool,
	update_thread:       ^thread.Thread,
	updates:             ^stream.Port(Updated),
	// update_key is the throwaway Ed25519 public key a test signs its fixture
	// with. Empty means the key compiled into the build, which a debug build
	// does not have.
	update_key:          [32]byte,
	update_key_set:      bool,
	// update_exe is the executable a test asks the check to classify. "" is
	// this process.
	update_exe:          string,
	// The opted-in schedule (update_schedule.odin). update_time is a test
	// clock, nil for the real one. update_checked is the shared Unix seconds
	// of the last automatic check. update_dismissed is the version whose
	// notice was closed, owned. The counts are how many automatic and manual
	// checks this window started.
	update_time:         ^Update_Time,
	update_opened_set:   bool,
	update_opened_mono:  i64,
	update_startup_done: bool,
	update_checked:      i64,
	update_has_mono:     bool,
	update_last_mono:    i64,
	update_dismissed:    string,
	update_auto_count:   int,
	update_manual_count: int,
	// update_save_failed is set when this session could not write the
	// automatic-check choice. Checks stay off until the process ends. The
	// stored choice is what the next launch reads.
	update_save_failed:  bool,
	// When leita first ran here, the start of the evaluation (licence.first_use).
	first_use:           time.Time,
	// Searching (search.odin): each live Search need's finding, each pass out
	// on the workers by the finding it is for (nil once halted), the workers,
	// the port passes come back through, and what describing a hit works in.
	findings:            map[ui.Need_Key]^Finding,
	passes:              map[^search.Pass]^Finding,
	workers:             ^stream.Workers,
	searched:            ^stream.Port(Finished_Pass),
	open_failures:       ^stream.Port(Open_Failure), // act.odin's open_entry
	opening:             ^sync.Wait_Group, // the entries open_entry is opening
	recordings:          ^stream.Port(Recorder_Change), // recorder_linux.odin's set_recording
	recording:           ^sync.Wait_Group, // the change it is running, if any
	scratch:             ^search.Scratch,
	tested:              ^stream.Port(Test_Done), // webhook.odin's test_webhook
	testing_wg:          ^sync.Wait_Group, // the tests test_webhook is sending
	monitoring:          Monitoring, // monitor.odin
}

Host :: struct {
	p:             ^stream.Pipeline,
	cmd_port:      stream.Port(command.Command),
	need_port:     stream.Port(Need_Event),
	act_port:      stream.Port(Activated),
	update_port:   stream.Port(Updated),
	searched:      stream.Port(Finished_Pass),
	open_failures: stream.Port(Open_Failure),
	opening:       sync.Wait_Group,
	recordings:    stream.Port(Recorder_Change),
	recording:     sync.Wait_Group,
	tested:        stream.Port(Test_Done),
	testing:       sync.Wait_Group,
	thumbs:        Thumbs, // thumbs.odin
	workers:       ^stream.Workers,
	inbox:         ui.Inbox,
	desk:          Desk,
	pool:          ^thread.Thread,
	// The desk thread: woken by the pipeline when the pinned stage has work.
	desk_wake:     sync.Sema,
	stopping:      bool, // atomic
	desk_main:     ^thread.Thread,
}

/*
Build the pipeline and start the threads, then scan path if it is not empty.

wake is called, from the desk thread, whenever an answer has been put in the inbox:
a frame loop runs a frame on it. kept is the history store's path, "" for none;
reports the folder reports are exported to, "" for the user's Documents. The
licence is kept beside the history store and checked against licence_key, nil
for the keys leita was built with. A licence key is exchanged for its licence at
activate_url, "" for LEITA_ACTIVATE_URL or else ACTIVATE_URL. Monitoring is
handed to scheduler running monitor_argv, nil for the system's scheduler running
this binary (monitor.odin). update_key is 32 bytes of a fixture's Ed25519
public key; nil uses the key the build was given. update_exe is that fixture's
executable; "" is this process. made_up is the day of a made-up disk to scan in
place of every path, as scan.synthetic_day read it at startup, nil for real
scans. allocator builds the desk.
*/
init :: proc(
	h: ^Host,
	path: string,
	wake: proc() = nil,
	kept := "",
	reports := "",
	licence_key: []byte = nil,
	activate_url := "",
	release_base := "",
	thumbs := "",
	scheduler: ^schedule.Host = nil,
	monitor_argv: []string = nil,
	update_key: []byte = nil,
	update_exe := "",
	update_time: ^Update_Time = nil,
	made_up: Maybe(int) = nil,
	allocator := context.allocator,
) {
	ui.inbox_init(&h.inbox, allocator)
	h.workers = stream.workers_start(worker_count(), allocator)
	h.desk = {
		inbox         = &h.inbox,
		wake          = wake,
		made_up       = made_up,
		live          = make(map[ui.Need_Key]Query, allocator),
		words         = new(msg.Strings, allocator),
		reports       = strings.clone(reports, allocator) if reports != "" else files.reports_folder(allocator),
		findings      = make(map[ui.Need_Key]^Finding, allocator),
		passes        = make(map[^search.Pass]^Finding, allocator),
		workers       = h.workers,
		searched      = &h.searched,
		open_failures = &h.open_failures,
		opening       = &h.opening,
		recordings    = &h.recordings,
		recording     = &h.recording,
		tested        = &h.tested,
		testing_wg    = &h.testing,
		scratch       = new(search.Scratch, allocator),
	}
	if len(update_key) == 32 {
		copy(h.desk.update_key[:], update_key)
		h.desk.update_key_set = true
	}
	h.desk.update_exe = update_exe
	h.desk.update_time = update_time
	msg.init(h.desk.words, .English)
	history_open(&h.desk, kept)
	settings_open(&h.desk, licence.path_beside(kept, context.temp_allocator, settings.FILE))
	licence_open(
		&h.desk,
		licence.path_beside(kept, context.temp_allocator),
		licence_key,
		activate_url,
	)
	update_open(&h.desk, release_base)
	monitor_open(&h.desk, kept, scheduler, monitor_argv)

	p := stream.make_pipeline(allocator, cap = 64)
	h.p = p
	p.wake = desk_wake
	p.wake_data = h

	commands: stream.Stream(command.Command)
	commands, h.cmd_port = stream.port(p, command.Command, name = "commands")
	needs: stream.Stream(Need_Event)
	needs, h.need_port = stream.port(p, Need_Event, name = "needs")
	clock := stream.interval(p, TICK, name = "clock")
	activations: stream.Stream(Activated)
	activations, h.act_port = stream.port(p, Activated, name = "activations")
	h.desk.activations = &h.act_port
	licence_refresh_pending(&h.desk)
	updates: stream.Stream(Updated)
	updates, h.update_port = stream.port(p, Updated, name = "updates")
	h.desk.updates = &h.update_port
	searched: stream.Stream(Finished_Pass)
	searched, h.searched = stream.port(p, Finished_Pass, cap = 256, name = "searched")
	open_failures: stream.Stream(Open_Failure)
	open_failures, h.open_failures = stream.port(p, Open_Failure, cap = 16, name = "open failures")
	recordings: stream.Stream(Recorder_Change)
	recordings, h.recordings = stream.port(p, Recorder_Change, cap = 4, name = "recorder changes")
	tested: stream.Stream(Test_Done)
	tested, h.tested = stream.port(p, Test_Done, cap = 4, name = "tested")
	thumbs_init(h, thumbs)

	desk_in := stream.merge(
		[]stream.Stream(Desk_In) {
			stream.transform(needs, need_in),
			stream.transform(commands, command_in),
			stream.transform(clock, tick_in),
			stream.transform(activations, activated_in),
			stream.transform(updates, updated_in),
			stream.transform(searched, finished_in),
			stream.transform(open_failures, open_failure_in),
			stream.transform(recordings, recorder_change_in),
			stream.transform(tested, test_done_in),
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
	licence_stop(&h.desk)
	// An update may finish while the desk is stopping. Close its inbox so
	// the worker cannot wait for a desk that has stopped draining it.
	stream.port_close(h.update_port)
	thumbs_cancel(h)
	stream.stop(h.p)
	thread.join(h.pool)
	thread.destroy(h.pool)
	sync.atomic_store(&h.stopping, true)
	sync.sema_post(&h.desk_wake)
	thread.join(h.desk_main)
	thread.destroy(h.desk_main)
	// Only the desk reaps completed jobs while it runs. Once it is gone,
	// a still-running update is this thread's to join and destroy.
	update_stop(&h.desk)
	// The desk is gone, so its passes are this thread's to halt, before the
	// workers stop and the tree they read goes.
	find_halt(&h.desk)
	stream.port_close(h.searched)
	stream.port_close(h.open_failures)
	stream.port_close(h.recordings)
	stream.port_close(h.tested)
	// An entry still being opened says a failure through the port, which
	// refuses it now but lives until the pipeline goes.
	sync.wait_group_wait(&h.opening)
	sync.wait_group_wait(&h.recording)
	sync.wait_group_wait(&h.testing)
	stream.workers_stop(h.workers)
	find_stop(&h.desk)
	thumbs_destroy(h)
	scan_end(&h.desk)
	stream.destroy(h.p)
	delete(h.desk.live)
	delete(h.desk.reclaimable)
	for _, path in h.desk.recycle_paths {
		delete(path)
	}
	delete(h.desk.recycle_paths)
	delete(h.desk.notice.text)
	free(h.desk.words)
	delete(h.desk.reports)
	for _, path in h.desk.saved {
		delete(path)
	}
	delete(h.desk.saved)
	history_close(&h.desk)
	settings_close(&h.desk)
	licence_close(&h.desk)
	update_close(&h.desk)
	monitor_close(&h.desk)
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
	case ui.need_is(need, query.Record):
		q = query.Record{}
	case ui.need_is(need, query.Licence):
		q = query.Licence{}
	case ui.need_is(need, query.Settings):
		q = query.Settings{}
	case ui.need_is(need, query.Search):
		q, _ = ui.need_as(need, query.Search)
	case ui.need_is(need, query.Monitor):
		q = query.Monitor{}
	case ui.need_is(need, query.Update):
		q = query.Update{}
	case ui.need_is(need, query.Thumb):
		thumb_follow(h, need, added)
		return
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

// worker_count is how many threads search and make thumbnails: all but one of
// the machine's, so the window and the reader keep one.
@(private)
worker_count :: proc() -> int {
	return clamp(os.get_processor_core_count() - 1, 1, 32)
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

activated_in :: proc(a: Activated) -> Desk_In {
	return a
}

//review:ignore verb-for-func every desk inbound converter is named *_in (need_in, command_in, tick_in, activated_in, finished_in, open_failure_in); this one only returns the Updated
updated_in :: proc(u: Updated) -> Desk_In {
	return u
}

// desk_step is the desk: one need, command or tick at a time, on the desk thread.
desk_step :: proc(d: ^Desk, v: Desk_In) {
	v := v
	switch &e in v {
	case Need_Event:
		if !e.added {
			delete_key(&d.live, e.key)
			if _, is := e.q.(query.Search); is {
				find_close(d, e.key)
			}
			return
		}
		d.live[e.key] = e.q
		#partial switch q in e.q {
		case query.Search:
			find_open(d, e.key, q)
		case query.Monitor:
			recorder_refresh(d)
		}
		answer(d, e.key, e.q)
		notify(d)
	case command.Command:
		switch &c in e {
		case command.Scan:
			find_forget(d)
			scan_end(d)
			scan_begin(d, command.text_of(&c.path), c.path.cut)
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
		case command.Export:
			// The window hears that a report is under way before the desk
			// stops answering to write it, and that it is done after.
			d.exporting = true
			answer_all(d)
			export(d, c)
			d.exporting = false
			answer_all(d)
		case command.Reveal:
			reveal(d, c)
		case command.Add_Licence:
			add_licence(d, &c)
			answer_all(d)
		case command.Language:
			set_language(d, c)
			remember_language(d, c)
			answer_all(d)
		case command.Theme:
			remember_theme(d, c)
		case command.Monitoring:
			set_monitoring(d, c)
			answer_all(d)
		case command.Watch:
			watch(d, &c)
			answer_all(d)
		case command.Unwatch:
			unwatch(d, &c)
			answer_all(d)
		case command.Recording:
			set_recording(d, c)
			answer_all(d)
		case command.Check_Update:
			// A person asked. It does not record the automatic check, and it
			// does not install.
			sync.atomic_add(&d.update_manual_count, 1)
			if d.updates != nil {
				update_begin(d, false)
			}
			answer_all(d)
		case command.Apply_Update:
			update_apply(d)
			answer_all(d)
		case command.Automatic_Checks:
			remember_updates(d, c.on)
			answer_all(d)
		case command.Dismiss_Update:
			remember_dismiss(d, command.text_of(&c.version))
			answer_all(d)
		case command.Add_Webhook:
			add_webhook(d, &c)
			answer_all(d)
		case command.Remove_Webhook:
			remove_webhook(d, &c)
			answer_all(d)
		case command.Test_Webhook:
			test_webhook(d, &c)
			answer_all(d)
		case command.Locate,
		     command.Open,
		     command.Trash,
		     command.Rename,
		     command.Clean,
		     command.Empty_Trash:
			// A rename writes a name a search may be reading.
			_, renaming := c.(command.Rename)
			if renaming {
				find_halt(d)
			}
			act(d, &e)
			if renaming {
				find_restart(d)
			}
			if d.scan != nil {
				measure(d.scan)
			}
			answer_all(d)
		}
	case Activated:
		take_activation(d, &e)
		answer_all(d)
	case Updated:
		take_update(d, &e)
		answer_all(d)
	case Finished_Pass:
		take_pass(d, e.pass)
	case Test_Done:
		d.monitoring.testing = false
		answer_all(d)
	case Open_Failure:
		tell(d, true, .Open_Failed, command.text_of(&e.name))
		answer_all(d)
	case Recorder_Change:
		finish_recording(d, &e)
		answer_all(d)
	case Tick:
		// A check is due or not on its own. The scan moving is a separate
		// reason to answer, and neither waits on the other.
		changed := advance(d)
		if update_consider(d) {
			changed = true
		}
		if changed {
			answer_all(d)
		}
		find_tick(d)
		monitor_refresh(d)
	}
}

// --- the scan ------------------------------------------------------------------

// scan_begin starts a reader on path. A target that cannot be scanned still makes
// a scan, a failed one, so the window can say why. A path that was cut to fit its
// command is refused the same way: scanning what is left of it would read an
// ancestor, and Reclaim would offer other projects' folders as this one's.
scan_begin :: proc(d: ^Desk, path: string, cut := false) {
	d.generation += 1
	d.snapshot, d.compared = 0, {}
	clear(&d.was)
	s := new(Scan)
	d.scan = s
	s.path = strings.clone(path) if !cut else ""
	s.started = time.tick_now()
	s.begun = time.now()
	s.state = .Failed

	if cut {
		s.problem = strings.clone(say(d, .Path_Too_Long))
		return
	}

	target, choice, err := scan.resolve(path, made_up = d.made_up)
	if err != nil {
		s.problem = strings.clone(say(d, .Cannot_Scan, path, fmt.tprint(err)))
		return
	}
	s.resolved = true
	s.fill.target = target
	s.engine = choice.engine
	s.slow = choice.permission_would_help
	if choice.engine == .None {
		s.problem = strings.clone(say(d, .Nothing_To_Scan))
		return
	}
	s.fill.wcfg = walk.Config {
		media = target.media,
	}
	if tree_err := scan.tree_init(&s.tree, walk.width(s.fill.wcfg)); tree_err != nil {
		s.problem = strings.clone(fmt.tprintf("%v", tree_err))
		return
	}
	s.grown = true
	s.roll.linked = true
	s.fill.engine = choice.engine
	s.fill.probe = choice.probe
	s.fill.opts = ntfs.Read_Options{}
	s.fill.watched = true
	s.fill.tree = &s.tree
	// With history on, the place's whole tree is kept beside it, shared with the
	// command line and the monitor, and the next scan reads only what changed since.
	if d.history != nil {
		s.baseline = history.baseline_path(
			d.history_path,
			scan.location(target, context.temp_allocator),
		)
		s.fill.baseline = s.baseline
	}
	sync.atomic_store(&s.fill.scanning, true)

	s.reader = thread.create_and_start_with_poly_data(&s.fill, reader_main, init_context = context)
	if s.reader == nil {
		sync.atomic_store(&s.fill.scanning, false)
		s.problem = strings.clone(say(d, .Reader_Failed))
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
	if s.engine == .Synthetic {
		s.disk_total, s.disk_free = synth.space(s.fill.target.day)
		return
	}
	where_ := scan.location(s.fill.target, context.temp_allocator)
	if total, free, ok := scan.space(where_); ok {
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
	delete(s.path)
	delete(s.problem)
	delete(s.baseline)
	delete(s.incomplete_dirs)
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
	if s.engine == .Synthetic && synth.clock_override.elapsed != nil {
		s.seconds = time.duration_seconds(synth.clock_override.elapsed())
	}
	if finished {
		thread.join(s.reader)
		thread.destroy(s.reader)
		s.reader = nil
		// A probe may have settled on the MFT where a walk was chosen.
		s.engine = s.fill.engine
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
	case query.Record:
		put(d, key, record_answer(d))
	case query.Licence:
		put(d, key, licence_answer(d))
	case query.Settings:
		put(d, key, settings_answer(d))
	case query.Search:
		if r, ready := find_answer(d, key, q); ready {
			put(d, key, r)
		}
	case query.Monitor:
		put(d, key, monitor_answer(d))
	case query.Update:
		put(d, key, update_answer(d))
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
		exporting  = d.exporting,
		reports    = d.reports,
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
	if s.fill.baseline != "" && s.state == .Done {
		r.kept = true
		r.updated = s.fill.how == .Updated
		r.reread = s.fill.reread
		r.since = time.to_unix_seconds(s.fill.taken)
		r.why = s.fill.why
	}
	engine := s.engine
	if sync.atomic_load(&s.fill.escalated) {
		engine = .Mft
	}
	switch engine {
	case .Mft:
		r.engine = "MFT"
	case .Walk:
		r.engine = "walk"
	case .Synthetic:
		r.engine = "synthetic"
	case .None:
	}
	if s.grown {
		r.nodes = sync.atomic_load(&s.tree.nodes_done)
		r.bytes = sync.atomic_load(&s.tree.bytes_done)
		r.unread, r.denied = scan.unread(&s.tree)
	}
	r.retention_known = true
	ret := scan.retention_of(&s.tree)
	r.snapshots = u8(ret.snapshots)
	r.purge_known = ret.purgeable_known
	r.purgeable = ret.purgeable
	r.scan_order = scan.is_scan_order(&s.tree)
	r.logical_sizes = scan.is_logical(&s.tree)
	return r
}

// root is the top of the scan, once the reader has written it.
root :: proc(s: ^Scan) -> (u32, bool) {
	if !s.grown {
		return 0, false
	}
	i := sync.atomic_load(&s.tree.root)
	if i >= s.roll.seen || .Used not_in scan.node_flags(scan.node(&s.tree, i)) {
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
	if dir >= s.roll.seen {
		return r
	}
	if survey.removed(&s.roll, &s.tree, dir) {
		r.gone, r.up = true, live_above(s, dir, top)
		return r
	}
	r.dir = dir
	r.bytes = survey.total(&s.roll, dir)
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
		// A folder row shows the charged rollup. The inode's length and exact
		// reclaim are not that total, so they stay unknown on the row.
		logical: u64
		logical_known: bool
		frees: u64
		frees_known: bool
		if !directory {
			logical, logical_known, frees, frees_known = node_measures(&s.tree, c)
		}
		append(
			&entries,
			query.Entry {
				node = c,
				name = scan.name_of(&s.tree, c),
				bytes = directory ? survey.total(&s.roll, c) : n.disk,
				directory = directory,
				was = was_of(d, c),
				incomplete = directory && incomplete(s, c),
				logical = logical,
				logical_known = logical_known,
				frees = frees,
				frees_known = frees_known,
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

// node_measures is one node's length and exact reclaim. A missing fact stays
// unknown. The charged share is not copied into frees.
@(private = "file")
node_measures :: proc(t: ^scan.Tree, index: u32) -> (logical: u64, logical_known: bool, frees: u64, frees_known: bool) {
	if a, ok := scan.account_of(t, index); ok && .Logical in a.known {
		logical, logical_known = a.logical, true
	}
	if n, ok := scan.exact_frees(scan.freed_of(t, index)); ok {
		frees, frees_known = n, true
	}
	return
}

/*
incomplete says whether the walk left directory node short of what is in it, so
its total is less than it holds: it, or a directory under it, could not be opened
or listed, or the scan was stopped or failed and one under it has no entries
yet. A directory cut off in the middle of its listing is not told, and an empty
one in a scan cut short is, as nothing separates it from one never reached.
Nothing is incomplete while the scan runs, as every directory is still to come.
*/
incomplete :: proc(s: ^Scan, node: u32) -> bool {
	if s.state == .Scanning {
		return false
	}
	if !s.incomplete_built {
		build_incomplete(s)
	}
	return node in s.incomplete_dirs
}

// build_incomplete works out which directories of the finished scan s are
// incomplete: each one that was not read, and every directory above it.
@(private = "file")
build_incomplete :: proc(s: ^Scan) {
	s.incomplete_built = true
	cut := s.state == .Stopped || s.state == .Failed
	if unread, _ := scan.unread(&s.tree); !cut && unread == 0 {
		return
	}
	for i in 0 ..< s.roll.seen {
		flags := scan.node_flags(scan.node(&s.tree, i))
		if .Used not_in flags || .Directory not_in flags || .Mount in flags || .Reparse in flags {
			continue
		}
		if .Unread not_in flags {
			it := survey.children(&s.roll, i)
			if _, has := survey.next_child(&it); !cut || has {
				continue
			}
		}
		at := i
		for {
			if at in s.incomplete_dirs {
				break
			}
			s.incomplete_dirs[at] = {}
			up := scan.node(&s.tree, at).parent
			if up == at || up >= s.roll.seen {
				break
			}
			at = up
		}
	}
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
	if dir >= s.roll.seen {
		return r
	}
	if survey.removed(&s.roll, &s.tree, dir) {
		r.gone, r.up = true, live_above(s, dir, top)
		return r
	}
	r.dir = dir
	r.bytes = survey.total(&s.roll, dir)
	r.was = was_of(d, dir)
	r.compared = d.compared.id != 0
	r.crumbs = crumbs(s, dir, top)
	r.incomplete = s.state == .Stopped || s.state == .Failed || incomplete(s, dir)
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
				incomplete = e.incomplete,
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
		if n.parent == cur || n.parent >= s.roll.seen {
			break
		}
		cur = n.parent
		append(&out, cur)
	}
	return out[:]
}

// live_above is the nearest ancestor of dir the tree still holds, or query.ROOT
// for the top, which is what the window calls it: where the window goes when the
// directory it shows has been forgotten.
live_above :: proc(s: ^Scan, dir, top: u32) -> u32 {
	way := crumbs(s, dir, top)
	for i := len(way) - 2; i >= 0; i -= 1 {
		if !survey.removed(&s.roll, &s.tree, way[i].node) {
			return query.ROOT if way[i].node == top else way[i].node
		}
	}
	return query.ROOT
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
		if cur == top || n.parent == cur || n.parent >= s.roll.seen {
			break
		}
		cur = n.parent
	}
	out := make([]query.Crumb, depth, context.temp_allocator)
	for i in 0 ..< depth {
		c := chain[depth - 1 - i]
		out[i] = {c, scan.name_of(&s.tree, c)}
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
	for i in 0 ..< s.roll.seen {
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
		files[i].path = shown_path(s, scan.path(&s.tree, top[i].node, allocator), allocator)
		files[i].within = ancestors(s, top[i].node, allocator)
		files[i].was = was_of(d, top[i].node)
		files[i].logical, files[i].logical_known, files[i].frees, files[i].frees_known = node_measures(&s.tree, top[i].node)
	}
	return {files = files, compared = d.compared.id != 0}
}

/*
shown_path is path, which scan.path built in allocator, as the window shows it:
a made-up disk's is the Mac's, written with / alone (synth.mac_path), where a
Windows host joined it with \. path is freed when a new one replaces it.
*/
shown_path :: proc(s: ^Scan, path: string, allocator := context.allocator) -> string {
	if s.engine != .Synthetic {
		return path
	}
	defer delete(path, allocator)

	return synth.mac_path(path, allocator)
}
