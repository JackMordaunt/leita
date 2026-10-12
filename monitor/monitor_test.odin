package leita_monitor

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:http/loopback"

import "../history"
import "../schedule"
import "../settings"
import "../webhook"

// A test's machine: a data folder of its own, a place to watch in it, and a
// scheduler that records what it is asked rather than doing it.
@(private = "file")
Bench :: struct {
	dir:      string,
	place:    string,
	c:        Context,
	commands: [dynamic]string,
	out:      strings.Builder,
	shown:    [dynamic]string, // each notification's body
}

@(private = "file")
record_notification :: proc(argv: []string, user: rawptr) -> bool {
	b := (^Bench)(user)
	append(&b.shown, strings.clone(argv[len(argv) - 1], context.temp_allocator))
	return true
}

@(private = "file")
join :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}

@(private = "file")
record_command :: proc(argv: []string, user: rawptr) -> schedule.Outcome {
	b := (^Bench)(user)
	append(&b.commands, strings.join(argv, " ", context.temp_allocator))
	return {ok = true}
}

@(private = "file")
bench_open :: proc(t: ^testing.T, b: ^Bench) {
	dir, err := os.make_directory_temp("", "leita-monitor-*", context.temp_allocator)
	testing.expect(t, err == nil)
	b.dir = dir
	b.place = join(dir, "watched")
	testing.expect(t, os.make_directory_all(join(b.place, "photos")) == nil)
	body := make([]byte, 2 << 20, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expect(t, os.write_entire_file(join(b.place, "photos", "big.raw"), body) == nil)
	kept := join(dir, "data", "history.db")
	b.commands = make([dynamic]string, context.temp_allocator)
	b.shown = make([dynamic]string, context.temp_allocator)
	b.out = strings.builder_make(context.temp_allocator)
	host := schedule.Host {
		run    = record_command,
		user   = b,
		system = .Systemd,
	}
	host.units = join(dir, "units")
	b.c = Context {
		paths    = paths_beside(kept, context.temp_allocator),
		host     = host,
		argv     = slice.clone(
			[]string{"/usr/bin/leita", "monitor", "run"},
			context.temp_allocator,
		),
		unlocked = true,
		now      = time.unix(1_800_000_000, 0),
		notify   = record_notification,
		user     = b,
		desktop  = .Freedesktop,
	}
}

// run_monitor runs the monitor command args, and returns its exit code and
// what it said.
@(private = "file")
run_monitor :: proc(b: ^Bench, args: ..string) -> (int, string) {
	strings.builder_reset(&b.out)
	code := dispatch(b.c, args, strings.to_writer(&b.out))
	return code, strings.clone(strings.to_string(b.out), context.temp_allocator)
}

@(private = "file")
snapshot_count :: proc(t: ^testing.T, b: ^Bench) -> int {
	hs: history.Store
	testing.expect(t, history.open(&hs, b.c.paths.history) == nil)
	defer history.close(&hs)
	place := place_of(b.place)
	when ODIN_OS == .Darwin {
		// macOS's temp folder is under /var, a link to /private/var, which a
		// scan resolves (scratch in gui/app/app_test.odin meets the same).
		info, _ := os.stat(place, context.temp_allocator)
		place = info.fullpath
	}
	snaps, _ := history.list(&hs, place)
	return len(snaps)
}

@(test)
a_place_is_due_once_its_period_is_nearly_up :: proc(t: ^testing.T) {
	hour :: 60 * 60
	testing.expect(t, due(.Weekly, 0, 1000), "never scanned is due")
	testing.expect(t, due(.Hourly, 10 * hour, 11 * hour - 4 * 60), "a run five minutes early")
	testing.expect(t, !due(.Hourly, 10 * hour, 10 * hour + 30 * 60))
	testing.expect(t, !due(.Daily, 0 + 1, 20 * hour))
	testing.expect(t, due(.Daily, 1, 24 * hour - 5 * 60))
	testing.expect(t, !due(.Weekly, 1, 6 * 24 * hour))
	testing.expect(t, due(.Weekly, 1, 7 * 24 * hour))
}

@(test)
a_place_is_added_listed_and_removed :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)

	code, out := run_monitor(&b, "add", b.place, "--every", "hourly")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "watching "), out)
	testing.expect(t, strings.contains(out, "monitoring is off"), out)

	code, out = run_monitor(&b, "list")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "hourly\n  not scanned yet"), out)

	code, out = run_monitor(&b, "add", b.place, "--every", "fortnightly")
	testing.expect_value(t, code, EXIT_FAILED)
	code, out = run_monitor(&b, "add", join(b.dir, "missing"))
	testing.expect_value(t, code, EXIT_FAILED)
	testing.expect(t, strings.contains(out, "is not there"), out)

	code, out = run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, 0)
	code, out = run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, EXIT_FAILED)
	testing.expect(t, strings.contains(out, "is not watched"), out)
}

