package leita_schedule

import "core:strings"
import "core:testing"

/*
What leita writes for the three schedulers is an hourly interval and no hour of the
day, so it holds no zone or day length of its own: a unit that named 02:30 would
fall in the hour a clock change repeats or skips.
*/

// The systemd timer is OnCalendar=hourly, the start of each hour, and names no
// calendar time of its own.
@(test)
the_systemd_timer_names_no_hour_of_the_day :: proc(t: ^testing.T) {
	text := timer_text()
	testing.expect(t, strings.contains(text, "OnCalendar=hourly\n"), text)
	testing.expect(t, strings.contains(text, "Persistent=true\n"), text)
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.has_prefix(line, "OnCalendar=") {
			testing.expect_value(t, line, "OnCalendar=hourly")
		}
	}
}

// The launchd agent is a StartInterval of 3600 seconds, and has no calendar interval,
// which names an hour of the day.
@(test)
the_launchd_agent_runs_on_an_interval_not_a_time_of_day :: proc(t: ^testing.T) {
	text := agent_plist({"/usr/local/bin/leita", "monitor", "run"}, "")
	testing.expect(t, strings.contains(text, "<key>StartInterval</key>\n\t<integer>3600</integer>"), text)
	testing.expect(t, !strings.contains(text, "StartCalendarInterval"), "a calendar interval names an hour of the day")
}

// The Windows task repeats every PT1H from a start at midnight on New Year's Day,
// written without an offset or a Z.
@(test)
the_windows_task_repeats_every_hour_from_a_start_long_past :: proc(t: ^testing.T) {
	text := task_xml({`C:\Users\leita\leita.exe`, "monitor", "run"})
	testing.expect(t, strings.contains(text, "<Interval>PT1H</Interval>"), text)
	start := "<StartBoundary>2026-01-01T00:00:00</StartBoundary>"
	testing.expect(t, strings.contains(text, start), text)
	testing.expect(t, !strings.contains(text, "T00:00:00Z") && !strings.contains(text, "T00:00:00+"), text)
}

// A profile path with letters outside ASCII, a Cyrillic or Turkish user name, a
// Windows path in a code page: each scheduler gives back the program it was given.
@(test)
a_program_in_a_non_ascii_profile_is_read_back_from_each_scheduler :: proc(t: ^testing.T) {
	linux := "/home/Ünal Çağlar/ürün dir/日本語/leita"
	testing.expect_value(t, service_program(service_text({linux, "monitor", "run"})), linux)
	testing.expect_value(t, agent_program(agent_plist({linux, "monitor", "run"}, "")), linux)
	windows := `C:\Users\Ünal Çağlar\AppData\Local\Программы\日本語\leita.exe`
	testing.expect_value(t, task_program(task_xml({windows, "monitor", "run"})), windows)
}
