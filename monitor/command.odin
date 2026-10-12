package leita_monitor

import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

import "jm:sh"
import "jm:timefmt"

import "../alert"
import "../gui/msg"
import "../history"
import "../human"
import "../licence"
import "../schedule"
import "../settings"
import "../webhook"

/*
The monitor's command line, which both binaries answer as their first argument
`monitor`: leita monitor ..., and Leita monitor ... for the window's, so the
scheduler's entry runs whichever binary turned monitoring on.
*/

USAGE :: `Usage: leita monitor [command]

Monitoring scans the places you watch on a schedule, gently, while leita is
closed, and keeps each scan so change tracking has a steady record. It runs
only while turned on, through the system's scheduler; nothing stays running.
A limit crossed raises an alert, once, as a desktop notification and in list.

  run [--all]        scan each watched place that is due, then exit; what the
                     scheduler runs every hour, and the default command
  list               whether monitoring is on, each place's last run and
                     its alerts
  add PATH [--every hourly|daily|weekly] [limits]
                     watch PATH, daily unless --every says, or change how
                     it is watched; each limit is off unless given:
      --warn-used N    alert once the disk is N percent used
      --fail-used N    alert harder once it is N percent used
      --min-free SIZE  alert once less than SIZE is free, e.g. 20GiB
      --full-within N  alert once the disk is forecast full within N days
      --growth         alert when PATH grows far faster than it has been
  remove PATH        stop watching PATH
  on                 turn monitoring on: hand it to the system's scheduler
  off                turn monitoring off: remove it from the scheduler
  webhook add URL [--paths]
                     send each new alert, with a summary of the scan, to URL
                     (https), signed with a secret this prints; --paths lets
                     it carry the folder paths inside a place
  webhook remove URL stop sending to URL
  webhook list       the webhooks, their secrets and how delivery went
  webhook test [URL] send a test to URL, or to every webhook, now

Nothing is sent anywhere unless you add a webhook.
`

// Context is what the command line works with: where its files are, the
// scheduler, the command the scheduler is to run, whether the paid features
// are unlocked, and how an alert is shown on the desktop, nil for not at all.
Context :: struct {
	paths:    Paths,
	host:     schedule.Host,
	argv:     []string, // what the scheduler runs: this binary, monitor, run
	unlocked: bool,
	now:      time.Time,
	notify:   alert.Runner,
	user:     rawptr, // notify's own
	desktop:  alert.System,
	// How a webhook's delivery is posted, nil for not at all, and the
	// poster's own.
	post:     webhook.Poster,
	posted:   rawptr,
}

// LOCKED says why a paid command was refused.
LOCKED :: "error: monitoring needs a licence now the 30-day trial has ended; add one in Leita, the window, under the key in its toolbar"