@(test)
on_hands_the_monitor_to_the_scheduler_and_off_takes_it_back :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)

	code, out := run_monitor(&b, "on")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "monitoring is on"), out)
	testing.expect(t, schedule.installed(b.c.host))
	service, _ := os.read_entire_file(
		join(b.c.host.units, "leita-monitor.service"),
		context.temp_allocator,
	)
	testing.expect(t, strings.contains(string(service), "ExecStart=/usr/bin/leita monitor run\n"))
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.has_prefix(out, "monitoring is on"), out)

	code, out = run_monitor(&b, "off")
	testing.expect_value(t, code, 0)
	testing.expect(t, !schedule.installed(b.c.host))
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.has_prefix(out, "monitoring is off"), out)
}

@(test)
a_run_scans_what_is_due_and_keeps_it_in_history :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)
	_, _ = run_monitor(&b, "add", b.place, "--every", "daily")

	code, out := run_monitor(&b, "run")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "monitoring is off"), out)
	testing.expect_value(t, snapshot_count(t, &b), 0)

	_, _ = run_monitor(&b, "on")
	code, out = run_monitor(&b, "run")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "2.0 MiB"), out)
	testing.expect_value(t, snapshot_count(t, &b), 1)

	// Not due again within the day, unless every place is asked for.
	b.c.now = time.time_add(b.c.now, 3 * time.Hour)
	_, out = run_monitor(&b, "run")
	testing.expect_value(t, out, "")
	testing.expect_value(t, snapshot_count(t, &b), 1)
	_, out = run_monitor(&b, "run", "--all")
	testing.expectf(t, snapshot_count(t, &b) == 2, "after --all: %s", out)
	b.c.now = time.time_add(b.c.now, 24 * time.Hour)
	_, out = run_monitor(&b, "run")
	testing.expectf(t, snapshot_count(t, &b) == 3, "a day later: %s", out)

	st: settings.Store
	testing.expect(t, settings.open(&st, b.c.paths.settings) == nil)
	defer settings.close(&st)
	runs, _ := settings.runs(&st, place_of(b.place), allocator = context.temp_allocator)
	testing.expect_value(t, len(runs), 3)
	testing.expect(t, runs[0].bytes >= 2 << 20)
	testing.expect_value(t, runs[0].problem, "")
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.contains(out, "2.0 MiB"), out)

	// The first run read the place whole and kept it as the baseline the next
	// update from; stopping watching it deletes the baseline, not the history.
	testing.expect(t, !runs[2].updated)
	baseline := history.baseline_path(b.c.paths.history, place_of(b.place), context.temp_allocator)
	testing.expect(t, os.exists(baseline), "the baseline is kept")
	code, _ = run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, 0)
	testing.expect(t, !os.exists(baseline), "and goes with the place")
	testing.expect_value(t, snapshot_count(t, &b), 3)
}

@(test)
a_place_that_cannot_be_scanned_fails_the_run_and_says_why :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)
	_, _ = run_monitor(&b, "add", b.place)
	_, _ = run_monitor(&b, "on")
	testing.expect(t, os.remove_all(b.place) == nil)

	code, out := run_monitor(&b, "run")
	testing.expect_value(t, code, EXIT_FAILED)
	testing.expect(t, strings.contains(out, "failed: cannot scan"), out)
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.contains(out, "failed: cannot scan"), out)
}

