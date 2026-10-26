package leita_schedule

import "core:log"
import jm_path "jm:path"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:unicode/utf16"

// A test's system: folders of its own under a temporary directory, and a
// runner that records each command rather than running it, answering as told.
@(private = "file")
Fake :: struct {
	dir:      string,
	commands: [dynamic]string,
	// What a schtasks /Create was given to read, as it read it.
	task:     string,
	// Whether a schtasks /Query finds the task, as Task Scheduler would.
	has_task: bool,
	// Whether this fake's systemd timer or launchd agent is loaded. Disable
	// and bootout clear it, and fail while it is clear.
	active:   bool,
	linger:   string, // what loginctl says of lingering
	refuse:   string, // a command that starts with this fails
}

@(private = "file")
fake_run :: proc(argv: []string, user: rawptr) -> Outcome {
	f := (^Fake)(user)
	line := strings.join(argv, " ", context.temp_allocator)
	append(&f.commands, line)
	if f.refuse != "" && strings.has_prefix(line, f.refuse) {
		return {err = "refused"}
	}
	switch {
	case strings.has_prefix(line, "loginctl show-user"):
		return {ok = true, out = f.linger}
	case strings.has_prefix(line, "schtasks /Create"):
		data, _ := os.read_entire_file(argv[3], context.temp_allocator)
		f.task = from_utf16(data)
		f.has_task = true
	case strings.has_prefix(line, "schtasks /Query"):
		return {ok = f.has_task, out = f.task if f.has_task else ""}
	case strings.has_prefix(line, "schtasks /Delete"):
		f.has_task = false
	case strings.contains(line, "enable --now"):
		f.active = true
	case strings.contains(line, "disable --now"):
		if !f.active {
			return {err = "Failed to disable unit: Unit leita-monitor.timer does not exist"}
		}
		f.active = false
	case strings.contains(line, "is-active"):
		if !f.active {
			return {out = "inactive", err = "inactive"}
		}
		return {ok = true, out = "active"}
	case strings.has_prefix(line, "launchctl bootstrap"):
		f.active = true
	case strings.has_prefix(line, "launchctl bootout"):
		if !f.active {
			return {err = "Boot-out failed: 3: No such process"}
		}
		f.active = false
	case strings.has_prefix(line, "launchctl print"):
		if !f.active {
			return {err = "Could not find service"}
		}
	}
	return {ok = true}
}

@(private = "file")
from_utf16 :: proc(data: []byte) -> string {
	if len(data) < 2 || data[0] != 0xff || data[1] != 0xfe {
		return ""
	}
	units := make([]u16, (len(data) - 2) / 2, context.temp_allocator)
	for &u, i in units {
		u = u16(data[2 + 2 * i]) | u16(data[3 + 2 * i]) << 8
	}
	out := make([]byte, 4 * len(units), context.temp_allocator)
	n := utf16.decode_to_utf8(out, units)
	return string(out[:n])
}

@(private = "file")
fake_host :: proc(t: ^testing.T, f: ^Fake, system: System) -> Host {
	dir, err := jm_path.make_directory_temp("", "leita-schedule-*", context.temp_allocator)
	testing.expectf(t, err == nil, "make_directory_temp: %v", err)

	f.dir = dir
	f.commands = make([dynamic]string, context.temp_allocator)
	h := Host {
		run    = fake_run,
		user   = f,
		system = system,
		uid    = "501",
		login  = "ann",
	}
	h.units, _ = filepath.join({dir, "config", "systemd", "user"}, context.temp_allocator)
	h.agents, _ = filepath.join({dir, "Library", "LaunchAgents"}, context.temp_allocator)
	h.log, _ = filepath.join({dir, "Library", "Logs", "leita", "monitor.log"}, context.temp_allocator)
	h.temp = dir
	return h
}

@(private = "file")
ARGV :: []string{"/opt/leita dev/bin/leita", "monitor", "run"}