// dispatch carries out the monitor command args names, saying how it went on w,
// and returns the exit code.
dispatch :: proc(c: Context, args: []string, w: io.Writer) -> int {
	verb := args[0] if len(args) > 0 else "run"
	rest := args[1:] if len(args) > 0 else nil
	switch verb {
	case "run":
		Run_Flags :: struct {
			all: bool `usage:"Scan every watched place, due or not."`,
		}
		f: Run_Flags
		if code, ok := parse(&f, rest); !ok {
			return code
		}
		if !c.unlocked {
			fmt.wprintln(w, LOCKED)
			return EXIT_FAILED
		}
		return run(
			{
				paths = c.paths,
				now = c.now,
				all = f.all,
				notify = c.notify,
				user = c.user,
				desktop = c.desktop,
				post = c.post,
				posted = c.posted,
			},
			w,
		)
	case "list":
		return list(c, w)
	case "add":
		Add_Flags :: struct {
			path:        string `args:"pos=0,required" usage:"The directory or drive to watch."`,
			every:       string `usage:"How often to scan it: hourly, daily or weekly."`,
			warn_used:   int `usage:"Alert once its disk is this percent used, e.g. 80."`,
			fail_used:   int `usage:"Alert harder once its disk is this percent used, e.g. 95."`,
			min_free:    string `usage:"Alert once its disk has less than this free, e.g. 20GiB."`,
			full_within: int `usage:"Alert once its disk is forecast to be full within this many days."`,
			growth:      bool `usage:"Alert when it grows far faster than it has been."`,
		}
		f := Add_Flags {
			every = "daily",
		}
		if code, ok := parse(&f, rest); !ok {
			return code
		}
		if !c.unlocked {
			fmt.wprintln(w, LOCKED)
			return EXIT_FAILED
		}
		every, ok := settings.frequency_named(f.every)
		if !ok {
			fmt.wprintfln(w, "error: --every is hourly, daily or weekly, not %q", f.every)
			return EXIT_FAILED
		}
		limits := settings.Limits {
			warn_used   = f.warn_used,
			fail_used   = f.fail_used,
			full_within = f.full_within,
			growth      = f.growth,
		}
		for v, name in ([2]int{f.warn_used, f.fail_used}) {
			if v < 0 || v > 100 {
				fmt.wprintfln(
					w,
					"error: --%s is a percent, 0 to 100, not %d",
					"warn-used" if name == 0 else "fail-used",
					v,
				)
				return EXIT_FAILED
			}
		}
		if f.full_within < 0 {
			fmt.wprintfln(w, "error: --full-within is days, not %d", f.full_within)
			return EXIT_FAILED
		}
		if f.min_free != "" {
			if limits.min_free, ok = human.parse_bytes(f.min_free); !ok {
				fmt.wprintfln(
					w,
					"error: cannot read --min-free %q: a size such as 20GiB",
					f.min_free,
				)
				return EXIT_FAILED
			}
		}
		return add(c, f.path, every, limits, w)
	case "remove":
		Remove_Flags :: struct {
			path: string `args:"pos=0,required" usage:"The place to stop watching."`,
		}
		f: Remove_Flags
		if code, ok := parse(&f, rest); !ok {
			return code
		}
		return remove(c, f.path, w)
	case "on":
		if !c.unlocked {
			fmt.wprintln(w, LOCKED)
			return EXIT_FAILED
		}
		return switch_on(c, w)
	case "off":
		return switch_off(c, w)
	case "webhook":
		return dispatch_webhook(c, rest, w)
	case "-h", "--help", "help":
		fmt.wprint(w, USAGE)
		return 0
	}
	fmt.wprintf(w, "error: no monitor command %q\n\n%s", verb, USAGE)
	return EXIT_FAILED
}

// parse reads args into f, saying what is wrong; it fails with the exit code to
// return, 0 for a request for help.
@(private)
parse :: proc(f: ^$T, args: []string) -> (code: int, ok: bool) {
	err := flags.parse(f, args, .Unix)
	if err == nil {
		return 0, true
	}
	flags.print_errors(T, err, "leita monitor", .Unix)
	_, help := err.(flags.Help_Request)
	return 0 if help else EXIT_FAILED, false
}

// open_settings opens the settings store, saying why not on w.
@(private)
open_settings :: proc(c: Context, st: ^settings.Store, w: io.Writer) -> bool {
	if err := settings.open(st, c.paths.settings); err != nil {
		fmt.wprintfln(w, "error: cannot open %s: %s", c.paths.settings, history.describe(err))
		return false
	}
	return true
}

