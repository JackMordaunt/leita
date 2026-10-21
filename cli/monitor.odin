package leita_cli

import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:terminal"
import "core:time"

import "jm:sh"
import "jm:timefmt"

import "../alert"
import "../gui/msg"
import "../history"
import "../human"
import "../licence"
import "../monitor"
import "../schedule"
import "../settings"
import "../term"

/*
The monitor's command line, which both binaries answer as their first argument
`monitor`: leita monitor ..., and Leita monitor ... for the window's, so the
scheduler's entry runs whichever binary turned monitoring on.
*/

MONITOR_USAGE :: `leita monitor — scan the places you watch on a schedule, while leita is closed.

Watch
  leita monitor add PATH [--every hourly|daily|weekly] [LIMITS]
                            watch PATH, daily unless --every says, or change how it is
                            watched; each limit is off unless given:
      --warn-used N         alert once the disk is N percent used
      --fail-used N         alert harder once it is N percent used
      --min-free SIZE       alert once less than SIZE is free, e.g. 20GB
                            sizes are decimal: 1 GB = 1,000,000,000 bytes; GiB is
                            accepted on input
      --full-within N       alert once the disk is forecast full within N days
      --growth              alert when PATH grows far faster than it has been
  leita monitor remove PATH stop watching PATH
  leita monitor list        whether monitoring is on, each place's last run and its alerts
Run
  leita monitor on          turn monitoring on: hand it to the system's scheduler
  leita monitor off         turn monitoring off: remove it from the scheduler
  leita monitor run [--all] scan each watched place that is due, then exit; what the
                            scheduler runs every hour, and the default command

Monitoring runs only while turned on, through the system's scheduler; nothing stays
running. Each scan is kept, so change tracking has a steady record, and a limit
crossed raises an alert, once, as a desktop notification and in list.
`

// Context is what the command line works with: where its files are, the
// scheduler, the command the scheduler is to run, whether the paid features
// are unlocked, how an alert is shown on the desktop, nil for not at all,
// and what its output may carry, plain unless a person is watching.
Monitor_Context :: struct {
	style:    term.Style,
	paths:    monitor.Paths,
	host:     schedule.Host,
	argv:     []string, // what the scheduler runs: this binary, monitor, run
	aside:    io.Writer, // where a note beside the answer goes: stderr, or the answer's writer when nil
	unlocked: bool,
	now:      time.Time,
	notify:   alert.Runner,
	user:     rawptr, // notify's own
	desktop:  alert.System,
}

// LOCKED says why a Pro command was refused. Listing, turning monitoring off
// and removing a place are not refused: the record stays reachable.
MONITOR_LOCKED :: "scheduled scans need a licence now the 30-day Pro evaluation has ended; monitoring can still be turned off, and places removed. add one with leita licence add, or in Leita, the window, under Licence in its settings"