@(test)
a_systemd_timer_runs_the_monitor_hourly_and_catches_up :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Systemd)
	defer os.remove_all(f.dir)
	f.linger = "Linger=no\n"

	testing.expect(t, !installed(h))
	clear(&f.commands) // is-active, asked because the unit file is not there yet
	problem, state := install(h, ARGV)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, state, Linger.While_Logged_In)
	testing.expect(t, installed(h))

	service_path, timer_path := unit_paths(h)
	service, _ := os.read_entire_file(service_path, context.temp_allocator)
	testing.expect_value(
		t,
		string(service),
		"[Unit]\nDescription=leita: scan the watched places\n\n" +
		"[Service]\nType=oneshot\nExecStart=\"/opt/leita dev/bin/leita\" monitor run\n" +
		"Nice=10\nIOSchedulingClass=idle\n",
	)
	timer, _ := os.read_entire_file(timer_path, context.temp_allocator)
	testing.expect_value(
		t,
		string(timer),
		"[Unit]\nDescription=leita: scan the watched places when due\n\n" +
		"[Timer]\nOnCalendar=hourly\nPersistent=true\nRandomizedDelaySec=5min\n\n" +
		"[Install]\nWantedBy=timers.target\n",
	)
	testing.expect_value(t, len(f.commands), 3)
	testing.expect_value(t, f.commands[0], "systemctl --user daemon-reload")
	testing.expect_value(t, f.commands[1], "systemctl --user enable --now leita-monitor.timer")
	testing.expect_value(t, f.commands[2], "loginctl show-user ann -p Linger")
	testing.expect_value(t, program(h), "/opt/leita dev/bin/leita")

	clear(&f.commands)
	testing.expect(t, loaded(h))
	testing.expect_value(t, f.commands[0], "systemctl --user is-enabled leita-monitor.timer")
	f.refuse = "systemctl --user is-enabled"
	testing.expect(t, !loaded(h), "systemd no longer has the timer")

	clear(&f.commands)
	testing.expect_value(t, remove(h), "")
	testing.expect(t, !installed(h))
	testing.expect_value(t, program(h), "")
	testing.expect_value(t, f.commands[0], "systemctl --user disable --now leita-monitor.timer")
	testing.expect_value(t, remove(h), "") // what is gone is removed
}

@(test)
a_timer_systemd_refuses_is_not_left_behind :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Systemd)
	defer os.remove_all(f.dir)
	f.refuse = "systemctl --user enable"

	problem, _ := install(h, ARGV)
	testing.expect_value(t, problem, "refused")
	testing.expect(t, !installed(h))
	service, _ := unit_paths(h)
	testing.expect(t, !os.exists(service))
}

@(test)
loginctl_failing_leaves_the_linger_state_unknown :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Systemd)
	defer os.remove_all(f.dir)
	f.refuse = "loginctl"

	problem, state := install(h, ARGV)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, state, Linger.Unknown)
	testing.expect_value(t, linger(h), Linger.Unknown)

	f.refuse = ""
	f.linger = "not a linger line"
	testing.expect_value(t, linger(h), Linger.Unknown)
	f.linger = "Linger=yes\n"
	testing.expect_value(t, linger(h), Linger.Always)
	h.login = ""
	testing.expect_value(t, linger(h), Linger.Unknown)
}

@(test)
monitoring_is_not_scheduled_as_root :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Systemd)
	defer os.remove_all(f.dir)
	h.uid = "0"

	problem, state := install(h, ARGV)
	testing.expect_value(t, state, Linger.Unknown)
	testing.expect(t, strings.contains(problem, "root"), problem)
	service, _ := unit_paths(h)
	testing.expect(t, !os.exists(service))
	testing.expect_value(t, len(f.commands), 0)
}

@(test)
not_loaded_means_the_scheduler_has_no_entry :: proc(t: ^testing.T) {
	testing.expect(
		t,
		not_loaded({err = "Failed to disable unit: Unit leita-monitor.timer does not exist"}),
	)
	testing.expect(t, not_loaded({out = "not-found"}))
	testing.expect(t, not_loaded({err = "Unit leita-monitor.timer not loaded"}))
	testing.expect(t, not_loaded({err = "Boot-out failed: 3: No such process"}))
	testing.expect(t, not_loaded({err = "Could not find service"}))
	testing.expect(t, not_loaded({err = "could not be found"}))
	// inactive is deliberately not a missing job.
	testing.expect(t, !not_loaded({ok = true, out = "inactive"}))
	testing.expect(t, !not_loaded({err = "inactive"}))
	testing.expect(t, !not_loaded({err = "Access denied"}))
}

