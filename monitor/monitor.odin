/*
Package monitor is leita's monitoring, a paid feature: scans of the places the
person watches, run while the window is closed, each kept in history so change
tracking has a steady record. There is no process of its own: the system's
scheduler runs `leita monitor run` every hour (package schedule), and each run
scans the watched places that are due, at the gentle pace, keeps each in the
history store the window reads, records how it went in settings.db, and exits.

Nothing runs unless the person turned monitoring on, and turning it off removes
the scheduler's entry (command.odin). The window and the command line share
what is watched through settings.db, so either can change it.
*/
package leita_monitor

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

import "jm:i18n"
import "jm:sqlite3"

import "../alert"
import "../gui/msg"
import "../history"
import "../human"
import "../licence"
import "../report"
import "../settings"
import "../version"
import "../webhook"

// Paths are the files a run reads and writes.
Paths :: struct {
	settings: string, // settings.db: what is watched, and the runs
	history:  string, // history.db: the scans kept
	lock:     string, // held while a run runs
	licence:  string, // the licence, beside history.db
}

// paths_beside are the files beside the history store at kept, in allocator.
paths_beside :: proc(kept: string, allocator := context.allocator) -> Paths {
	return {
		settings = licence.path_beside(kept, allocator, settings.FILE),
		history = strings.clone(kept, allocator),
		lock = licence.path_beside(kept, allocator, LOCK_FILE),
		licence = licence.path_beside(kept, allocator),
	}
}

// PERIODS are how long each schedule leaves between scans of a place, in
// seconds.
PERIODS := [settings.Frequency]i64 {
	.Hourly = 60 * 60,
	.Daily  = 24 * 60 * 60,
	.Weekly = 7 * 24 * 60 * 60,
}

// SLACK is how early a place may be scanned before its period is up. The
// scheduler starts each run up to five minutes past the hour (schedule.SPREAD,
// and the task's RandomDelay), so an hourly place is due every run, and a daily
// one at about the same hour each day, with room for a run that starts late.
SLACK :: 15 * 60

// due is whether a place scanned every every, last at last (Unix seconds, 0
// for never), is due at now.
due :: proc(every: settings.Frequency, last, now: i64) -> bool {
	return last == 0 || now - last >= PERIODS[every] - SLACK
}

// Options are what a run is asked to do, and how it tells the person of an
// alert: through notify on desktop, nil for not at all.
Options :: struct {
	paths:   Paths,
	now:     time.Time,
	all:     bool, // scan every watched place, due or not
	notify:  alert.Runner,
	user:    rawptr, // notify's own
	desktop: alert.System,
	// How a webhook's delivery is posted (webhook.post), nil for not at all,
	// and the poster's own.
	post:    webhook.Poster,
	posted:  rawptr,
}

// EXIT_FAILED is what a run exits with when a place could not be scanned or
// kept, so the scheduler's own record says so.
EXIT_FAILED :: 1

