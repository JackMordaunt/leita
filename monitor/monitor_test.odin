package leita_monitor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "../history"
import "../scan"
import "../schedule"
import "../settings"

// A test's machine: a data folder of its own, a place to watch in it, and a
// scheduler that records what it is asked rather than doing it.
@(private = "file")
Bench :: struct {
	dir:      string,
	place:    string,
	c:        Context,
	commands: [dynamic]string,
	refuse:   string, // a scheduler command that starts with this fails
	active:   bool, // the timer is in systemd, including after its file is deleted
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
bench_open :: proc(t: ^testing.T, b: ^Bench) {
	dir, err := os.make_directory_temp("", "leita-monitor-*", context.temp_allocator)
	testing.expect(t, err == nil)
	b.dir = dir
	b.place = join(dir, "watched")
	testing.expect(t, os.make_directory_all(join(b.place, "photos")) == nil)
	body := make([]byte, 2 << 20, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expect(t, os.write_entire_file(join(b.place, "photos", "big.raw"), body) == nil)
	// The binary the scheduler is to run, which list looks for.
	testing.expect(t, os.make_directory_all(join(dir, "bin")) == nil)
	testing.expect(t, os.write_entire_file(join(dir, "bin", "leita"), nil) == nil)
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
			[]string{join(dir, "bin", "leita"), "monitor", "run"},
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

// -h answers with USAGE, plain unless a person is watching, and a command
// that is missing something says so in words and where the words are.
@(test)
help_is_plain_unless_a_person_is_watching :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)

	code, out := run_monitor(&b, "-h")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, out, USAGE)
	code, out = run_monitor(&b, "add")
	testing.expect_value(t, code, EXIT_FAILED)
	testing.expect(t, strings.has_prefix(out, "error: "), out)
	testing.expect(t, strings.has_suffix(out, "leita monitor -h lists what it takes\n"), out)

	b.c.style = {depth = .Three_Bit}
	_, out = run_monitor(&b, "-h")
	testing.expect(t, strings.contains(out, "\x1b[1mWatch\x1b[0m"), "headings are bold")
	testing.expect(t, strings.contains(out, "\x1b[2mleita monitor\x1b[0m \x1b[1madd\x1b[0m"), out)
	_, out = run_monitor(&b, "bogus")
	testing.expect(t, strings.has_prefix(out, "\x1b[1merror:\x1b[0m no monitor command"), out)
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
	testing.expect(t, strings.contains(out, "linger state is unknown"), out)
	testing.expect(t, schedule.installed(b.c.host))
	service, _ := os.read_entire_file(
		join(b.c.host.units, "leita-monitor.service"),
		context.temp_allocator,
	)
	// Spelt as systemd reads a word: a Windows temp folder's backslashes come
	// escaped and the path quoted.
	first := b.c.argv[0]
	exec := fmt.tprintf("ExecStart=%s monitor run\n", schedule.systemd_quote(first))
	testing.expect(t, strings.contains(string(service), exec), string(service))
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.has_prefix(out, "monitoring is on, through the systemd"), out)

	// Started by another path, leita moves the entry to it and says so once.
	moved := join(b.dir, "bin", "leita2")
	testing.expect(t, os.write_entire_file(moved, nil) == nil)
	b.c.argv[0] = moved
	_, out = run_monitor(&b, "list")
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
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.has_prefix(out, "monitoring is on, through"), "and not again")

	// The binary gone, list says which is missing rather than that all is well.
	testing.expect(t, os.remove(moved) == nil)
	_, out = run_monitor(&b, "list")
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
	_, out = run_monitor(&b, "list")
	testing.expect(
		t,
		strings.has_prefix(
			out,
			"monitoring is on, but the systemd user timer leita-monitor.timer is missing; leita monitor on puts it back\n",
		),
		out,
	)
	b.refuse = ""

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
	testing.expect(t, strings.contains(out, "2.1 MB"), out)
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
	testing.expect(t, strings.contains(out, "2.1 MB"), out)
	// The last run updated from the first's tree, and says how much it read again,
	// and since when, as the command line does.
	testing.expectf(t, runs[0].updated, "the last run read whole: %s", runs[0].why)
	testing.expect(t, strings.contains(out, "read again since"), out)

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
	testing.expectf(t, os.exists(baseline), "no baseline at %s", baseline)
	code, _ = run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, 0)
	testing.expect(t, os.exists(baseline), "the baseline went with the place")
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

// The trial is kept in settings.db as well as the first-use file, so deleting
// the file does not open monitoring again once the trial is over.
@(test)
monitoring_stays_locked_when_the_first_use_file_is_deleted :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "leita-trial-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	kept := join(dir, "data", "history.db")
	began := time.unix(1_800_000_000, 0)
	_, open, _ := licence_beside(kept, "", began)
	testing.expect(t, open, "the first run starts the trial")
	month := time.time_add(began, 31 * 24 * time.Hour)
	_, open, _ = licence_beside(kept, "", month)
	testing.expect(t, !open, "a month on, it is over")
	testing.expect(t, os.remove(join(dir, "data", "first-use")) == nil)
	_, open, _ = licence_beside(kept, "", month)
	testing.expect(t, !open, "deleting the file does not restart it")
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
	// Less than 1000 PB free fires on any disk a test runs on, where a percent
	// used does not: a fresh tmpfs is under 1% used.
	_, _ = run_monitor(&b, "add", b.place, "--min-free", "1000PB")
	_, _ = run_monitor(&b, "on")

	_, out := run_monitor(&b, "run")
	testing.expect(t, strings.contains(out, "free, under the 1000.0 PB asked for."), out)
	testing.expect_value(t, len(b.shown), 1)
	if len(b.shown) == 1 {
		testing.expect(t, strings.contains(b.shown[0], "under the 1000.0 PB"), b.shown[0])
	}
	_, out = run_monitor(&b, "run", "--all")
	testing.expect(t, !strings.contains(out, "alert:"), out)
	testing.expect_value(t, len(b.shown), 1)

	_, _ = run_monitor(&b, "add", b.place) // no limits now
	_, _ = run_monitor(&b, "run", "--all")
	_, _ = run_monitor(&b, "add", b.place, "--min-free", "1000PB")
	_, out = run_monitor(&b, "run", "--all")
	testing.expect(t, strings.contains(out, "alert:"), out)
	testing.expect_value(t, len(b.shown), 2)

	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.contains(out, "alerts on under 1000.0 PB free"), out)
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
		"20GB",
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
			"alerts on 80% used, 95% used (fail), under 20.0 GB free, full within 14 days, unusual growth",
		),
		out,
	)
}