// dispatch carries out the monitor command args names, saying how it went on w,
// and returns the exit code.
monitor_dispatch :: proc(c: Monitor_Context, args: []string, w: io.Writer) -> int {
	verb := args[0] if len(args) > 0 else "run"
	rest := args[1:] if len(args) > 0 else nil
	switch verb {
	case "run":
		Run_Flags :: struct {
			all: bool `usage:"Scan every watched place, due or not."`,
		}
		f: Run_Flags
		if code, ok := monitor_parse(c, &f, rest, w); !ok {
			return code
		}
		if !c.unlocked {
			monitor_errorf(c, w, MONITOR_LOCKED)
			return monitor.EXIT_FAILED
		}
		return monitor.run(
			{
				paths = c.paths,
				now = c.now,
				all = f.all,
				notify = c.notify,
				user = c.user,
				desktop = c.desktop,
			},
			w,
		)
	case "list":
		monitor_heal(c, w)
		return monitor_list(c, w)
	case "add":
		Add_Flags :: struct {
			path:        string `args:"pos=0,required" usage:"The directory or drive to watch."`,
			every:       string `usage:"How often to scan it: hourly, daily or weekly."`,
			warn_used:   int `usage:"Alert once its disk is this percent used, e.g. 80."`,
			fail_used:   int `usage:"Alert harder once its disk is this percent used, e.g. 95."`,
			min_free:    string `usage:"Alert once its disk has less than this free, e.g. 20GB (decimal; GiB is accepted)."`,
			full_within: int `usage:"Alert once its disk is forecast to be full within this many days."`,
			growth:      bool `usage:"Alert when it grows far faster than it has been."`,
		}
		f := Add_Flags {
			every = "daily",
		}
		if code, ok := monitor_parse(c, &f, rest, w); !ok {
			return code
		}
		if !c.unlocked {
			monitor_errorf(c, w, MONITOR_LOCKED)
			return monitor.EXIT_FAILED
		}
		every, ok := settings.frequency_named(f.every)
		if !ok {
			monitor_errorf(c, w, "--every is hourly, daily or weekly, not %q", f.every)
			return monitor.EXIT_FAILED
		}
		limits := settings.Limits {
			warn_used   = f.warn_used,
			fail_used   = f.fail_used,
			full_within = f.full_within,
			growth      = f.growth,
		}
		for v, name in ([2]int{f.warn_used, f.fail_used}) {
			if v < 0 || v > 100 {
				monitor_errorf(
					c,
					w,
					"--%s is a percent, 0 to 100, not %d",
					"warn-used" if name == 0 else "fail-used",
					v,
				)
				return monitor.EXIT_FAILED
			}
		}
		if f.full_within < 0 {
			monitor_errorf(c, w, "--full-within is days, not %d", f.full_within)
			return monitor.EXIT_FAILED
		}
		if f.min_free != "" {
			if limits.min_free, ok = human.parse_bytes(f.min_free); !ok {
				monitor_errorf(
					c,
					w,
					"cannot read --min-free %q: a size such as 20GB or 20GiB",
					f.min_free,
				)
				return monitor.EXIT_FAILED
			}
		}
		monitor_heal(c, w)
		return monitor_add(c, f.path, every, limits, w)
	case "remove":
		Remove_Flags :: struct {
			path: string `args:"pos=0,required" usage:"The place to stop watching."`,
		}
		f: Remove_Flags
		if code, ok := monitor_parse(c, &f, rest, w); !ok {
			return code
		}
		monitor_heal(c, w)
		return monitor_remove(c, f.path, w)
	case "on":
		if !c.unlocked {
			monitor_errorf(c, w, MONITOR_LOCKED)
			return monitor.EXIT_FAILED
		}
		return monitor_switch_on(c, w)
	case "off":
		return monitor_switch_off(c, w)
	case "-h", "--help", "help":
		monitor_print_usage(c, w)
		return 0
	}
	monitor_errorf(c, w, "no monitor command %q", verb)
	fmt.wprintln(w)
	monitor_print_usage(c, w)
	return monitor.EXIT_FAILED
}

// print_usage writes USAGE on w: plain, byte for byte; for a person, with weight.
@(private)
monitor_print_usage :: proc(c: Monitor_Context, w: io.Writer) {
	b := strings.builder_make(context.temp_allocator)
	term.write_usage(&b, c.style, "leita monitor", MONITOR_USAGE)
	fmt.wprint(w, strings.to_string(b))
}

// errorf says what went wrong on w, the prefix in bold for a person.
@(private)
monitor_errorf :: proc(c: Monitor_Context, w: io.Writer, format: string, args: ..any) {
	fmt.wprintfln(
		w,
		"%s %s",
		term.painted(c.style, {.Bold}, "error:"),
		fmt.tprintf(format, ..args),
	)
}

// notef says what a person should know on w, the prefix in bold for them.
@(private)
monitor_notef :: proc(c: Monitor_Context, w: io.Writer, format: string, args: ..any) {
	fmt.wprintfln(w, "%s %s", term.painted(c.style, {.Bold}, "note:"), fmt.tprintf(format, ..args))
}

