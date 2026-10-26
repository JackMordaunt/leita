package leita_cli

import "base:runtime"

import "core:fmt"
import jm_path "jm:path"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:http/loopback"

import "../history"
import "../monitor"
import "../scan"
import "../schedule"
import "../settings"
import "../webhook"

// A test's machine: a data folder of its own, a place to watch in it, and a
// scheduler that records what it is asked rather than doing it.
@(private = "file")
Monitor_Bench :: struct {
	dir:      string,
	place:    string,
	c:        Monitor_Context,
	commands: [dynamic]string,
	refuse:   string, // a scheduler command that starts with this fails
	active:   bool, // the timer is in systemd, including after its file is deleted
	out:      strings.Builder,
	shown:    [dynamic]string, // each notification's body
}

@(private = "file")
monitor_record_notification :: proc(argv: []string, user: rawptr) -> bool {
	b := (^Monitor_Bench)(user)
	append(&b.shown, strings.clone(argv[len(argv) - 1], context.temp_allocator))
	return true
}

@(private = "file")
monitor_join :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}

@(private = "file")
monitor_record_command :: proc(argv: []string, user: rawptr) -> schedule.Outcome {
	b := (^Monitor_Bench)(user)
	line := strings.join(argv, " ", context.temp_allocator)
	append(&b.commands, line)
	if b.refuse != "" && strings.has_prefix(line, b.refuse) {
		return {err = "refused"}
	}
	// enable is not a substring of disable. is-active is how installed asks
	// once the unit file is gone, and it is active only after enable --now.
	if strings.contains(line, "enable --now") {
		b.active = true
	} else if strings.contains(line, "disable --now") {
		if !b.active {
			return {err = "Failed to disable unit: Unit leita-monitor.timer does not exist"}
		}
		b.active = false
	} else if strings.contains(line, "is-active") {
		if !b.active {
			return {err = "inactive"}
		}
	}
	return {ok = true}
}

@(private = "file")
monitor_bench_open :: proc(t: ^testing.T, b: ^Monitor_Bench) {
	dir, err := jm_path.make_directory_temp("", "leita-monitor-*", context.temp_allocator)
	testing.expect(t, err == nil)
	b.dir = dir
	b.place = monitor_join(dir, "watched")
	testing.expect(t, os.make_directory_all(monitor_join(b.place, "photos")) == nil)
	body := make([]byte, 2 << 20, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expect(
		t,
		os.write_entire_file(monitor_join(b.place, "photos", "big.raw"), body) == nil,
	)
	// The binary the scheduler is to run, which list looks for.
	testing.expect(t, os.make_directory_all(monitor_join(dir, "bin")) == nil)
	testing.expect(t, os.write_entire_file(monitor_join(dir, "bin", "leita"), nil) == nil)
	kept := monitor_join(dir, "data", "history.db")
	b.commands = make([dynamic]string, context.temp_allocator)
	b.shown = make([dynamic]string, context.temp_allocator)
	b.out = strings.builder_make(context.temp_allocator)
	host := schedule.Host {
		run    = monitor_record_command,
		user   = b,
		system = .Systemd,
	}
	host.units = monitor_join(dir, "units")
	b.c = Monitor_Context {
		paths    = monitor.paths_beside(kept, context.temp_allocator),
		host     = host,
		argv     = slice.clone(
			[]string{monitor_join(dir, "bin", "leita"), "monitor", "run"},
			context.temp_allocator,
		),
		unlocked = true,
		now      = time.unix(1_800_000_000, 0),
		notify   = monitor_record_notification,
		user     = b,
		desktop  = .Freedesktop,
	}
}

// run_monitor runs the monitor command args, and returns its exit code and
// what it said.
@(private = "file")
monitor_run_monitor :: proc(b: ^Monitor_Bench, args: ..string) -> (int, string) {
	stdio_shared()
	defer stdio_done()
	strings.builder_reset(&b.out)
	code := monitor_dispatch(b.c, args, strings.to_writer(&b.out))
	return code, strings.clone(strings.to_string(b.out), context.temp_allocator)
}

@(private = "file")
monitor_snapshot_count :: proc(t: ^testing.T, b: ^Monitor_Bench) -> int {
	hs: history.Store
	testing.expect(t, history.open(&hs, b.c.paths.history) == nil)
	defer history.close(&hs)
	// History keeps the place as the scan names it. history.place_of is the
	// tree root, and scan.location returns that path. The watched path can
	// be another spelling of the same directory.
	given := monitor.place_of(b.place)
	target, _, err := scan.resolve(given)
	testing.expect_value(t, err, scan.Error.None)
	if err != nil {
		return 0
	}
	defer scan.target_destroy(&target)
	place := scan.location(target, context.temp_allocator)
	snaps, _ := history.list(&hs, place)
	return len(snaps)
}

@(test)
monitor_help_is_plain_unless_a_person_is_watching :: proc(t: ^testing.T) {
	b: Monitor_Bench
	monitor_bench_open(t, &b)
	defer os.remove_all(b.dir)

	code, out := monitor_run_monitor(&b, "-h")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, out, MONITOR_USAGE)
	code, out = monitor_run_monitor(&b, "add")
	testing.expect_value(t, code, monitor.EXIT_FAILED)
	testing.expect(t, strings.has_prefix(out, "error: "), out)
	testing.expect(t, strings.has_suffix(out, "leita monitor -h lists what it takes\n"), out)

	b.c.style = {
		depth = .Three_Bit,
	}
	_, out = monitor_run_monitor(&b, "-h")
	testing.expect(t, strings.contains(out, "\x1b[1mWatch\x1b[0m"), "headings are bold")
	testing.expect(t, strings.contains(out, "\x1b[2mleita monitor\x1b[0m \x1b[1madd\x1b[0m"), out)
	_, out = monitor_run_monitor(&b, "bogus")
	testing.expect(t, strings.has_prefix(out, "\x1b[1merror:\x1b[0m no monitor command"), out)
}

