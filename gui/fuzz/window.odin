package gui_fuzz

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../../scan"
import "../../schedule"
import "../../synth"
import "../app"
import "../command"
import "../query"
import "../view"

/*
Window is one run of the application for a case: the real host, desk and
reader on their threads, the real view in a headless probe in place of a
window, and a data folder of its own. It is journeys/gui's Window with three
differences a random sequence needs. The made-up disk is read through a gate,
so how far a scan has got is an action and not a race. Commands that reach past
the folder and the made-up disk are dropped before the host sees them (allowed).
And a frame is only looked at once the host has gone quiet (settle).
*/
Window :: struct {
	dir:      string,
	h:        app.Host,
	m:        view.Model,
	using hl: render.Headless,
	data:     ui.Data_Host, // the host's, which safe hands what it allows
	safe:     ui.Data_Host, // the probe's
	sched:    schedule.Host,
	faces:    []ops.Font_Ref,
	backs:    []ops.Font_Id,
	// What the window asked the host for and was refused here, by kind.
	dropped:  int,
}

// --- the gate --------------------------------------------------------------------

/*
Gate holds the made-up disk's reader at each directory until the case lets it
on: synth calls clock_override.wait once per directory read. allowed is how
many directories may have been read, over every scan of the case; open lets
every scan run to its end. A cancelled tree is let go at once, as synth asks.
*/
Gate :: struct {
	allowed: i64,
	used:    i64,
	open:    bool,
}

@(private)
gate: Gate

@(private)
gate_wait :: proc(tree: ^scan.Tree, _: time.Duration) {
	n := sync.atomic_add(&gate.used, 1) + 1
	for !sync.atomic_load(&gate.open) &&
	    n > sync.atomic_load(&gate.allowed) &&
	    !scan.cancelled(tree) {
		time.sleep(200 * time.Microsecond)
	}
}

// let_through lets the reader on by n more directories.
let_through :: proc(n: int) {
	sync.atomic_store(
		&gate.allowed,
		max(sync.atomic_load(&gate.allowed), sync.atomic_load(&gate.used)) + i64(n),
	)
}

// hold_at_gate stops the reader at the next directory, wherever it is.
hold_at_gate :: proc() {
	sync.atomic_store(&gate.allowed, sync.atomic_load(&gate.used))
}

// --- opening and closing -----------------------------------------------------------

// ROOT_ENV names the folder a run's cases keep their data in. The run makes it
// and removes it when it ends, so a case whose child crashed leaves nothing
// behind: the history and baseline a scan keeps there hold every entry of the
// made-up disk, 806,693 of them on day 0 (journeys/gui chart_test).
ROOT_ENV :: "LEITA_GUI_FUZZ_DIR"

// folder is a fresh data folder for one case, emptied of whatever the case
// before it, whose child may have crashed, left there. A case run on its own,
// with no run around it, keeps its data in a folder named for its process,
// which close removes.
folder :: proc(allocator := context.allocator) -> string {
	dir: string
	if root := os.get_env(ROOT_ENV, context.temp_allocator); root != "" {
		os.remove_all(root)
		_ = os.make_directory_all(root)
		dir = fmt.aprintf("%s/case", root, allocator = allocator)
	} else {
		tmp, _ := os.temp_directory(context.temp_allocator)
		dir = fmt.aprintf("%s/leita_gui_fuzz_case_%d", tmp, os.get_pid(), allocator = allocator)
		os.remove_all(dir)
	}
	_ = os.make_directory(dir)
	return dir
}

// DEAD_URL is where the licence and update clients are pointed: a loopback
// address. What keeps a case off the network is pass_allowed, which drops the
// update and webhook commands; a licence activation, which it lets through,
// goes here and no further.
DEAD_URL :: "http://127.0.0.1:9/"

/*
open starts the application on the made-up disk of day at size, dark or not,
with its reader held at the gate after first directories.
*/
open :: proc(w: ^Window, day: int, size: ops.Size, dark: bool, first: int) {
	sync.atomic_store(&gate.open, false)
	sync.atomic_store(&gate.used, 0)
	sync.atomic_store(&gate.allowed, i64(first))
	synth.clock_override = {
		wait = gate_wait,
	}

	w.dir = folder()
	w.sched = {
		run    = refuse_to_run,
		system = schedule.SYSTEM,
		units  = fmt.aprintf("%s/units", w.dir),
		agents = fmt.aprintf("%s/agents", w.dir),
		log    = fmt.aprintf("%s/monitor.log", w.dir),
		temp   = w.dir,
		uid    = "0",
		login  = "fuzz",
	}
	app.init(
		&w.h,
		synth.HOME,
		kept = fmt.tprintf("%s/history.db", w.dir),
		reports = w.dir,
		activate_url = DEAD_URL,
		release_base = DEAD_URL,
		thumbs = w.dir,
		scheduler = &w.sched,
		monitor_argv = []string{fmt.tprintf("%s/no-such-monitor", w.dir)},
		update_exe = fmt.tprintf("%s/no-such-exe", w.dir),
		made_up = day,
	)
	w.data = app.data_host(&w.h)
	w.safe = {
		user       = w,
		on_need    = pass_need,
		on_command = pass_allowed,
		inbox      = w.data.inbox,
	}
	view.model_init(&w.m, synth.HOME)
	w.m.dark = dark
	w.faces = view.fonts()
	w.backs = view.fallbacks(w.faces)
	render.headless_init(
		&w.hl,
		view.view,
		&w.m,
		size,
		w.faces,
		fallbacks = w.backs,
		data = &w.safe,
	)

	ui.probe_frame(&w.p)
}