/*
run scans each watched place that is due, keeps each scan in history, and
records how each went, saying so on w a line a place. It does nothing while
monitoring is off, or while another run holds the lock. It exits EXIT_FAILED
when a place failed, else 0.
*/
run :: proc(opt: Options, w: io.Writer) -> int {
	st: settings.Store
	if err := settings.open(&st, opt.paths.settings); err != nil {
		fmt.wprintfln(w, "error: cannot open %s: %s", opt.paths.settings, history.describe(err))
		return EXIT_FAILED
	}
	defer settings.close(&st)
	if !settings.monitoring(&st) {
		fmt.wprintln(w, "monitoring is off: nothing to do")
		return 0
	}
	l, taken := lock(opt.paths.lock)
	switch taken {
	case .Held:
		fmt.wprintln(w, "another run is still going: standing aside")
		return 0
	case .Failed:
		fmt.wprintfln(w, "error: cannot lock %s", opt.paths.lock)
		return EXIT_FAILED
	case .Taken:
	}
	defer unlock(&l)

	watches, err := settings.watches(&st, context.temp_allocator)
	if err != nil {
		fmt.wprintfln(w, "error: cannot read what is watched: %s", history.describe(err))
		return EXIT_FAILED
	}
	now := time.to_unix_seconds(opt.now)
	words := words_of(&st)
	english := new(msg.Strings, context.temp_allocator)
	msg.init(english, .English)
	hooks, _ := settings.hooks(&st, context.temp_allocator)
	code := 0
	for watch in watches {
		last, has_last := settings.last_run(&st, watch.place, context.temp_allocator)
		if !opt.all && !due(watch.every, last.started if has_last else 0, now) {
			continue
		}
		r, alerts, summaries := scan_one(opt, watch, len(hooks) > 0)
		// What was wrong last run is not news; what is wrong now and was not
		// is raised, once, until it goes and comes back.
		before := alert.conditions_of(last.firing) if has_last else {}
		firing := alert.conditions(alerts)
		if r.problem != "" {
			firing = before + {.Scan_Failed}
		}
		r.firing = alert.keys(firing)
		if _, rerr := settings.record(&st, r); rerr != nil {
			fmt.wprintfln(
				w,
				"error: cannot record the run of %s: %s",
				watch.place,
				history.describe(rerr),
			)
			code = EXIT_FAILED
		}
		if r.problem != "" {
			fmt.wprintfln(w, "%s: failed: %s", watch.place, r.problem)
			code = EXIT_FAILED
		} else {
			fmt.wprintfln(
				w,
				"%s: %s in %.1f s, %s",
				watch.place,
				human.bytes(r.bytes),
				r.seconds,
				how_read(r),
			)
		}
		raised := make([dynamic]alert.Alert, context.temp_allocator)
		for a in alerts {
			if a.kind not_in before {
				append(&raised, a)
			}
		}
		if r.problem != "" && .Scan_Failed not_in before {
			append(&raised, alert.Alert{kind = .Scan_Failed})
		}
		for a in raised {
			raise(&st, opt, words, w, watch.place, a, r)
			if len(hooks) == 0 {
				continue
			}
			e := webhook.Event {
				event   = alert.CONDITION_KEYS[a.kind],
				raised  = opt.now,
				host    = webhook.host_name(),
				place   = watch.place,
				text    = alert.say(english, a, watch.place, r.problem),
				measure = a,
				problem = r.problem,
			}
			if problem := webhook.tell(&st, e, summaries.with_paths, summaries.without_paths, now);
			   problem != "" {
				fmt.wprintfln(w, "error: %s", problem)
			}
		}
	}
	if opt.post != nil && len(hooks) > 0 {
		tally, problem := webhook.deliver(&st, now, opt.post, opt.posted)
		if problem != "" {
			fmt.wprintfln(w, "error: webhooks: %s", problem)
		}
		if tally != {} {
			fmt.wprintfln(
				w,
				"webhooks: %d delivered, %d to try again, %d dropped",
				tally.taken,
				tally.later,
				tally.dropped,
			)
		}
	}
	return code
}

// Summaries are a scan as a webhook's event carries it, in the report schema:
// with folder paths, and without, for a webhook not allowed them.
Summaries :: struct {
	with_paths, without_paths: string,
}

/*
scan_one scans the watched place and keeps the scan in history, and says how
it went and what its limits find wrong, and, when want_summaries, the scan as
a webhook carries it, in the temp allocator.
*/
@(private)
scan_one :: proc(
	opt: Options,
	watch: settings.Watch,
	want_summaries: bool,
) -> (
	r: settings.Run,
	alerts: []alert.Alert,
	summaries: Summaries,
) {
	r.place = watch.place
	r.started = time.to_unix_seconds(opt.now)
	s, problem := survey_place(
		watch.place,
		history.baseline_path(opt.paths.history, watch.place, context.temp_allocator),
	)
	if s == nil {
		r.problem = problem
		return
	}
	defer place_scan_destroy(s)
	r.seconds = time.duration_seconds(s.duration)
	r.bytes = bytes(s)
	r.updated = s.updated
	r.why = s.why
	if sp, ok := s.space.?; ok {
		r.disk_total, r.disk_free = sp.total, sp.free
	}
	snapshots: []history.Snapshot
	snapshots, r.problem = keep(opt.paths.history, s)
	if r.problem == "" {
		alerts = alert.check(rules_of(watch.limits), snapshots)
	}
	if want_summaries && r.problem == "" && len(alerts) > 0 {
		facts := report.Facts {
			target   = s.fill.target,
			engine   = s.engine,
			started  = s.started,
			duration = s.duration,
			space    = s.space,
		}
		limits := report.Options {
			warn_used = watch.limits.warn_used,
			fail_used = watch.limits.fail_used,
			min_free  = watch.limits.min_free,
		}
		summary := report.build(&s.tree, &s.roll, facts, limits, context.temp_allocator)
		summaries = {webhook.summary(&summary, true), webhook.summary(&summary, false)}
	}
	return
}

