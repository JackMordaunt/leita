package sonar_schedule

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:unicode/utf16"

@(private)
DAILY :: Entry {
	name = "srv-data",
	target = "/srv/data",
	timing = {every = .Daily, hour = 3, minute = 5},
}

@(test)
names_are_safe_for_units_files_and_tasks :: proc(t: ^testing.T) {
	testing.expect_value(t, safe_name("/home/ann"), "home-ann")
	testing.expect_value(t, safe_name("/"), "root")
	testing.expect_value(t, safe_name(`C:\`), "c")
	testing.expect_value(t, safe_name(`D:\Media Files\..`), "d-media-files")
	testing.expect_value(t, safe_name("/dev/sdb1"), "dev-sdb1")
	testing.expect_value(t, safe_name("My_Backups!!"), "my_backups")
	testing.expect_value(t, safe_name("ünï/x"), "n-x")
	testing.expect_value(t, len(safe_name(strings.repeat("ab/", 50, context.temp_allocator))), 64)
}

@(test)
clocks_and_days_are_read_as_written :: proc(t: ^testing.T) {
	h, m, ok := parse_clock("03:05")
	testing.expect(t, ok && h == 3 && m == 5)
	h, m, ok = parse_clock("23:59")
	testing.expect(t, ok && h == 23 && m == 59)
	for bad in ([]string{"24:00", "3:5", "03:60", "0305", ":05", "03:5x", ""}) {
		_, _, ok = parse_clock(bad)
		testing.expectf(t, !ok, "%q read as a time", bad)
	}
	d, dok := parse_weekday("mon")
	testing.expect(t, dok && d == .Monday)
	d, dok = parse_weekday("Sunday")
	testing.expect(t, dok && d == .Sunday)
	_, dok = parse_weekday("mo")
	testing.expect(t, !dok)
}

@(test)
a_daily_entry_is_a_persistent_timer :: proc(t: ^testing.T) {
	e := DAILY
	e.flags = {"--alert-free", "10"}
	argv := command("/opt/sonar/bin/sonar", e)
	testing.expect_value(t, len(argv), 5)

	service := service_text(e, argv)
	testing.expect_value(
		t,
		service,
		"[Unit]\nDescription=sonar: keep a scan of /srv/data\n\n" +
		"[Service]\nType=oneshot\nExecStart=/opt/sonar/bin/sonar /srv/data --keep --alert-free 10\n" +
		"Nice=10\nIOSchedulingClass=idle\n",
	)
	timer := timer_text(e)
	testing.expect_value(
		t,
		timer,
		"[Unit]\nDescription=sonar: scan /srv/data daily at 03:05\n" +
		"X-Sonar-Target=/srv/data\nX-Sonar-Schedule=daily at 03:05\n\n" +
		"[Timer]\nOnCalendar=*-*-* 03:05:00\nPersistent=true\n\n" +
		"[Install]\nWantedBy=timers.target\n",
	)
}

@(test)
hourly_and_weekly_timers_say_when :: proc(t: ^testing.T) {
	e := DAILY
	e.timing = {
		every = .Hourly,
	}
	hourly := timer_text(e)
	testing.expect(t, strings.contains(hourly, "OnCalendar=*-*-* *:00:00\n"), hourly)
	testing.expect(t, strings.contains(hourly, "Persistent=true\n"), hourly)
	testing.expect(t, strings.contains(hourly, "RandomizedDelaySec=5min\n"), hourly)

	e.timing = {
		every   = .Weekly,
		weekday = .Sunday,
		hour    = 22,
		minute  = 30,
	}
	weekly := timer_text(e)
	testing.expect(t, strings.contains(weekly, "OnCalendar=Sun *-*-* 22:30:00\n"), weekly)
	testing.expect(t, strings.contains(weekly, "Persistent=true\n"), weekly)
	testing.expect(t, !strings.contains(weekly, "RandomizedDelaySec"), weekly)
	testing.expect_value(t, unit_value(weekly, "X-Sonar-Schedule"), "weekly on Sunday at 22:30")
}

@(test)
a_command_line_survives_systemd :: proc(t: ^testing.T) {
	testing.expect_value(t, systemd_quote("/usr/bin/sonar"), "/usr/bin/sonar")
	testing.expect_value(t, systemd_quote("/mnt/My Disk"), `"/mnt/My Disk"`)
	testing.expect_value(t, systemd_quote(`a"b\c`), `"a\"b\\c"`)
	testing.expect_value(t, systemd_quote("https://h/x?a=%20&b=$C"), "https://h/x?a=%%20&b=$$C")
	testing.expect_value(t, systemd_quote(""), `""`)
	testing.expect_value(t, systemd_quote(";"), `";"`)
}

@(test)
a_task_catches_up_once_and_never_stacks :: proc(t: ^testing.T) {
	e := DAILY
	e.name = "c"
	e.target = `C:\`
	e.flags = {"--history", `C:\Users\Ann Lee\sonar.db`, "--webhook", "https://h/x?a=1&b=2"}
	argv := command(`C:\Program Files\sonar\sonar.exe`, e)
	xml := task_xml(e, argv)

	expect_has :: proc(t: ^testing.T, xml, want: string, loc := #caller_location) {
		testing.expectf(t, strings.contains(xml, want), "missing %q in\n%s", want, xml, loc = loc)
	}
	expect_has(t, xml, `<?xml version="1.0" encoding="UTF-16"?>`)
	expect_has(t, xml, `<URI>\sonar\c</URI>`)
	expect_has(t, xml, "<StartWhenAvailable>true</StartWhenAvailable>")
	expect_has(t, xml, "<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>")
	expect_has(
		t,
		xml,
		"<CalendarTrigger>\n      <StartBoundary>2026-01-01T03:05:00</StartBoundary>\n" +
		"      <Enabled>true</Enabled>\n      <ScheduleByDay>\n        <DaysInterval>1</DaysInterval>",
	)
	expect_has(t, xml, "<Command>&quot;C:\\Program Files\\sonar\\sonar.exe&quot;</Command>")
	expect_has(
		t,
		xml,
		"<Arguments>C:\\ --keep --history &quot;C:\\Users\\Ann Lee\\sonar.db&quot; " +
		"--webhook https://h/x?a=1&amp;b=2</Arguments>",
	)
	expect_has(t, xml, "<LogonType>InteractiveToken</LogonType>")

	e.timing = {
		every   = .Weekly,
		weekday = .Wednesday,
		hour    = 1,
	}
	e.system = true
	weekly := task_xml(e, argv)
	expect_has(t, weekly, "<DaysOfWeek>\n          <Wednesday />\n        </DaysOfWeek>")
	expect_has(t, weekly, "<StartBoundary>2026-01-01T01:00:00</StartBoundary>")
	expect_has(t, weekly, "<UserId>S-1-5-18</UserId>")

	e.timing = {
		every = .Hourly,
	}
	hourly := task_xml(e, argv)
	expect_has(t, hourly, "<Interval>PT1H</Interval>")
	expect_has(t, hourly, "<StartWhenAvailable>true</StartWhenAvailable>")
}

@(test)
a_windows_command_line_splits_back_as_quoted :: proc(t: ^testing.T) {
	args := []string{`C:\Program Files\sonar.exe`, `C:\`, `D:\a dir\`, `say "hi"`, "", `a\\b`}
	quoted := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&quoted, windows_quote(a))
	}
	testing.expect_value(t, quoted[0], `"C:\Program Files\sonar.exe"`)
	testing.expect_value(t, quoted[1], `C:\`)
	testing.expect_value(t, quoted[2], `"D:\a dir\\"`)
	testing.expect_value(t, quoted[3], `"say \"hi\""`)
	line := strings.join(quoted[:], " ", context.temp_allocator)
	back := windows_split(line)
	testing.expect_value(t, len(back), len(args))
	for a, i in args {
		testing.expect_value(t, back[i], a)
	}
}

@(test)
a_task_file_is_utf16_with_a_mark :: proc(t: ^testing.T) {
	data := utf16_file("<é/>")
	testing.expect_value(t, len(data), 10)
	testing.expect_value(t, data[0], 0xff)
	testing.expect_value(t, data[1], 0xfe)
	testing.expect_value(t, data[2], '<')
	testing.expect_value(t, data[3], 0)
	units := ([^]u16)(raw_data(data))[1:5]
	back: [16]byte
	n := utf16.decode_to_utf8(back[:], units)
	testing.expect_value(t, string(back[:n]), "<é/>")
}

// join_path joins parts as a path.
@(private)
join_path :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}

// Recorder stands in for the system: it notes each command, and answers each
// with what answers holds for the command's start, or success.
@(private)
Recorder :: struct {
	commands: [dynamic]string,
	answers:  map[string]Outcome,
}

@(private)
record :: proc(argv: []string, user: rawptr) -> Outcome {
	r := (^Recorder)(user)
	line := strings.join(argv, " ", context.temp_allocator)
	append(&r.commands, line)
	for start, ran in r.answers {
		if strings.has_prefix(line, start) {
			return ran
		}
	}
	return {ok = true}
}

@(test)
units_are_added_listed_and_removed :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "sonar-schedule-units-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	rec := Recorder {
		commands = make([dynamic]string, context.temp_allocator),
		answers  = make(map[string]Outcome, context.temp_allocator),
	}
	rec.answers["loginctl show-user ann"] = {
		ok  = true,
		out = "Linger=no\n",
	}
	rec.answers["systemctl --user show sonar-srv-data.timer"] = {
		ok  = true,
		out = "NextElapseUSecRealtime=Fri 2026-10-09 03:05:00 AEDT\n",
	}
	rec.answers["systemctl --user show sonar-srv-data.service"] = {
		ok  = true,
		out = "ExecMainExitTimestamp=Thu 2026-10-08 03:05:41 AEDT\nExecMainStatus=3\n",
	}
	units, _ := filepath.join({dir, "systemd", "user"}, context.temp_allocator)
	h := Host {
		run   = record,
		user  = &rec,
		units = units,
		login = "ann",
	}

	e := DAILY
	argv := command("/usr/bin/sonar", e)
	testing.expect_value(t, add_units(h, e, argv), "")
	service, _ := os.read_entire_file(
		join_path(units, "sonar-srv-data.service"),
		context.temp_allocator,
	)
	timer, _ := os.read_entire_file(
		join_path(units, "sonar-srv-data.timer"),
		context.temp_allocator,
	)
	testing.expect_value(t, string(service), service_text(e, argv))
	testing.expect_value(t, string(timer), timer_text(e))
	testing.expect_value(t, len(rec.commands), 3)
	testing.expect_value(t, rec.commands[0], "systemctl --user daemon-reload")
	testing.expect_value(t, rec.commands[1], "systemctl --user enable --now sonar-srv-data.timer")
	testing.expect_value(t, rec.commands[2], "loginctl show-user ann -p Linger")

	listed, lerr := list_units(h, false)
	testing.expect_value(t, lerr, "")
	testing.expect_value(t, len(listed), 1)
	testing.expect_value(
		t,
		listed[0],
		Listing {
			name = "srv-data",
			target = "/srv/data",
			timing = "daily at 03:05",
			next = "Fri 2026-10-09 03:05:00 AEDT",
			last = "alert fired at Thu 2026-10-08 03:05:41 AEDT",
		},
	)

	clear(&rec.commands)
	testing.expect_value(t, remove_units(h, "srv-data", false), "")
	testing.expect(t, !os.exists(join_path(units, "sonar-srv-data.service")))
	testing.expect(t, !os.exists(join_path(units, "sonar-srv-data.timer")))
	testing.expect_value(t, rec.commands[0], "systemctl --user disable --now sonar-srv-data.timer")
	testing.expect_value(t, rec.commands[1], "systemctl --user daemon-reload")
	listed, _ = list_units(h, false)
	testing.expect_value(t, len(listed), 0)
	testing.expect(t, remove_units(h, "srv-data", false) != "", "removing what is not there fails")

	// A failed enable leaves nothing behind.
	rec.answers["systemctl --user enable"] = {
		err = "boom",
	}
	testing.expect_value(t, add_units(h, e, argv), "boom")
	testing.expect(t, !os.exists(join_path(units, "sonar-srv-data.timer")))
}

@(test)
the_user_units_are_under_the_config_home :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "sonar-schedule-config-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	was := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", dir)
	defer os.set_env("XDG_CONFIG_HOME", was)

	h := host_default()
	want, _ := filepath.join({dir, "systemd", "user"}, context.temp_allocator)
	testing.expect_value(t, h.units, want)
}

@(test)
tasks_are_added_listed_and_removed :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "sonar-schedule-tasks-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	rec := Recorder {
		commands = make([dynamic]string, context.temp_allocator),
		answers  = make(map[string]Outcome, context.temp_allocator),
	}
	h := Host {
		run  = record,
		user = &rec,
		temp = dir,
	}
	e := DAILY
	e.name = "c"
	e.target = `C:\`
	e.system = true
	testing.expect_value(t, add_task(h, e, command(`C:\sonar\sonar.exe`, e)), "")
	testing.expect_value(t, len(rec.commands), 1)
	xml, _ := filepath.join({dir, "sonar-c.xml"}, context.temp_allocator)
	testing.expect_value(
		t,
		rec.commands[0],
		strings.concatenate(
			{`schtasks /Create /XML `, xml, ` /TN sonar\c /F /RU SYSTEM`},
			context.temp_allocator,
		),
	)
	testing.expect(t, !os.exists(xml), "the XML is gone once schtasks has read it")

	csv :=
		`"HostName","TaskName","Next Run Time","Status","Logon Mode","Last Run Time","Last Result","Author","Task To Run","Start In","Comment"` +
		"\r\n" +
		`"BOX","\sonar\c","9/10/2026 3:05:00 AM","Ready","Interactive/Background","8/10/2026 3:05:00 AM","3","ann","""C:\Program Files\sonar.exe"" C:\ --keep","N/A","daily at 03:05"` +
		"\r\n" +
		`"BOX","\sonar\c","9/10/2026 3:05:00 AM","Ready","Interactive/Background","8/10/2026 3:05:00 AM","3","ann","""C:\Program Files\sonar.exe"" C:\ --keep","N/A","daily at 03:05"` +
		"\r\n" +
		`"BOX","\sonar\d-media","N/A","Ready","Interactive/Background","N/A","267011","ann","""C:\Program Files\sonar.exe"" ""D:\Media"" --keep","N/A","hourly"` +
		"\r\n" +
		`"BOX","\Microsoft\Other","N/A","Ready","Interactive/Background","N/A","0","ann","x.exe","N/A","N/A"` +
		"\r\n"
	rec.answers["schtasks /Query"] = {
		ok  = true,
		out = csv,
	}
	listed, lerr := list_tasks(h)
	testing.expect_value(t, lerr, "")
	testing.expect_value(t, len(listed), 2)
	testing.expect_value(
		t,
		listed[0],
		Listing {
			"c",
			`C:\`,
			"daily at 03:05",
			"9/10/2026 3:05:00 AM",
			"alert fired at 8/10/2026 3:05:00 AM",
		},
	)
	testing.expect_value(t, listed[1], Listing{"d-media", `D:\Media`, "hourly", "N/A", ""})

	clear(&rec.commands)
	testing.expect_value(t, remove_task(h, "c"), "")
	testing.expect_value(t, rec.commands[0], `schtasks /Delete /TN sonar\c /F`)
}