// parse reads args into f, saying what is wrong on w; it fails with the exit
// code to return, 0 for a request for help, which USAGE answers.
@(private)
monitor_parse :: proc(
	c: Monitor_Context,
	f: ^$T,
	args: []string,
	w: io.Writer,
) -> (
	code: int,
	ok: bool,
) {
	switch e in flags.parse(f, args, .Unix) {
	case nil:
		return 0, true
	case flags.Help_Request:
		monitor_print_usage(c, w)
		return 0, false
	case flags.Parse_Error:
		monitor_errorf(c, w, "%s", e.message)
	case flags.Validation_Error:
		monitor_errorf(c, w, "%s", e.message)
	case flags.Open_File_Error:
		monitor_errorf(c, w, "cannot open %s: %v", e.filename, e.errno)
	}
	fmt.wprintln(w, "leita monitor -h lists what it takes")
	return monitor.EXIT_FAILED, false
}

// open_settings opens the settings store, saying why not on w.
@(private)
monitor_open_settings :: proc(c: Monitor_Context, st: ^settings.Store, w: io.Writer) -> bool {
	if err := settings.open(st, c.paths.settings); err != nil {
		monitor_errorf(c, w, "cannot open %s: %s", c.paths.settings, history.describe(err))
		return false
	}
	return true
}

@(private)
monitor_add :: proc(
	c: Monitor_Context,
	path: string,
	every: settings.Frequency,
	limits: settings.Limits,
	w: io.Writer,
) -> int {
	st: settings.Store
	if !monitor_open_settings(c, &st, w) {
		return monitor.EXIT_FAILED
	}
	defer settings.close(&st)
	place := monitor.place_of(path)
	if !os.exists(place) {
		monitor_errorf(c, w, "%s is not there", place)
		return monitor.EXIT_FAILED
	}
	if err := settings.watch(
		&st,
		{place = place, every = every, added = time.to_unix_seconds(c.now), limits = limits},
	); err != nil {
		monitor_errorf(c, w, "cannot watch %s: %s", place, history.describe(err))
		return monitor.EXIT_FAILED
	}
	fmt.wprintfln(w, "watching %s, %s", place, settings.FREQUENCY_NAMES[every])
	if !settings.monitoring(&st) {
		monitor_notef(c, w, "monitoring is off; leita monitor on turns it on")
	}
	return 0
}

@(private)
monitor_remove :: proc(c: Monitor_Context, path: string, w: io.Writer) -> int {
	st: settings.Store
	if !monitor_open_settings(c, &st, w) {
		return monitor.EXIT_FAILED
	}
	defer settings.close(&st)
	// The place as given first, so one no longer there can still be removed.
	for place in ([]string{path, monitor.place_of(path)}) {
		found, err := settings.unwatch(&st, place)
		if err != nil {
			monitor_errorf(c, w, "cannot stop watching %s: %s", place, history.describe(err))
			return monitor.EXIT_FAILED
		}
		if found {
			fmt.wprintfln(w, "no longer watching %s", place)
			return 0
		}
	}
	monitor_errorf(c, w, "%s is not watched", path)
	return monitor.EXIT_FAILED
}

/*
heal puts the scheduler's entry right when monitoring is on but the entry runs
leita at another path than this one: an entry made by an earlier install, or
by the other binary, would run what is no longer there. It says so once,
beside the answer, since the person asked for something else.
*/
@(private)
monitor_heal :: proc(c: Monitor_Context, w: io.Writer) {
	st: settings.Store
	if settings.open(&st, c.paths.settings) != nil {
		return
	}
	defer settings.close(&st)
	if !settings.monitoring(&st) {
		return
	}
	was := schedule.program(c.host)
	if was == "" || was == c.argv[0] {
		return
	}
	aside := c.aside if c.aside.procedure != nil else w
	entry := schedule.describe(c.host)
	if problem, _ := schedule.install(c.host, c.argv); problem != "" {
		monitor_errorf(
			c,
			aside,
			"the %s ran %s and cannot be moved to %s: %s",
			entry,
			was,
			c.argv[0],
			problem,
		)
		return
	}
	monitor_notef(c, aside, "the %s ran %s; it now runs %s", entry, was, c.argv[0])
}