// place_of is path as a place is watched: absolute, in the temp allocator.
place_of :: proc(path: string) -> string {
	abs, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil {
		return path
	}
	if len(abs) > 1 {
		abs = strings.trim_right(abs, `/\`)
		if len(abs) == 2 && abs[1] == ':' {
			abs = strings.concatenate({abs, `\`}, context.temp_allocator)
		}
	}
	return abs
}

@(private)
add :: proc(
	c: Context,
	path: string,
	every: settings.Frequency,
	limits: settings.Limits,
	w: io.Writer,
) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	place := place_of(path)
	if !os.exists(place) {
		fmt.wprintfln(w, "error: %s is not there", place)
		return EXIT_FAILED
	}
	if err := settings.watch(
		&st,
		{place = place, every = every, added = time.to_unix_seconds(c.now), limits = limits},
	); err != nil {
		fmt.wprintfln(w, "error: cannot watch %s: %s", place, history.describe(err))
		return EXIT_FAILED
	}
	fmt.wprintfln(w, "watching %s, %s", place, settings.FREQUENCY_NAMES[every])
	if !settings.monitoring(&st) {
		fmt.wprintln(w, "note: monitoring is off; leita monitor on turns it on")
	}
	return 0
}

@(private)
remove :: proc(c: Context, path: string, w: io.Writer) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	// The place as given first, so one no longer there can still be removed.
	for place in ([]string{path, place_of(path)}) {
		found, err := forget(&st, c.paths, place)
		if err != nil {
			fmt.wprintfln(w, "error: cannot stop watching %s: %s", place, history.describe(err))
			return EXIT_FAILED
		}
		if found {
			fmt.wprintfln(w, "no longer watching %s", place)
			return 0
		}
	}
	fmt.wprintfln(w, "error: %s is not watched", path)
	return EXIT_FAILED
}

// switch_on hands the monitor to the scheduler, then turns monitoring on.
switch_on :: proc(c: Context, w: io.Writer) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	problem, logged_in_only := schedule.install(c.host, c.argv)
	if problem != "" {
		fmt.wprintfln(w, "error: cannot add the %s: %s", schedule.describe(c.host), problem)
		return EXIT_FAILED
	}
	if err := settings.set_monitoring(&st, true); err != nil {
		schedule.remove(c.host)
		fmt.wprintfln(w, "error: cannot turn monitoring on: %s", history.describe(err))
		return EXIT_FAILED
	}
	fmt.wprintfln(w, "monitoring is on: the %s runs it every hour", schedule.describe(c.host))
	if logged_in_only {
		fmt.wprintfln(
			w,
			"note: it runs only while %s is logged in; to run it always: loginctl enable-linger %s",
			c.host.login,
			c.host.login,
		)
	}
	return 0
}

// switch_off turns monitoring off, then takes the monitor out of the scheduler.
switch_off :: proc(c: Context, w: io.Writer) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	if err := settings.set_monitoring(&st, false); err != nil {
		fmt.wprintfln(w, "error: cannot turn monitoring off: %s", history.describe(err))
		return EXIT_FAILED
	}
	if problem := schedule.remove(c.host); problem != "" {
		fmt.wprintfln(w, "error: cannot remove the %s: %s", schedule.describe(c.host), problem)
		return EXIT_FAILED
	}
	fmt.wprintln(w, "monitoring is off, and nothing is scheduled")
	return 0
}

@(private)
list :: proc(c: Context, w: io.Writer) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	switch {
	case settings.monitoring(&st):
		fmt.wprintfln(w, "monitoring is on, through the %s", schedule.describe(c.host))
	case:
		fmt.wprintln(w, "monitoring is off")
	}
	watches, err := settings.watches(&st, context.temp_allocator)
	if err != nil {
		fmt.wprintfln(w, "error: cannot read what is watched: %s", history.describe(err))
		return EXIT_FAILED
	}
	if len(watches) == 0 {
		fmt.wprintln(w, "no place is watched; leita monitor add PATH watches one")
		return 0
	}
	english := new(msg.Strings, context.temp_allocator)
	msg.init(english, .English)
	for watch in watches {
		fmt.wprintfln(w, "%s  %s", watch.place, settings.FREQUENCY_NAMES[watch.every])
		if limits := limits_text(watch.limits); limits != "" {
			fmt.wprintfln(w, "  alerts on %s", limits)
		}
		last, ok := settings.last_run(&st, watch.place, context.temp_allocator)
		switch {
		case !ok:
			fmt.wprintln(w, "  not scanned yet")
		case last.problem != "":
			fmt.wprintfln(w, "  %s  failed: %s", when_(last.started), last.problem)
		case:
			fmt.wprintfln(
				w,
				"  %s  %s, %s",
				when_(last.started),
				human.bytes(last.bytes),
				how_read(last),
			)
		}
		raised, _ := settings.alerts(&st, watch.place, LIST_ALERTS, context.temp_allocator)
		for r in raised {
			if a, known := alert_of(r); known {
				fmt.wprintfln(
					w,
					"  %s  alert: %s",
					when_(r.raised),
					alert.say(english, a, r.place, r.problem),
				)
			}
		}
	}
	return 0
}

// LIST_ALERTS is how many of a place's newest alerts list shows.
LIST_ALERTS :: 5

// limits_text says what a place is checked against, in a line, "" for nothing,
// in the temp allocator.
@(private)
limits_text :: proc(l: settings.Limits) -> string {
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
when_ :: proc(unix: i64) -> string {
	return timefmt.local(time.unix(unix, 0), "%Y-%m-%d %H:%M", context.temp_allocator)
}

/*
run_command_line runs the monitor's command line on this machine, as either
binary does
when its first argument is monitor: the stores beside the history store, the
system's scheduler, and this binary as what the scheduler runs. It says how it
went on standard output and returns the exit code.
*/
run_command_line :: proc(args: []string) -> int {
	kept := history.default_path(context.temp_allocator)
	if kept == "" {
		fmt.eprintln("error: no folder to keep leita's data in")
		return EXIT_FAILED
	}
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		exe = os.args[0]
	}
	host := schedule.host_default(context.temp_allocator)
	paths := paths_beside(kept, context.temp_allocator)
	licensee := licence.licensee_kept(paths.licence)
	first := licence.first_use(licence.path_beside(kept, context.temp_allocator, "first-use"))
	c := Context {
		paths    = paths,
		host     = host,
		argv     = {exe, "monitor", "run"},
		unlocked = licence.unlocked(licensee != "", first),
		now      = time.now(),
		notify   = show,
		desktop  = alert.SYSTEM,
		post     = webhook.post,
	}
	return dispatch(c, args, os.to_writer(os.stdout))
}

// show runs a notification's command for real, and says whether it ran.
@(private)
show :: proc(argv: []string, _: rawptr) -> bool {
	return sh.exec(argv, {timeout = NOTIFY_TIMEOUT}, context.temp_allocator).ok
}

// NOTIFY_TIMEOUT is how long a notification's command may take: one that hangs
// must not hold up the scans after it.
NOTIFY_TIMEOUT :: 20 * time.Second

// dispatch_webhook carries out leita monitor webhook ..., saying how it went on
// w, and returns the exit code.
@(private)
dispatch_webhook :: proc(c: Context, args: []string, w: io.Writer) -> int {
	verb := args[0] if len(args) > 0 else "list"
	rest := args[1:] if len(args) > 0 else nil
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	now := time.to_unix_seconds(c.now)
	switch verb {
	case "add":
		Hook_Flags :: struct {
			url:   string `args:"pos=0,required" usage:"Where to send each alert: an https URL."`,
			paths: bool `usage:"Let it carry the folder paths inside a place."`,
		}
		f: Hook_Flags
		if code, ok := parse(&f, rest); !ok {
			return code
		}
		if !c.unlocked {
			fmt.wprintln(w, LOCKED)
			return EXIT_FAILED
		}
		switch webhook.check_url(f.url) {
		case .None:
		case .Not_Https:
			fmt.wprintfln(w, "error: %s is not https; plain http is only for this machine", f.url)
			return EXIT_FAILED
		case .No_Host:
			fmt.wprintfln(w, "error: %s names no server", f.url)
			return EXIT_FAILED
		}
		if _, err := settings.hook_add(
			&st,
			f.url,
			webhook.make_secret(context.temp_allocator),
			f.paths,
			now,
		); err != nil {
			fmt.wprintfln(w, "error: cannot keep the webhook: %s", history.describe(err))
			return EXIT_FAILED
		}
		fmt.wprintfln(
			w,
			"sending each new alert to %s%s",
			f.url,
			", folder paths included" if f.paths else "",
		)
		print_secret(&st, f.url, w)
		return 0
	case "remove":
		Remove_Hook :: struct {
			url: string `args:"pos=0,required" usage:"The webhook to stop sending to."`,
		}
		f: Remove_Hook
		if code, ok := parse(&f, rest); !ok {
			return code
		}
		found, err := settings.hook_remove(&st, f.url)
		switch {
		case err != nil:
			fmt.wprintfln(w, "error: cannot remove the webhook: %s", history.describe(err))
			return EXIT_FAILED
		case !found:
			fmt.wprintfln(w, "error: no webhook to %s", f.url)
			return EXIT_FAILED
		}
		fmt.wprintfln(w, "no longer sending to %s", f.url)
		return 0
	case "list":
		hooks, err := settings.hooks(&st, context.temp_allocator)
		if err != nil {
			fmt.wprintfln(w, "error: cannot read the webhooks: %s", history.describe(err))
			return EXIT_FAILED
		}
		if len(hooks) == 0 {
			fmt.wprintln(w, "no webhook; nothing is sent anywhere")
		}
		for h in hooks {
			fmt.wprintfln(w, "%s%s", h.url, "  (folder paths included)" if h.paths else "")
			fmt.wprintfln(w, "  secret %s", h.secret)
			switch {
			case h.last_problem != "":
				fmt.wprintfln(w, "  last try failed: %s", h.last_problem)
			case h.last_sent > 0:
				fmt.wprintfln(w, "  last delivered %s", when_(h.last_sent))
			case:
				fmt.wprintln(w, "  nothing delivered yet")
			}
			if n := settings.waiting(&st, h.id); n > 0 {
				fmt.wprintfln(w, "  %d waiting to be taken", n)
			}
		}
		return 0
	case "test":
		Test_Hook :: struct {
			url: string `args:"pos=0" usage:"The webhook to test; every one unless given."`,
		}
		f: Test_Hook
		if code, ok := parse(&f, rest); !ok {
			return code
		}
		if !c.unlocked {
			fmt.wprintln(w, LOCKED)
			return EXIT_FAILED
		}
		return test_hooks(c, &st, f.url, now, w)
	}
	fmt.wprintf(w, "error: no webhook command %q\n\n%s", verb, USAGE)
	return EXIT_FAILED
}

// print_secret says the secret of the webhook to url, for its server to check
// each request with.
@(private)
print_secret :: proc(st: ^settings.Store, url: string, w: io.Writer) {
	hooks, _ := settings.hooks(st, context.temp_allocator)
	for h in hooks {
		if h.url == url {
			fmt.wprintfln(
				w,
				"its secret, for checking X-Leita-Signature on each request: %s",
				h.secret,
			)
		}
	}
}

// test_hooks sends a test to the webhook to url, or to every one for "", now,
// and says how each went on w.
@(private)
test_hooks :: proc(c: Context, st: ^settings.Store, url: string, now: i64, w: io.Writer) -> int {
	hooks, _ := settings.hooks(st, context.temp_allocator)
	tested := 0
	for h in hooks {
		if url != "" && h.url != url {
			continue
		}
		tested += 1
		if problem := webhook.queue_test(st, h.id, now); problem != "" {
			fmt.wprintfln(w, "error: %s", problem)
			return EXIT_FAILED
		}
		if c.post == nil {
			continue
		}
		tally, problem := webhook.deliver(st, now, c.post, c.posted, h.id)
		switch {
		case problem != "":
			fmt.wprintfln(w, "error: %s", problem)
			return EXIT_FAILED
		case tally.taken > 0:
			fmt.wprintfln(w, "%s took the test", h.url)
		case:
			heard, _ := settings.hooks(st, context.temp_allocator)
			why := ""
			for g in heard {
				if g.id == h.id {
					why = g.last_problem
				}
			}
			fmt.wprintfln(
				w,
				"%s did not take the test: %s%s",
				h.url,
				why,
				"; it is tried again on later runs" if tally.later > 0 else "",
			)
		}
	}
	if tested == 0 {
		fmt.wprintln(w, "error: no webhook to test; leita monitor webhook add URL adds one")
		return EXIT_FAILED
	}
	return 0
}