@(test)
monitor_a_place_is_added_listed_and_removed :: proc(t: ^testing.T) {
	b: Monitor_Bench
	monitor_bench_open(t, &b)
	defer os.remove_all(b.dir)

	code, out := monitor_run_monitor(&b, "add", b.place, "--every", "hourly")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "watching "), out)
	testing.expect(t, strings.contains(out, "monitoring is off"), out)

	code, out = monitor_run_monitor(&b, "list")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "hourly\n  not scanned yet"), out)

	code, out = monitor_run_monitor(&b, "add", b.place, "--every", "fortnightly")
	testing.expect_value(t, code, monitor.EXIT_FAILED)
	code, out = monitor_run_monitor(&b, "add", monitor_join(b.dir, "missing"))
	testing.expect_value(t, code, monitor.EXIT_FAILED)
	testing.expect(t, strings.contains(out, "is not there"), out)

	code, out = monitor_run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, 0)
	code, out = monitor_run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, monitor.EXIT_FAILED)
	testing.expect(t, strings.contains(out, "is not watched"), out)
}

@(test)
monitor_on_hands_the_monitor_to_the_scheduler_and_off_takes_it_back :: proc(t: ^testing.T) {
	b: Monitor_Bench
	monitor_bench_open(t, &b)
	defer os.remove_all(b.dir)

	code, out := monitor_run_monitor(&b, "on")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "monitoring is on"), out)
	testing.expect(t, strings.contains(out, "linger state is unknown"), out)
	testing.expect(t, schedule.installed(b.c.host))
	service, _ := os.read_entire_file(
		monitor_join(b.c.host.units, "leita-monitor.service"),
		context.temp_allocator,
	)
	// Spelt as systemd reads a word: a Windows temp folder's backslashes come
	// escaped and the path quoted.
	first := b.c.argv[0]
	exec := fmt.tprintf("ExecStart=%s monitor run\n", schedule.systemd_quote(first))
	testing.expect(t, strings.contains(string(service), exec), string(service))
	_, out = monitor_run_monitor(&b, "list")
	testing.expect(t, strings.has_prefix(out, "monitoring is on, through the systemd"), out)

	// Started by another path, leita moves the entry to it and says so once.
	moved := monitor_join(b.dir, "bin", "leita2")
	testing.expect(t, os.write_entire_file(moved, nil) == nil)
	b.c.argv[0] = moved
	_, out = monitor_run_monitor(&b, "list")
	testing.expect(
		t,
		strings.has_prefix(
			out,
			fmt.tprintf(
				"note: the systemd user timer leita-monitor.timer ran %s; it now runs %s\n" +
				"monitoring is on, through the systemd",
				first,
				moved,
			),
		),
		out,
	)
	testing.expect_value(t, schedule.program(b.c.host), moved)
	_, out = monitor_run_monitor(&b, "list")
	testing.expect(t, strings.has_prefix(out, "monitoring is on, through"), "and not again")

	// The binary gone, list says which is missing rather than that all is well.
	testing.expect(t, os.remove(moved) == nil)
	_, out = monitor_run_monitor(&b, "list")
	testing.expect(
		t,
		strings.has_prefix(
			out,
			fmt.tprintf(
				"monitoring is on, but the systemd user timer leita-monitor.timer runs %s, which is gone; leita monitor on puts it right\n",
				moved,
			),
		),
		out,
	)

	// The timer gone from systemd, list says so rather than that all is well.
	b.refuse = "systemctl --user is-enabled"
	_, out = monitor_run_monitor(&b, "list")
	testing.expect(
		t,
		strings.has_prefix(
			out,
			"monitoring is on, but the systemd user timer leita-monitor.timer is missing; leita monitor on puts it back\n",
		),
		out,
	)
	b.refuse = ""

	code, out = monitor_run_monitor(&b, "off")
	testing.expect_value(t, code, 0)
	testing.expect(t, !schedule.installed(b.c.host))
	_, out = monitor_run_monitor(&b, "list")
	testing.expect(t, strings.has_prefix(out, "monitoring is off"), out)
}