// switch_on hands the monitor to the scheduler, then turns monitoring on.
monitor_switch_on :: proc(c: Monitor_Context, w: io.Writer) -> int {
	st: settings.Store
	if !monitor_open_settings(c, &st, w) {
		return monitor.EXIT_FAILED
	}
	defer settings.close(&st)
	problem, state := schedule.install(c.host, c.argv)
	if problem != "" {
		monitor_errorf(c, w, "cannot add the %s: %s", schedule.describe(c.host), problem)
		return monitor.EXIT_FAILED
	}
	if err := settings.set_monitoring(&st, true); err != nil {
		schedule.remove(c.host)
		monitor_errorf(c, w, "cannot turn monitoring on: %s", history.describe(err))
		return monitor.EXIT_FAILED
	}
	fmt.wprintfln(w, "monitoring is on: the %s runs it every hour", schedule.describe(c.host))
	switch state {
	case .While_Logged_In:
		monitor_notef(
			c,
			w,
			"it runs only while %s is logged in; to run it always: loginctl enable-linger %s",
			c.host.login,
			c.host.login,
		)
	case .Unknown:
		monitor_notef(
			c,
			w,
			"The linger state is unknown, so it is not known whether " +
			"scheduled scans run while you are logged out",
		)
	case .Always:
	}
	return 0
}

// switch_off turns monitoring off, then takes the job out of the scheduler,
// which disables it before deleting its files.
monitor_switch_off :: proc(c: Monitor_Context, w: io.Writer) -> int {
	st: settings.Store
	if !monitor_open_settings(c, &st, w) {
		return monitor.EXIT_FAILED
	}
	defer settings.close(&st)
	if err := settings.set_monitoring(&st, false); err != nil {
		monitor_errorf(c, w, "cannot turn monitoring off: %s", history.describe(err))
		return monitor.EXIT_FAILED
	}
	if problem := schedule.remove(c.host); problem != "" {
		monitor_errorf(c, w, "cannot remove the %s: %s", schedule.describe(c.host), problem)
		return monitor.EXIT_FAILED
	}
	fmt.wprintln(w, "monitoring is off, and nothing is scheduled")
	return 0
}

@(private)
monitor_list :: proc(c: Monitor_Context, w: io.Writer) -> int {
	st: settings.Store
	if !monitor_open_settings(c, &st, w) {
		return monitor.EXIT_FAILED
	}
	defer settings.close(&st)
	switch {
	case !settings.monitoring(&st):
		fmt.wprintln(w, "monitoring is off")
	case !schedule.loaded(c.host):
		fmt.wprintfln(
			w,
			"monitoring is on, but the %s is missing; leita monitor on puts it back",
			schedule.describe(c.host),
		)
	case !os.exists(schedule.program(c.host)):
		fmt.wprintfln(
			w,
			"monitoring is on, but the %s runs %s, which is gone; leita monitor on puts it right",
			schedule.describe(c.host),
			schedule.program(c.host),
		)
	case:
		fmt.wprintfln(w, "monitoring is on, through the %s", schedule.describe(c.host))
		if log := schedule.log_path(c.host); log != "" {
			fmt.wprintfln(w, "each run is logged to %s", log)
		}
	}
	watches, err := settings.watches(&st, context.temp_allocator)
	if err != nil {
		monitor_errorf(c, w, "cannot read what is watched: %s", history.describe(err))
		return monitor.EXIT_FAILED
	}
	if len(watches) == 0 {
		fmt.wprintln(w, "no place is watched; leita monitor add PATH watches one")
		return 0
	}
	english := new(msg.Strings, context.temp_allocator)
	msg.init(english, .English)
	for watch in watches {
		fmt.wprintfln(
			w,
			"%s  %s",
			term.painted(c.style, {.Bold}, watch.place),
			settings.FREQUENCY_NAMES[watch.every],
		)
		if limits := monitor_limits_text(watch.limits); limits != "" {
			fmt.wprintfln(w, "  alerts on %s", limits)
		}
		last, ok := settings.last_run(&st, watch.place, context.temp_allocator)
		switch {
		case !ok:
			fmt.wprintln(w, "  not scanned yet")
		case last.problem != "":
			fmt.wprintfln(
				w,
				"  %s  %s %s",
				monitor_when_(last.started),
				term.painted(c.style, {.Bold}, "failed:"),
				last.problem,
			)
		case:
			fmt.wprintfln(
				w,
				"  %s  %s, %s",
				monitor_when_(last.started),
				human.bytes(last.bytes),
				monitor.how_read(last),
			)
		}
		raised, _ := settings.alerts(&st, watch.place, MONITOR_LIST_ALERTS, context.temp_allocator)
		for r in raised {
			if a, known := monitor.alert_of(r); known {
				fmt.wprintfln(
					w,
					"  %s  %s %s",
					monitor_when_(r.raised),
					term.painted(c.style, {.Bold}, "alert:"),
					alert.say(english, a, r.place, r.problem),
				)
			}
		}
	}
	return 0
}