// close stops the application and removes its data folder. The gate opens
// first, so a reader held at it is not what the stop waits on.
close :: proc(w: ^Window) {
	sync.atomic_store(&gate.open, true)
	render.headless_destroy(&w.hl)
	view.model_destroy(&w.m)
	app.stop(&w.h)
	delete(w.backs)
	delete(w.faces)
	delete(w.sched.units)
	delete(w.sched.agents)
	delete(w.sched.log)
	os.remove_all(w.dir)
	delete(w.dir)
	synth.clock_override = {}
}

@(private)
refuse_to_run :: proc(argv: []string, _: rawptr) -> schedule.Outcome {
	return {ok = false, err = "the gui fuzz runs no command"}
}

@(private)
pass_need :: proc(user: rawptr, need: ui.Need, added: bool) {
	w := (^Window)(user)
	w.data.on_need(w.data.user, need, added)
}

/*
pass_allowed hands the host what it may do in a fuzz run: scan and stop, the
requests about an entry (which a made-up disk's scan refuses, app/act.odin),
exports into the case's folder, the language and theme, and a licence pasted or
read (its activation goes to DEAD_URL). Everything that reaches the system or
the network, monitoring, the recorder, updates and webhooks, and showing a file
in the file manager, is dropped and counted.
*/
@(private)
pass_allowed :: proc(user: rawptr, c: ui.Command) {
	w := (^Window)(user)
	cmd, ok := ui.command_as(c, command.Command)
	if !ok {
		w.dropped += 1
		return
	}
	switch _ in cmd {
	case command.Scan,
	     command.Stop,
	     command.Locate,
	     command.Open,
	     command.Trash,
	     command.Rename,
	     command.Clean,
	     command.Empty_Trash,
	     command.Baseline,
	     command.Export,
	     command.Add_Licence,
	     command.Language,
	     command.Theme,
	     command.Dismiss_Update:
		w.data.on_command(w.data.user, c)
	case command.Reveal,
	     command.Monitoring,
	     command.Watch,
	     command.Unwatch,
	     command.Recording,
	     command.Check_Update,
	     command.Apply_Update,
	     command.Automatic_Checks,
	     command.Add_Webhook,
	     command.Remove_Webhook,
	     command.Test_Webhook:
		w.dropped += 1
	}
}

// --- frames ------------------------------------------------------------------------

/*
settle runs frames until the host has gone quiet: nothing in the inbox and no
frame asked for over QUIET, for at most LONGEST. A gated scan still ticks, so a
quiet window is short; what a case looks at is the frame after it.
*/
settle :: proc(w: ^Window) {
	QUIET   :: 12 * time.Millisecond
	LONGEST :: 400 * time.Millisecond
	start := time.tick_now()
	calm := time.tick_now()
	for time.tick_since(start) < LONGEST {
		pending := ui.inbox_pending(w.data.inbox)
		ui.probe_frame(&w.p)
		if pending || w.p.wants_frame && w.p.frame_after <= 0 {
			calm = time.tick_now()
		} else if time.tick_since(calm) >= QUIET {
			break
		}
		time.sleep(2 * time.Millisecond)
	}

	ui.probe_frame(&w.p)
}

// linger runs frames for LINGER, so whatever the host had still to answer arrives.
linger :: proc(w: ^Window) {
	LINGER :: 2 * time.Second
	start := time.tick_now()
	for time.tick_since(start) < LINGER {
		ui.probe_frame(&w.p)
		time.sleep(5 * time.Millisecond)
	}

	ui.probe_frame(&w.p)
}

// state is how the scan stands on the desk, and the generation it is of.
// The desk owns both; a word read here is at worst a frame stale.
state :: proc(w: ^Window) -> (s: query.State, generation: u32) {
	sc := sync.atomic_load(&w.h.desk.scan)
	if sc == nil {
		return .Idle, sync.atomic_load(&w.h.desk.generation)
	}
	return sync.atomic_load(&sc.state), sync.atomic_load(&w.h.desk.generation)
}

// finish lets the scan run to its end, waiting up to seconds, then holds the
// gate again for the next.
finish :: proc(w: ^Window, seconds := 120) -> bool {
	sync.atomic_store(&gate.open, true)
	defer hold_at_gate()
	defer sync.atomic_store(&gate.open, false)

	deadline := time.tick_now()._nsec + i64(seconds) * i64(time.Second)
	for time.tick_now()._nsec < deadline {
		if s, _ := state(w); s != .Scanning {
			settle(w)
			return true
		}
		ui.probe_frame(&w.p)
		time.sleep(5 * time.Millisecond)
	}
	return false
}