@(test)
a_deleted_unit_file_still_disables_the_timer :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Systemd)
	defer os.remove_all(f.dir)

	problem, _ := install(h, ARGV)
	testing.expect_value(t, problem, "")
	service, timer := unit_paths(h)
	testing.expect(t, os.remove(timer) == nil)
	testing.expect(t, os.remove(service) == nil)
	testing.expect(t, installed(h), "the timer stays loaded without its file")

	clear(&f.commands)
	testing.expect_value(t, remove(h), "")
	testing.expect_value(t, f.commands[0], "systemctl --user disable --now leita-monitor.timer")
	testing.expect(t, !installed(h))
}

@(test)
a_task_repeats_hourly_catches_up_once_and_never_stacks :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Task_Scheduler)
	defer os.remove_all(f.dir)

	testing.expect(t, !installed(h))
	clear(&f.commands)
	argv := []string{`C:\Program Files\leita\leita.exe`, "monitor", "run"}
	problem, _ := install(h, argv)
	testing.expect_value(t, problem, "")
	testing.expect(t, installed(h))
	testing.expect(t, !os.exists(task_path(h)), "the XML is gone once read")

	want := []string {
		`<?xml version="1.0" encoding="UTF-16"?>`,
		`<URI>\leita\monitor</URI>`,
		"<Interval>PT1H</Interval>",
		"<StartWhenAvailable>true</StartWhenAvailable>",
		"<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>",
		"<LogonType>InteractiveToken</LogonType>",
		"<RunLevel>LeastPrivilege</RunLevel>",
		// Through the console host's headless switch (card 82).
		"<Command>conhost.exe</Command>",
		`<Arguments>--headless &quot;C:\Program Files\leita\leita.exe&quot; monitor run</Arguments>`,
	}
	for w in want {
		testing.expectf(t, strings.contains(f.task, w), "missing %q in\n%s", w, f.task)
	}
	// Task Scheduler takes <Command> as a bare path, so no quote is part of it;
	// the quoting stays inside <Arguments>.
	testing.expect_value(t, xml_text(f.task, "Command"), "conhost.exe")
	testing.expect(t, !strings.contains(xml_text(f.task, "Command"), "&quot;"))
	testing.expect(
		t,
		strings.has_prefix(f.commands[0], `schtasks /Create /XML `) &&
		strings.has_suffix(f.commands[0], `/TN leita\monitor /F`),
		f.commands[0],
	)
	testing.expect_value(t, program(h), `C:\Program Files\leita\leita.exe`)
	testing.expect(t, loaded(h))

	testing.expect_value(t, remove(h), "")
	testing.expect_value(t, program(h), "")
	testing.expect(t, !loaded(h))
	testing.expect(t, !installed(h))
	clear(&f.commands)
	testing.expect_value(t, remove(h), "")
	testing.expect_value(t, len(f.commands), 1)
	testing.expect_value(t, f.commands[0], `schtasks /Query /TN leita\monitor`)
}

