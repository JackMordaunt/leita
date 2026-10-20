package leita_app

import "core:os"
import "core:strings"
import "core:time"

import "../../alert"
import "../../licence"
import "../../monitor"
import "../../schedule"
import "../../settings"
import "../command"
import "../query"

/*
Monitoring, on the desk: what the Monitoring dialog shows and changes. What is
watched and how each run went live in the settings store the monitor's runs
write (package monitor), so the window reads them afresh for every answer and
shows a run that finished while it was open the next time it answers.

Turning monitoring on hands the monitor to the system's scheduler as this
binary, `Leita monitor run`, which the window's main answers as the command
line's does; turning it off takes it back. Both are refused while the paid
features are locked but for turning it off, which always works. The binary is
named by the path it was started by (schedule.this_program), and an entry found
at launch running leita by another path is moved to this one, as the command
line does, without a word: the dialog shows monitoring on either way.

On Linux the dialog also turns the recorder of changes on and off (package
journal), which is not a paid feature: `pkexec Leita journal on|off`, since it
installs a system service. Whether it is on is asked of the system when the dialog
opens and after each switch, and kept: asking forks systemctl, too much for an
answer given every MONITOR_FRESH.
*/

/*
Monitoring is the desk's part in monitoring: the scheduler it hands the monitor
to, what that is to run, and how the last change asked for went.

Whether scheduled scans run only while the person is logged in, or that
cannot be known, is asked of the scheduler with the first answer and again
whenever monitoring is turned on, and kept: the dialog's warning of it is
there from its first frame and stays through every change, rather than
arriving with the switch and leaving with the next place watched, each of
which moved everything beneath it.
*/
Monitoring :: struct {
	host:      schedule.Host,
	own_host:  bool, // host was made by monitor_open, to be freed
	argv:      []string,
	scheduler: string, // the host's describe, kept
	paths:     monitor.Paths, // beside the history store, for a place's baseline
	changed:   u32,
	problem:   string,
	linger:    schedule.Linger, // as the scheduler last said, once asked
	asked:     bool,
	answered:  time.Tick, // when a Monitor need was last answered on a tick
	recorder:  Recorder_Status, // as last asked (recorder_refresh)
	// The program that asks the system for the administrator's rights for the
	// recorder ("" for pkexec), and whether a change of the recorder is out on a
	// worker (set_recording).
	elevate:   string,
	toggling:  bool,
}

// What the system said of the recorder of changes when last asked.
Recorder_Status :: struct {
	installed: bool,
	running:   bool,
}

// How a change of the recorder ended, as the worker that ran it found out.
Recorder_Outcome :: enum u8 {
	Done,
	Dismissed, // the request for administrator rights was closed
	Refused, // and the rights were not given
	Said, // the program said why not, in text
	Failed, // it did not run, or failed without a word: text is what the system said
}

// Recorder_Change is a change of the recorder, back from the worker that ran it: how it
// went, the status the system had afterwards (it is asked there, as it forks),
// and for Said and Failed the words.
Recorder_Change :: struct {
	how:    Recorder_Outcome,
	text:   command.Text,
	status: Recorder_Status,
}

recorder_change_in :: proc(r: Recorder_Change) -> Desk_In {
	return r
}

// finish_recording settles the change of the recorder r says, as the desk's last
// word on it: the switch in the dialog holds what it was set to until now.
finish_recording :: proc(d: ^Desk, r: ^Recorder_Change) {
	d.monitoring.toggling = false
	d.monitoring.recorder = r.status
	why := ""
	switch r.how {
	case .Done:
	case .Dismissed:
		why = "the request for administrator rights was dismissed"
	case .Refused:
		why = "administrator rights were not given"
	case .Said, .Failed:
		why = command.text_of(&r.text)
	}
	if r.how == .Done {
		monitor_settle(d, "")
	} else {
		monitor_settle(d, say(d, .Record_Changes_Failed, why))
	}
}

// MONITOR_FRESH is how often a live Monitor need is answered again on the
// clock, so a run the scheduler finishes while the dialog is open shows.
MONITOR_FRESH :: 2 * time.Second

// monitor_refresh answers each live Monitor need again once MONITOR_FRESH has
// passed since it last was.
monitor_refresh :: proc(d: ^Desk) {
	mo := &d.monitoring
	if time.tick_since(mo.answered) < MONITOR_FRESH {
		return
	}
	mo.answered = time.tick_now()
	asked := false
	for key, q in d.live {
		if _, is := q.(query.Monitor); is {
			answer(d, key, q)
			asked = true
		}
	}
	if asked {
		notify(d)
	}
}

// monitor_open readies monitoring beside the history store at kept: on the
// system's scheduler running this binary, unless the caller gives a scheduler
// of its own and what it runs. It runs after settings_open, so an entry that
// runs leita by another path can be moved to this one.
monitor_open :: proc(d: ^Desk, kept: string, scheduler: ^schedule.Host, argv: []string) {
	mo := &d.monitoring
	mo.paths = monitor.paths_beside(kept)
	if scheduler != nil {
		mo.host = scheduler^
	} else {
		mo.host = schedule.host_default()
		mo.own_host = true
	}
	exe := strings.clone(argv[0]) if len(argv) > 0 else schedule.this_program()
	mo.argv = make([]string, 3)
	mo.argv[0], mo.argv[1], mo.argv[2] = exe, "monitor", "run"
	mo.scheduler = strings.clone(schedule.describe(mo.host))
	if d.settings != nil && settings.monitoring(d.settings) {
		if was := schedule.program(mo.host); was != "" && was != exe {
			schedule.install(mo.host, mo.argv)
		}
	}
}