@(test)
monitoring_is_refused_once_the_trial_is_over_but_can_still_be_turned_off :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)
	b.c.unlocked = false
	for args in ([][]string{{"run"}, {"add", b.place}, {"on"}}) {
		code, out := run_monitor(&b, ..args)
		testing.expect_value(t, code, EXIT_FAILED)
		testing.expect(t, strings.contains(out, "needs a licence"), out)
	}
	code, _ := run_monitor(&b, "off")
	testing.expect_value(t, code, 0)
	code, _ = run_monitor(&b, "list")
	testing.expect_value(t, code, 0)
}

@(test)
a_run_holds_a_lock_another_run_stands_aside_for :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "leita-lock-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/%s", dir, LOCK_FILE)

	l, taken := lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	unlock(&l)
	l, taken = lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	// A second open of the file is refused while the first holds it.
	_, again := lock(path)
	testing.expect_value(t, again, Lock_Result.Held)
	unlock(&l)
	l, taken = lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	unlock(&l)
	_, taken = lock(fmt.tprintf("%s/missing/%s", dir, LOCK_FILE))
	testing.expect_value(t, taken, Lock_Result.Failed)
}

// An alert is raised, said and shown the run it first fires, not again while
// it keeps firing, and again once it has gone and come back. A place that
// cannot be scanned raises one alert however many runs it fails.
@(test)
an_alert_is_raised_once_until_it_goes_and_comes_back :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)
	// 1% used fires on the disks these tests run on, this machine's and CI's
	// runners', which hold far more than that.
	_, _ = run_monitor(&b, "add", b.place, "--warn-used", "1")
	_, _ = run_monitor(&b, "on")

	_, out := run_monitor(&b, "run")
	testing.expect(t, strings.contains(out, "used, past the warning at 1%."), out)
	testing.expect_value(t, len(b.shown), 1)
	if len(b.shown) == 1 {
		testing.expect(t, strings.contains(b.shown[0], "past the warning at 1%"), b.shown[0])
	}
	_, out = run_monitor(&b, "run", "--all")
	testing.expect(t, !strings.contains(out, "alert:"), out)
	testing.expect_value(t, len(b.shown), 1)

	_, _ = run_monitor(&b, "add", b.place) // no limits now
	_, _ = run_monitor(&b, "run", "--all")
	_, _ = run_monitor(&b, "add", b.place, "--warn-used", "1")
	_, out = run_monitor(&b, "run", "--all")
	testing.expect(t, strings.contains(out, "alert:"), out)
	testing.expect_value(t, len(b.shown), 2)

	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.contains(out, "alerts on 1% used"), out)
	testing.expect_value(t, strings.count(out, "alert: The disk under"), 2)

	testing.expect(t, os.remove_all(b.place) == nil)
	_, out = run_monitor(&b, "run", "--all")
	testing.expect(t, strings.contains(out, "alert: The scan of"), out)
	_, out = run_monitor(&b, "run", "--all")
	testing.expect(t, !strings.contains(out, "alert:"), out)
	testing.expect_value(t, len(b.shown), 3)
}

@(test)
limits_are_checked_as_they_are_given :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)
	bad := [][]string {
		{"add", b.place, "--warn-used", "101"},
		{"add", b.place, "--fail-used", "-1"},
		{"add", b.place, "--min-free", "lots"},
		{"add", b.place, "--full-within", "-3"},
	}
	for args in bad {
		code, out := run_monitor(&b, ..args)
		testing.expectf(t, code == EXIT_FAILED, "%v: %s", args, out)
	}
	code, out := run_monitor(
		&b,
		"add",
		b.place,
		"--warn-used",
		"80",
		"--fail-used",
		"95",
		"--min-free",
		"20GiB",
		"--full-within",
		"14",
		"--growth",
	)
	testing.expect_value(t, code, 0)
	_, out = run_monitor(&b, "list")
	testing.expect(
		t,
		strings.contains(
			out,
			"alerts on 80% used, 95% used (fail), under 20.0 GiB free, full within 14 days, unusual growth",
		),
		out,
	)
}