@(test)
a_launchd_agent_runs_hourly_in_the_background :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Launchd)
	defer os.remove_all(f.dir)

	problem, state := install(
		h,
		{"/Applications/Leita.app/Contents/MacOS/Leita", "monitor", "run"},
	)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, state, Linger.Always)
	testing.expect(t, installed(h))
	plist, _ := os.read_entire_file(agent_path(h), context.temp_allocator)
	want := []string {
		"<string>dev.mordaunt.leita.monitor</string>",
		"<string>/Applications/Leita.app/Contents/MacOS/Leita</string>\n\t\t<string>monitor</string>\n\t\t<string>run</string>",
		"<key>StartInterval</key>\n\t<integer>3600</integer>",
		"<key>LowPriorityIO</key>\n\t<true/>",
		strings.concatenate(
			{"<key>StandardOutPath</key>\n\t<string>", h.log, "</string>"},
			context.temp_allocator,
		),
		strings.concatenate(
			{"<key>StandardErrorPath</key>\n\t<string>", h.log, "</string>"},
			context.temp_allocator,
		),
	}
	for w in want {
		testing.expectf(t, strings.contains(string(plist), w), "missing %q in\n%s", w, plist)
	}
	folder, _ := filepath.split(h.log)
	testing.expect(t, os.is_dir(folder), "the log's folder is made for launchd")
	testing.expect_value(t, program(h), "/Applications/Leita.app/Contents/MacOS/Leita")
	testing.expect_value(t, log_path(h), h.log)
	testing.expect_value(t, f.commands[0], "launchctl bootout gui/501/dev.mordaunt.leita.monitor")
	testing.expect_value(
		t,
		f.commands[1],
		strings.concatenate(
			{"launchctl bootstrap gui/501 ", agent_path(h)},
			context.temp_allocator,
		),
	)
	clear(&f.commands)
	testing.expect(t, loaded(h))
	testing.expect_value(t, f.commands[0], "launchctl print gui/501/dev.mordaunt.leita.monitor")
	f.refuse = "launchctl print"
	testing.expect(t, !loaded(h), "launchd no longer holds the agent")

	testing.expect_value(t, remove(h), "")
	testing.expect(t, !installed(h))
	testing.expect_value(t, program(h), "")
}

@(test)
a_deleted_agent_file_still_boots_the_agent_out :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Launchd)
	defer os.remove_all(f.dir)

	problem, _ := install(h, ARGV)
	testing.expect_value(t, problem, "")
	testing.expect(t, os.remove(agent_path(h)) == nil)
	testing.expect(t, installed(h), "the agent stays loaded without its file")

	clear(&f.commands)
	testing.expect_value(t, remove(h), "")
	testing.expect_value(t, f.commands[0], "launchctl bootout gui/501/dev.mordaunt.leita.monitor")
	testing.expect(t, !installed(h))
}