//review:ignore history-coupled-file command.odin already delegates list wording to how_read in monitor.odin; only the fallback expectation changes.
@(test)
monitor_a_run_scans_what_is_due_and_keeps_it_in_history :: proc(t: ^testing.T) {
	b: Monitor_Bench
	monitor_bench_open(t, &b)
	defer os.remove_all(b.dir)
	_, _ = monitor_run_monitor(&b, "add", b.place, "--every", "daily")

	code, out := monitor_run_monitor(&b, "run")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "monitoring is off"), out)
	testing.expect_value(t, monitor_snapshot_count(t, &b), 0)

	_, _ = monitor_run_monitor(&b, "on")
	code, out = monitor_run_monitor(&b, "run")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "2.1 MB"), out)
	testing.expect_value(t, monitor_snapshot_count(t, &b), 1)

	// Not due again within the day, unless every place is asked for.
	b.c.now = time.time_add(b.c.now, 3 * time.Hour)
	_, out = monitor_run_monitor(&b, "run")
	testing.expect_value(t, out, "")
	testing.expect_value(t, monitor_snapshot_count(t, &b), 1)
	_, out = monitor_run_monitor(&b, "run", "--all")
	testing.expectf(t, monitor_snapshot_count(t, &b) == 2, "after --all: %s", out)
	b.c.now = time.time_add(b.c.now, 24 * time.Hour)
	_, out = monitor_run_monitor(&b, "run")
	testing.expectf(t, monitor_snapshot_count(t, &b) == 3, "a day later: %s", out)

	st: settings.Store
	testing.expect(t, settings.open(&st, b.c.paths.settings) == nil)
	defer settings.close(&st)
	runs, _ := settings.runs(&st, monitor.place_of(b.place), allocator = context.temp_allocator)
	testing.expect_value(t, len(runs), 3)
	testing.expect(t, runs[0].bytes >= 2 << 20)
	testing.expect_value(t, runs[0].problem, "")
	_, out = monitor_run_monitor(&b, "list")
	testing.expect(t, strings.contains(out, "2.1 MB"), out)
	// A sharing-aware filesystem rereads because the baseline lacks extent ids;
	// elsewhere the last run says how much it read again from the first tree.
	if runs[0].updated {
		testing.expect(t, strings.contains(out, "read again since"), out)
	} else {
		testing.expect(
			t,
			runs[0].why == "extent charges require a fresh walk" ||
			runs[0].why == "clone charges require a fresh walk",
			out,
		)
		testing.expect(t, strings.contains(out, fmt.tprintf("read whole: %s", runs[0].why)), out)
	}

	// The first run read the place whole and kept it as the baseline the next
	// update from, named as the command line and the window name theirs; stopping
	// watching it keeps both the baseline and the history, which they share.
	testing.expect(t, !runs[2].updated)
	target, _, err := scan.resolve(b.place)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)
	baseline := history.baseline_path(
		b.c.paths.history,
		scan.location(target, context.temp_allocator),
		context.temp_allocator,
	)
	testing.expect(t, baseline != b.c.paths.history && baseline != b.place)
	testing.expectf(t, os.exists(baseline), "no baseline at %s", baseline)
	code, _ = monitor_run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, 0)
	testing.expect(t, os.exists(baseline), "the baseline went with the place")
	testing.expect_value(t, monitor_snapshot_count(t, &b), 3)
}