// Hook_Server is a webhook's server on this machine, keeping each body it was
// sent, and taking every one.
@(private = "file")
Hook_Server :: struct {
	mutex:  sync.Mutex,
	bodies: [dynamic]string,
}

@(private = "file")
hook_receive :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	s := (^Hook_Server)(conn.server.user)
	{
		sync.guard(&s.mutex)
		append(&s.bodies, strings.clone(req.body, runtime.heap_allocator()))
	}
	loopback.send(conn, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
}

// A webhook is added with a secret, tested, and sent each new alert with the
// scan's summary: the place named, the folder paths inside it only once they
// are allowed. Nothing goes anywhere before one is added.
@(test)
a_webhook_hears_each_new_alert_and_a_test :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)
	server: Hook_Server
	server.bodies = make([dynamic]string, runtime.heap_allocator())
	defer {
		for body in server.bodies {
			delete(body, runtime.heap_allocator())
		}
		delete(server.bodies)
	}
	srv, ok := loopback.start(hook_receive, &server, runtime.heap_allocator())
	testing.expect(t, ok)
	defer loopback.stop(srv)
	b.c.post = webhook.post
	url := loopback.url(srv, "/leita")

	_, _ = run_monitor(&b, "add", b.place, "--warn-used", "1")
	_, _ = run_monitor(&b, "on")
	_, out := run_monitor(&b, "run")
	testing.expect(t, !strings.contains(out, "webhooks:"), out)
	testing.expect_value(t, len(server.bodies), 0) // nothing is sent before a webhook is added

	code: int
	code, out = run_monitor(&b, "webhook", "add", "http://example.com/leita")
	testing.expect_value(t, code, EXIT_FAILED)
	testing.expect(t, strings.contains(out, "not https"), out)
	code, out = run_monitor(&b, "webhook", "add", url)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "its secret, for checking X-Leita-Signature"), out)

	code, out = run_monitor(&b, "webhook", "test")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "took the test"), out)
	testing.expect_value(t, len(server.bodies), 1)

	// The alert fired last run, before the webhook: clear it, and raise it again.
	_, _ = run_monitor(&b, "add", b.place)
	_, _ = run_monitor(&b, "run", "--all")
	_, _ = run_monitor(&b, "add", b.place, "--warn-used", "1")
	_, out = run_monitor(&b, "run", "--all")
	testing.expect(t, strings.contains(out, "webhooks: 1 delivered"), out)
	testing.expect_value(t, len(server.bodies), 2)
	if len(server.bodies) == 2 {
		body := server.bodies[1]
		testing.expect(t, strings.contains(body, `"event": "warn_used"`), body)
		testing.expect(t, strings.contains(body, `"schema": "leita.report/1"`), body)
		testing.expect(t, strings.contains(body, `"largest_directories": []`), body)
		testing.expect(t, !strings.contains(body, "big.raw"), "no path inside the place")
	}

	_, _ = run_monitor(&b, "webhook", "add", url, "--paths")
	_, _ = run_monitor(&b, "add", b.place)
	_, _ = run_monitor(&b, "run", "--all")
	_, _ = run_monitor(&b, "add", b.place, "--warn-used", "1")
	_, _ = run_monitor(&b, "run", "--all")
	testing.expect_value(t, len(server.bodies), 3)
	if len(server.bodies) == 3 {
		testing.expect(t, strings.contains(server.bodies[2], "big.raw"), "paths, once allowed")
	}

	_, out = run_monitor(&b, "webhook", "list")
	testing.expect(t, strings.contains(out, "last delivered"), out)
	code, _ = run_monitor(&b, "webhook", "remove", url)
	testing.expect_value(t, code, 0)
	_, out = run_monitor(&b, "webhook", "list")
	testing.expect(t, strings.contains(out, "nothing is sent anywhere"), out)
}