// LIST_ALERTS is how many of a place's newest alerts list shows.
MONITOR_LIST_ALERTS :: 5

// limits_text says what a place is checked against, in a line, "" for nothing,
// in the temp allocator.
@(private)
monitor_limits_text :: proc(l: settings.Limits) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if l.warn_used > 0 {
		append(&parts, fmt.tprintf("%d%% used", l.warn_used))
	}
	if l.fail_used > 0 {
		append(&parts, fmt.tprintf("%d%% used (fail)", l.fail_used))
	}
	if l.min_free > 0 {
		append(&parts, fmt.tprintf("under %s free", human.bytes(l.min_free)))
	}
	if l.full_within > 0 {
		append(&parts, fmt.tprintf("full within %d days", l.full_within))
	}
	if l.growth {
		append(&parts, "unusual growth")
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

// when_ is a run's start on the local clock, in the temp allocator.
@(private)
monitor_when_ :: proc(unix: i64) -> string {
	return timefmt.local(time.unix(unix, 0), "%Y-%m-%d %H:%M", context.temp_allocator)
}

/*
run_command_line runs the monitor's command line on this machine, as either
binary does when its first argument is monitor: the stores beside the history
store, the system's scheduler, and this binary, by the path it was started by
(schedule.this_program), as what the scheduler runs. It says how it went on
standard output, a note beside it on standard error, and returns the exit code.
*/
monitor_run_command_line :: proc(args: []string) -> int {
	mode, _ := term.parse_mode(os.get_env("LEITA_COLOR", context.temp_allocator))
	style := term.detect(terminal.is_terminal(os.stdout), mode)
	kept := history.default_path(context.temp_allocator)
	if kept == "" {
		monitor_errorf(
			{style = style},
			os.to_writer(os.stderr),
			"no folder to keep leita's data in",
		)
		return monitor.EXIT_FAILED
	}
	host := schedule.host_default(context.temp_allocator)
	paths := monitor.paths_beside(kept, context.temp_allocator)
	now := time.now()
	_, unlocked, problem := monitor.licence_beside(
		kept,
		os.get_env(licence.ENV, context.temp_allocator),
		now,
	)
	if problem != "" {
		monitor_notef({style = style}, os.to_writer(os.stderr), "%s", problem)
	}
	c := Monitor_Context {
		style    = style,
		paths    = paths,
		host     = host,
		argv     = {schedule.this_program(context.temp_allocator), "monitor", "run"},
		aside    = os.to_writer(os.stderr),
		unlocked = unlocked,
		now      = now,
		notify   = monitor_show,
		desktop  = alert.SYSTEM,
	}
	return monitor_dispatch(c, args, os.to_writer(os.stdout))
}

// show runs a notification's command for real, and says whether it ran.
@(private)
monitor_show :: proc(argv: []string, _: rawptr) -> bool {
	return sh.exec(argv, {timeout = MONITOR_NOTIFY_TIMEOUT}, context.temp_allocator).ok
}

// NOTIFY_TIMEOUT is how long a notification's command may take: one that hangs
// must not hold up the scans after it.
MONITOR_NOTIFY_TIMEOUT :: 20 * time.Second