@(test)
monitor_a_place_that_cannot_be_scanned_fails_the_run_and_says_why :: proc(t: ^testing.T) {
	b: Monitor_Bench
	monitor_bench_open(t, &b)
	defer os.remove_all(b.dir)
	_, _ = monitor_run_monitor(&b, "add", b.place)
	_, _ = monitor_run_monitor(&b, "on")
	testing.expect(t, os.remove_all(b.place) == nil)

	code, out := monitor_run_monitor(&b, "run")
	testing.expect_value(t, code, monitor.EXIT_FAILED)
	testing.expect(t, strings.contains(out, "failed: cannot scan"), out)
	_, out = monitor_run_monitor(&b, "list")
	testing.expect(t, strings.contains(out, "failed: cannot scan"), out)
}

@(test)
monitor_monitoring_is_refused_once_the_trial_is_over_but_can_still_be_turned_off :: proc(
	t: ^testing.T,
) {
	b: Monitor_Bench
	monitor_bench_open(t, &b)
	defer os.remove_all(b.dir)
	b.c.unlocked = false
	for args in ([][]string{{"run"}, {"add", b.place}, {"on"}}) {
		code, out := monitor_run_monitor(&b, ..args)
		testing.expect_value(t, code, monitor.EXIT_FAILED)
		testing.expect(t, strings.contains(out, "30-day Pro evaluation"), out)
	}
	code, _ := monitor_run_monitor(&b, "off")
	testing.expect_value(t, code, 0)
	code, _ = monitor_run_monitor(&b, "list")
	testing.expect_value(t, code, 0)
}

// The trial is kept in settings.db as well as the first-use file, so deleting
// the file does not open monitoring again once the trial is over.
@(test)
monitor_monitoring_stays_locked_when_the_first_use_file_is_deleted :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp("", "leita-trial-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	kept := monitor_join(dir, "data", "history.db")
	began := time.unix(1_800_000_000, 0)
	_, open, _ := monitor.licence_beside(kept, "", began)
	testing.expect(t, open, "the first run starts the trial")
	month := time.time_add(began, 31 * 24 * time.Hour)
	_, open, _ = monitor.licence_beside(kept, "", month)
	testing.expect(t, !open, "a month on, it is over")
	testing.expect(t, os.remove(monitor_join(dir, "data", "first-use")) == nil)
	_, open, _ = monitor.licence_beside(kept, "", month)
	testing.expect(t, !open, "deleting the file does not restart it")
}