monitor_close :: proc(d: ^Desk) {
	mo := &d.monitoring
	if mo.own_host {
		schedule.host_destroy(&mo.host)
	}
	if len(mo.argv) > 0 {
		delete(mo.argv[0])
	}
	delete(mo.argv)
	delete(mo.scheduler)
	delete(mo.paths.settings)
	delete(mo.paths.history)
	delete(mo.paths.lock)
	delete(mo.paths.licence)
	delete(mo.problem)
	mo^ = {}
}

// monitor_settle ends a change, with why it was refused, "" when it was made.
@(private)
monitor_settle :: proc(d: ^Desk, problem: string) {
	mo := &d.monitoring
	delete(mo.problem)
	mo.problem = strings.clone(problem)
	mo.changed += 1
}

// unlocked is whether Pro runs: the paid-through grant for this build, or the
// 30-day evaluation. The zero licence is no grant.
@(private = "file")
unlocked :: proc(d: ^Desk) -> bool {
	grant := licence.Licence{}
	if d.licensed {
		grant = d.licence
	}
	return licence.entitled_to_pro(grant, d.first_use, time.now())
}

// set_monitoring turns monitoring on or off as c asks.
set_monitoring :: proc(d: ^Desk, c: command.Monitoring) {
	if d.settings == nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	mo := &d.monitoring
	if !c.on {
		if err := settings.set_monitoring(d.settings, false); err != nil {
			monitor_settle(d, say(d, .Monitor_Unkept))
			return
		}
		if problem := schedule.remove(mo.host); problem != "" {
			monitor_settle(d, say(d, .Monitor_Cannot_Unschedule, mo.scheduler, problem))
			return
		}
		monitor_settle(d, "")
		return
	}
	if !unlocked(d) {
		monitor_settle(d, say(d, .Monitoring_Locked))
		return
	}
	problem, state := schedule.install(mo.host, mo.argv)
	if problem != "" {
		monitor_settle(d, say(d, .Monitor_Cannot_Schedule, mo.scheduler, problem))
		return
	}
	if err := settings.set_monitoring(d.settings, true); err != nil {
		schedule.remove(mo.host)
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	mo.linger, mo.asked = state, true
	monitor_settle(d, "")
}

// watch has the monitor watch the place c names.
watch :: proc(d: ^Desk, c: ^command.Watch) {
	if d.settings == nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	if !unlocked(d) {
		monitor_settle(d, say(d, .Monitoring_Locked))
		return
	}
	path := strings.trim_space(command.text_of(&c.path))
	place := monitor.place_of(path)
	if path == "" || !os.exists(place) {
		monitor_settle(d, say(d, .Monitor_Not_There, path))
		return
	}
	every := settings.Frequency(c.every) if int(c.every) < len(settings.Frequency) else .Daily
	w := settings.Watch {
		place = place,
		every = every,
		added = time.to_unix_seconds(time.now()),
		limits = {
			warn_used = clamp(c.warn_used, 0, 100),
			fail_used = clamp(c.fail_used, 0, 100),
			min_free = c.min_free,
			full_within = max(c.full_within, 0),
			growth = c.growth,
		},
	}
	if err := settings.watch(d.settings, w); err != nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	monitor_settle(d, "")
}

// unwatch stops the monitor watching the place c names.
unwatch :: proc(d: ^Desk, c: ^command.Unwatch) {
	if d.settings == nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	if _, err := settings.unwatch(d.settings, command.text_of(&c.path)); err != nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	monitor_settle(d, "")
}

// monitor_answer is monitoring as the store has it now, in the temp allocator.
monitor_answer :: proc(d: ^Desk) -> query.Monitor_Result {
	mo := &d.monitoring
	r := query.Monitor_Result {
		scheduler = mo.scheduler,
		changed   = mo.changed,
		problem   = mo.problem,
	}
	if !mo.asked {
		mo.linger, mo.asked = schedule.linger(mo.host), true
	}
	switch mo.linger {
	case .While_Logged_In:
		r.note = say(d, .Monitor_Logged_In_Only, mo.host.login)
	case .Unknown:
		r.note = say(d, .Monitor_Linger_Unknown)
	case .Always:
	}
	recorder_answer(d, &r)
	if d.settings == nil {
		return r
	}
	r.on = settings.monitoring(d.settings)
	watches, err := settings.watches(d.settings, context.temp_allocator)
	if err != nil {
		return r
	}
	out := make([]query.Watched_Place, len(watches), context.temp_allocator)
	for w, i in watches {
		out[i] = {
			place       = w.place,
			every       = query.Frequency(w.every),
			warn_used   = w.limits.warn_used,
			fail_used   = w.limits.fail_used,
			min_free    = w.limits.min_free,
			full_within = w.limits.full_within,
			growth      = w.limits.growth,
		}
		if last, ok := settings.last_run(d.settings, w.place, context.temp_allocator); ok {
			out[i].scanned = true
			out[i].started = last.started
			out[i].seconds = last.seconds
			out[i].bytes = last.bytes
			out[i].problem = last.problem
			out[i].alerting = last.firing != ""
		}
	}
	r.watched = out
	raised, _ := settings.alerts(
		d.settings,
		limit = query.MONITOR_ALERTS_LIMIT,
		allocator = context.temp_allocator,
	)
	alerts := make([dynamic]query.Raised_Alert, context.temp_allocator)
	for a in raised {
		if said, known := monitor.alert_of(a); known {
			append(
				&alerts,
				query.Raised_Alert {
					place = a.place,
					raised = a.raised,
					text = alert.say(d.words, said, a.place, a.problem),
				},
			)
		}
	}
	r.alerts = alerts[:]
	return r
}