// rules_of is a watch's limits as alert checks them.
@(private)
rules_of :: proc(l: settings.Limits) -> alert.Rules {
	return {
		warn_used = l.warn_used,
		fail_used = l.fail_used,
		min_free = l.min_free,
		full_within = l.full_within,
		growth = l.growth,
	}
}

// keep keeps the scan in the history store at path, and returns every scan
// kept of the place, newest first, this one among them, or says why it could
// not, in the temp allocator.
@(private)
keep :: proc(path: string, s: ^Place_Scan) -> (snapshots: []history.Snapshot, problem: string) {
	// The store makes its errors in the allocator it was opened in.
	context.allocator = context.temp_allocator
	hs: history.Store
	if err := history.open(&hs, path); err != nil {
		return nil, fmt.tprintf("cannot open %s: %s", path, history.describe(err))
	}
	defer history.close(&hs)
	disk: history.Disk
	if sp, ok := s.space.?; ok {
		disk = {sp.total, sp.free}
	}
	if _, err := history.keep(&hs, s.place, &s.tree, &s.roll, s.top, s.tree.nodes_done, disk);
	   err != nil {
		return nil, fmt.tprintf("cannot keep the scan: %s", history.describe(err))
	}
	snapshots, _ = history.list(&hs, s.place)
	return snapshots, ""
}

/*
raise keeps a, found on place by run r, in the alert log, says it on w, and
shows it as a desktop notification in the person's language. A log that
cannot be written is said on w and does not stop the notification.
*/
@(private)
raise :: proc(
	st: ^settings.Store,
	opt: Options,
	words: ^msg.Strings,
	w: io.Writer,
	place: string,
	a: alert.Alert,
	r: settings.Run,
) {
	said := alert.say(words, a, place, r.problem)
	fmt.wprintfln(w, "%s: alert: %s", place, said)
	kept := settings.Raised {
		place        = place,
		raised       = r.started,
		kind         = alert.CONDITION_KEYS[a.kind],
		used_percent = a.used_percent,
		free         = a.free,
		total        = a.total,
		days         = a.days,
		grew         = a.grew,
		limit        = a.limit,
		problem      = r.problem,
	}
	if err := settings.raise(st, kept); err != nil {
		fmt.wprintfln(w, "error: cannot keep the alert: %s", history.describe(err))
	}
	if opt.notify != nil && !alert.notify(opt.desktop, version.NAME, said, opt.notify, opt.user) {
		fmt.wprintln(w, "note: no desktop notification could be shown")
	}
}

/*
words_of is what the monitor says, in the language the person chose in the
window, else the system's, in the temp allocator: two whole message tables,
kept off the stack.
*/
@(private)
words_of :: proc(st: ^settings.Store) -> ^msg.Strings {
	words := new(msg.Strings, context.temp_allocator)
	locale := msg.system_locale()
	if tag, ok := settings.get(st, settings.LANGUAGE, context.temp_allocator); ok {
		if chosen, found := i18n.locale_match(tag); found && msg.offered(chosen) {
			locale = chosen
		}
	}
	msg.init(words, locale)
	return words
}

// how_read says how a run read its place: updated from the last tree, or
// whole and why, in the temp allocator.
how_read :: proc(r: settings.Run) -> string {
	switch {
	case r.updated:
		return "updated from the last scan"
	case r.why != "":
		return fmt.tprintf("read whole: %s", r.why)
	}
	return "read whole"
}

/*
forget stops watching place and deletes what was kept for its next run, its
baseline, and says whether it was watched. The scans kept in history stay.
*/
forget :: proc(
	st: ^settings.Store,
	paths: Paths,
	place: string,
) -> (
	found: bool,
	err: sqlite3.Error,
) {
	found = settings.unwatch(st, place) or_return
	if found {
		os.remove(history.baseline_path(paths.history, place, context.temp_allocator))
	}
	return
}

// alert_of is an alert as the log kept it, and whether its kind is one this
// build knows.
alert_of :: proc(r: settings.Raised) -> (a: alert.Alert, known: bool) {
	a.kind = alert.condition_of(r.kind) or_return
	a.used_percent = r.used_percent
	a.free, a.total = r.free, r.total
	a.days = r.days
	a.grew = r.grew
	a.limit = r.limit
	return a, true
}