@(test)
monitor_an_alert_is_raised_once_until_it_goes_and_comes_back :: proc(t: ^testing.T) {
	b: Monitor_Bench
	monitor_bench_open(t, &b)
	defer os.remove_all(b.dir)
	// Less than 1000 PB free fires on any disk a test runs on, where a percent
	// used does not: a fresh tmpfs is under 1% used.
	_, _ = monitor_run_monitor(&b, "add", b.place, "--min-free", "1000PB")
	_, _ = monitor_run_monitor(&b, "on")

	_, out := monitor_run_monitor(&b, "run")
	testing.expect(t, strings.contains(out, "free, under the 1000.0 PB asked for."), out)
	testing.expect_value(t, len(b.shown), 1)
	if len(b.shown) == 1 {
		testing.expect(t, strings.contains(b.shown[0], "under the 1000.0 PB"), b.shown[0])
	}
	_, out = monitor_run_monitor(&b, "run", "--all")
	testing.expect(t, !strings.contains(out, "alert:"), out)
	testing.expect_value(t, len(b.shown), 1)

	_, _ = monitor_run_monitor(&b, "add", b.place) // no limits now
	_, _ = monitor_run_monitor(&b, "run", "--all")
	_, _ = monitor_run_monitor(&b, "add", b.place, "--min-free", "1000PB")
	_, out = monitor_run_monitor(&b, "run", "--all")
	testing.expect(t, strings.contains(out, "alert:"), out)
	testing.expect_value(t, len(b.shown), 2)

	_, out = monitor_run_monitor(&b, "list")
	testing.expect(t, strings.contains(out, "alerts on under 1000.0 PB free"), out)
	testing.expect_value(t, strings.count(out, "alert: The disk under"), 2)

	testing.expect(t, os.remove_all(b.place) == nil)
	_, out = monitor_run_monitor(&b, "run", "--all")
	testing.expect(t, strings.contains(out, "alert: The scan of"), out)
	_, out = monitor_run_monitor(&b, "run", "--all")
	testing.expect(t, !strings.contains(out, "alert:"), out)
	testing.expect_value(t, len(b.shown), 3)
}

@(test)
monitor_limits_are_checked_as_they_are_given :: proc(t: ^testing.T) {
	b: Monitor_Bench
	monitor_bench_open(t, &b)
	defer os.remove_all(b.dir)
	bad := [][]string {
		{"add", b.place, "--warn-used", "101"},
		{"add", b.place, "--fail-used", "-1"},
		{"add", b.place, "--min-free", "lots"},
		{"add", b.place, "--full-within", "-3"},
	}
	for args in bad {
		code, out := monitor_run_monitor(&b, ..args)
		testing.expectf(t, code == monitor.EXIT_FAILED, "%v: %s", args, out)
	}
	code, out := monitor_run_monitor(
		&b,
		"add",
		b.place,
		"--warn-used",
		"80",
		"--fail-used",
		"95",
		"--min-free",
		"20GB",
		"--full-within",
		"14",
		"--growth",
	)
	testing.expect_value(t, code, 0)
	_, out = monitor_run_monitor(&b, "list")
	testing.expect(
		t,
		strings.contains(
			out,
			"alerts on 80% used, 95% used (fail), under 20.0 GB free, full within 14 days, unusual growth",
		),
		out,
	)
}

// Monitor_Hook_Server is a webhook's server on this machine, keeping each body it was
// sent, and taking every one.
@(private = "file")
Monitor_Hook_Server :: struct {
	mutex:  sync.Mutex,
	bodies: [dynamic]string,
}

@(private = "file")
monitor_hook_receive :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	s := (^Monitor_Hook_Server)(conn.server.user)
	{
		sync.guard(&s.mutex)
		append(&s.bodies, strings.clone(req.body, runtime.heap_allocator()))
	}
	loopback.send(conn, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
}