/*
The program an entry records is the path leita was started by, its links kept:
a bare name through PATH, a relative path through cwd, an absolute one as is;
one inside an application bundle is the bundle's, and one found nowhere the
resolved executable. A bare name is kept only when it is that executable, so
another install earlier on PATH is skipped.
*/
@(test)
the_program_recorded_is_the_path_leita_was_started_by :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp("", "leita-program-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	bin, _ := filepath.join({dir, "bin"}, context.temp_allocator)
	cellar, _ := filepath.join({dir, "Cellar", "leita", "1.0", "bin"}, context.temp_allocator)
	other, _ := filepath.join({dir, "other"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(bin) == nil)
	testing.expect(t, os.make_directory_all(cellar) == nil)
	testing.expect(t, os.make_directory_all(other) == nil)
	real, _ := filepath.join({cellar, "leita"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(real, transmute([]byte)string("#!/bin/sh\n")) == nil)
	link, _ := filepath.join({bin, "leita"}, context.temp_allocator)
	when ODIN_OS == .Windows {
		testing.expect(t, os.write_entire_file(link, transmute([]byte)string("")) == nil)
	} else {
		testing.expect(t, os.symlink(real, link) == nil)
	}
	// A different file, earlier on PATH than the link: a second install.
	decoy, _ := filepath.join({other, "leita"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(decoy, transmute([]byte)string("other\n")) == nil)
	empty, _ := filepath.join({dir, "empty"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(empty) == nil)
	sep := [1]byte{filepath.LIST_SEPARATOR}
	path := strings.join({other, empty, bin}, string(sep[:]), context.temp_allocator)

	a := context.temp_allocator
	when ODIN_OS == .Windows {
		// Neither file on PATH is the executable named as exe, so both are skipped.
		testing.expect_value(t, stable_program("leita", real, path, dir, a), real)
		// The same file written in another case is this program, and is kept.
		folded := strings.to_upper(link, a)
		testing.expect_value(t, stable_program("leita", folded, bin, dir, a), link)
	} else {
		testing.expect_value(t, stable_program("leita", real, path, dir, a), link)
	}
	testing.expect_value(t, stable_program("leita", real, empty, dir, a), real)
	testing.expect_value(t, stable_program("", real, path, dir, a), real)
	testing.expect_value(t, stable_program(link, real, "", dir, a), link)
	rel, _ := filepath.rel(dir, link, context.temp_allocator)
	rel = strings.concatenate({".", string(filepath.SEPARATOR_STRING), rel}, a)
	testing.expect_value(t, stable_program(rel, real, "", dir, a), link)
	app := "/Applications/Leita.app/Contents/MacOS/Leita"
	testing.expect_value(t, stable_program("leita", app, path, dir, a), app)
	testing.expect_value(t, stable_program(link, app, "", dir, a), app)
	// The bundle's command line, started through a link onto PATH such as
	// /usr/local/bin/leita, keeps the bundle's path, not the link's.
	helper := "/Applications/Leita.app/Contents/Helpers/leita"
	testing.expect_value(t, stable_program("leita", helper, path, dir, a), helper)
	testing.expect_value(t, stable_program(link, helper, "", dir, a), helper)

	// this_program reads the process PATH. Two fixtures stand in for it, so a
	// leita installed on the machine cannot decide the result: an earlier
	// program that is not this binary, then one that is. The file is named as
	// this process was started, leita when just test builds build/test/leita.
	exe, exe_err := os.get_executable_path(a)
	testing.expect(t, exe_err == nil)
	name := filepath.base(os.args[0])
	earlier, _ := filepath.join({dir, "earlier"}, a)
	later, _ := filepath.join({dir, "later"}, a)
	testing.expect(t, os.make_directory_all(earlier) == nil)
	testing.expect(t, os.make_directory_all(later) == nil)
	wrong, _ := filepath.join({earlier, name}, a)
	right, _ := filepath.join({later, name}, a)
	testing.expect(t, os.write_entire_file(wrong, transmute([]byte)string("not this leita\n")) == nil)
	when ODIN_OS == .Windows {
		// os.symlink is unsupported. A copy is a different file, so a bare name
		// falls back to exe; the earlier install must still be skipped.
		data, read_err := os.read_entire_file(exe, a)
		testing.expect(t, read_err == nil)
		testing.expect(t, os.write_entire_file(right, data) == nil)
	} else {
		testing.expect(t, os.symlink(exe, right) == nil)
	}
	was := strings.clone(os.get_env("PATH", a), a)
	testing.expect(
		t,
		os.set_env("PATH", strings.join({earlier, later}, string(sep[:]), a)) == nil,
	)
	defer os.set_env("PATH", was)

	mine := this_program(a)
	testing.expect(t, mine != wrong, "an earlier install is not this program")
	testing.expect(t, os.exists(mine), mine)
	info, info_err := os.stat(mine, a)
	resolved, resolved_err := os.stat(exe, a)
	testing.expect(t, info_err == nil && resolved_err == nil)
	when ODIN_OS == .Windows {
		testing.expect(t, strings.equal_fold(info.fullpath, resolved.fullpath))
	} else {
		testing.expect_value(t, mine, right)
		testing.expect_value(t, info.fullpath, resolved.fullpath)
	}
}

// Each entry's program is read back as it was written, whatever it holds.
@(test)
an_entry_gives_back_the_program_it_was_given :: proc(t: ^testing.T) {
	odd := `/opt/leita "dev" & co/100%$HOME/leita`
	testing.expect_value(t, agent_program(agent_plist({odd, "monitor", "run"}, "")), odd)
	testing.expect_value(t, agent_program("<plist></plist>"), "")
	testing.expect_value(t, service_program(service_text({odd, "monitor", "run"})), odd)
	testing.expect_value(t, service_program(service_text({"/usr/bin/leita", "monitor", "run"})), "/usr/bin/leita")
	testing.expect_value(t, service_program("[Unit]\n"), "")
	windows := `C:\Program Files\leita "dev"\leita.exe`
	testing.expect_value(t, task_program(task_xml({windows, "monitor", "run"})), windows)
	testing.expect_value(t, task_program(task_xml({`C:\leita\leita.exe`, "monitor", "run"})), `C:\leita\leita.exe`)
	testing.expect_value(t, windows_unquote(`"C:\Program Files\\"`), `C:\Program Files\`)
	testing.expect_value(t, task_program("<Task/>"), "")
	// Unquoted, with and without the console host; and a task written before
	// it, which ran the program itself.
	host :: "<Command>conhost.exe</Command><Arguments>"
	testing.expect_value(t, task_program(host + `--headless C:\leita.exe monitor run</Arguments>`), `C:\leita.exe`)
	testing.expect_value(t, task_program(host + "</Arguments>"), "")
	testing.expect_value(t, task_program(`<Command>C:\leita.exe</Command>`), `C:\leita.exe`)
}

@(test)
a_command_line_survives_each_scheduler :: proc(t: ^testing.T) {
	testing.expect_value(t, systemd_quote("/usr/bin/leita"), "/usr/bin/leita")
	testing.expect_value(t, systemd_quote("/mnt/My Disk"), `"/mnt/My Disk"`)
	testing.expect_value(t, systemd_quote(`a"b\c`), `"a\"b\\c"`)
	testing.expect_value(t, systemd_quote("100%$HOME"), "100%%$$HOME")
	testing.expect_value(t, systemd_quote(""), `""`)

	testing.expect_value(t, windows_quote(`C:\leita\leita.exe`), `C:\leita\leita.exe`)
	testing.expect_value(t, windows_quote(`C:\Program Files\`), `"C:\Program Files\\"`)
	testing.expect_value(t, windows_quote(`say "hi"`), `"say \"hi\""`)
	testing.expect_value(t, windows_quote(""), `""`)

	testing.expect_value(t, escape_xml(`<a & 'b'>`), "&lt;a &amp; &apos;b&apos;&gt;")
}

// On a Windows CI runner, a machine of its own, the task is made in Task
// Scheduler for real, read back, and deleted. Anywhere else it would change the
// person's own scheduler, so the test says it left it alone.
@(test)
task_scheduler_takes_and_gives_back_the_task_on_ci :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		if os.get_env("CI", context.temp_allocator) == "true" {
			h := host_default(context.temp_allocator)
			testing.expect_value(t, h.system, System.Task_Scheduler)
			exe, _ := os.get_executable_path(context.temp_allocator)
			problem, _ := install(h, {exe, "monitor", "run"})
			testing.expect_value(t, problem, "")
			testing.expect(t, installed(h), "the task is in Task Scheduler")
			query := run_command({"schtasks", "/Query", "/TN", TASK_NAME, "/XML"}, nil)
			testing.expect(t, strings.contains(query.out, "<Interval>PT1H</Interval>"), query.out)
			testing.expect(t, strings.contains(query.out, "conhost.exe"), query.out)
			testing.expect_value(t, program(h), exe)
			testing.expect_value(t, remove(h), "")
			testing.expect(t, !installed(h), "and gone again")
			log.infof("Task Scheduler made, read back and deleted %s", TASK_NAME)
			return
		}
	}
	log.info("Task Scheduler is changed only on a Windows CI runner: left alone here")
}

// A PATH entry is the running program when it is the same file, whatever it is
// called, and not when it is another one: found by stat without statx.
@(test)
a_path_entry_is_the_running_program_only_when_it_is_the_same_file :: proc(t: ^testing.T) {
	base, base_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, base_err == nil, "no temp directory")
	dir := strings.concatenate({base, "/leita_same_exe"}, context.temp_allocator)
	os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil, "could not make the directory")
	defer os.remove_all(dir)
	exe := strings.concatenate({dir, "/leita"}, context.temp_allocator)
	other := strings.concatenate({dir, "/other"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(exe, []byte{'x'}) == nil, "could not write the program")
	testing.expect(t, os.write_entire_file(other, []byte{'x'}) == nil, "could not write another")
	// A symbolic link on Windows needs a privilege a CI runner's account does not
	// have by default, so only the other cases are asked there.
	when ODIN_OS != .Windows {
		link := strings.concatenate({dir, "/le"}, context.temp_allocator)
		testing.expect(t, os.symlink(exe, link) == nil, "could not link")
		testing.expect(t, same_executable(link, exe), "a link to the program was another file")
	}
	testing.expect(t, same_executable(exe, exe), "the program was another file")
	testing.expect(t, !same_executable(other, exe), "another file was the program")
	testing.expect(t, !same_executable(strings.concatenate({dir, "/absent"}, context.temp_allocator), exe), "a missing file was the program")
}