// What the server has heard so far, copied under its lock: the handler appends
// on the server's thread, and the reply that follows is no ordering the thread
// sanitizer can see.
@(private = "file")
monitor_hook_heard :: proc(s: ^Monitor_Hook_Server) -> []string {
	sync.guard(&s.mutex)
	return slice.clone(s.bodies[:], context.temp_allocator)
}

// A webhook is added with a secret, tested, and sent each new alert with the
// scan's summary: the place named, the folder paths inside it only once they
// are allowed. Nothing goes anywhere before one is added.
@(test)
a_monitor_webhook_hears_each_new_alert_and_a_test :: proc(t: ^testing.T) {
	b: Monitor_Bench
	monitor_bench_open(t, &b)
	defer os.remove_all(b.dir)
	server: Monitor_Hook_Server
	server.bodies = make([dynamic]string, runtime.heap_allocator())
	defer {
		for body in server.bodies {
			delete(body, runtime.heap_allocator())
		}
		delete(server.bodies)
	}
	srv, ok := loopback.start(monitor_hook_receive, &server, runtime.heap_allocator())
	testing.expect(t, ok)
	defer loopback.stop(srv)
	b.c.post = webhook.post
	url := loopback.url(srv, "/leita")

	_, _ = monitor_run_monitor(&b, "add", b.place, "--warn-used", "1")
	_, _ = monitor_run_monitor(&b, "on")
	_, out := monitor_run_monitor(&b, "run")
	testing.expect(t, !strings.contains(out, "webhooks:"), out)
	testing.expect_value(t, len(monitor_hook_heard(&server)), 0) // nothing is sent before a webhook is added

	code: int
	code, out = monitor_run_monitor(&b, "webhook", "add", "http://example.com/leita")
	testing.expect_value(t, code, monitor.EXIT_FAILED)
	testing.expect(t, strings.contains(out, "not https"), out)
	code, out = monitor_run_monitor(&b, "webhook", "add", url)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "its secret, for checking X-Leita-Signature"), out)

	code, out = monitor_run_monitor(&b, "webhook", "test")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "took the test"), out)
	testing.expect_value(t, len(monitor_hook_heard(&server)), 1)

	// The alert fired last run, before the webhook: clear it, and raise it again.
	_, _ = monitor_run_monitor(&b, "add", b.place)
	_, _ = monitor_run_monitor(&b, "run", "--all")
	_, _ = monitor_run_monitor(&b, "add", b.place, "--warn-used", "1")
	_, out = monitor_run_monitor(&b, "run", "--all")
	testing.expect(t, strings.contains(out, "webhooks: 1 delivered"), out)
	heard := monitor_hook_heard(&server)
	testing.expect_value(t, len(heard), 2)
	if len(heard) == 2 {
		body := heard[1]
		testing.expect(t, strings.contains(body, `"event": "warn_used"`), body)
		testing.expect(t, strings.contains(body, `"schema": "leita.report/1"`), body)
		testing.expect(t, strings.contains(body, `"largest_directories": []`), body)
		testing.expect(t, !strings.contains(body, "big.raw"), "no path inside the place")
	}

	_, _ = monitor_run_monitor(&b, "webhook", "add", url, "--paths")
	_, _ = monitor_run_monitor(&b, "add", b.place)
	_, _ = monitor_run_monitor(&b, "run", "--all")
	_, _ = monitor_run_monitor(&b, "add", b.place, "--warn-used", "1")
	_, _ = monitor_run_monitor(&b, "run", "--all")
	heard = monitor_hook_heard(&server)
	testing.expect_value(t, len(heard), 3)
	if len(heard) == 3 {
		testing.expect(t, strings.contains(heard[2], "big.raw"), "paths, once allowed")
	}

	_, out = monitor_run_monitor(&b, "webhook", "list")
	testing.expect(t, strings.contains(out, "last delivered"), out)
	code, _ = monitor_run_monitor(&b, "webhook", "remove", url)
	testing.expect_value(t, code, 0)
	_, out = monitor_run_monitor(&b, "webhook", "list")
	testing.expect(t, strings.contains(out, "nothing is sent anywhere"), out)
}
