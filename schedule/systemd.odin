package sonar_schedule

import "core:fmt"
import "core:strings"

/*
On Linux an entry is a pair of systemd units: sonar-<name>.service runs the scan
once, and sonar-<name>.timer starts it on the calendar. Persistent=true has
systemd remember when the timer last fired, so a run missed while the machine was
off or asleep runs once when it is next up. An hourly timer starts somewhere in
the first minutes of the hour, so a fleet of machines does not scan in step.

The timer carries the target and the schedule in X-Sonar- keys, which systemd
ignores, so list can say what an entry is from its file alone. systemd.timer(5)
and systemd.unit(5) give Persistent=, RandomizedDelaySec=, OnCalendar= and the
X- keys; systemd.service(5) gives ExecStart= quoting and its % and $ escapes.
*/

// HOURLY_SPREAD is how far past the hour an hourly timer may start.
HOURLY_SPREAD :: "5min"

// on_calendar is timing as systemd's OnCalendar= reads it, on the local clock.
on_calendar :: proc(timing: Timing, allocator := context.temp_allocator) -> string {
	switch timing.every {
	case .Hourly:
		return strings.clone("*-*-* *:00:00", allocator)
	case .Daily:
		return fmt.aprintf("*-*-* %02d:%02d:00", timing.hour, timing.minute, allocator = allocator)
	case .Weekly:
		day := fmt.tprint(timing.weekday)[:3]
		return fmt.aprintf(
			"%s *-*-* %02d:%02d:00",
			day,
			timing.hour,
			timing.minute,
			allocator = allocator,
		)
	}
	return ""
}

// service_text is the service unit that runs argv once, at low priority so the
// machine stays usable while it scans.
service_text :: proc(e: Entry, argv: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"[Unit]\nDescription=sonar: keep a scan of %s\n\n",
		escape_specifiers(e.target),
	)
	strings.write_string(&b, "[Service]\nType=oneshot\nExecStart=")
	for arg, i in argv {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, systemd_quote(arg))
	}
	strings.write_string(&b, "\nNice=10\nIOSchedulingClass=idle\n")
	return strings.to_string(b)
}

// timer_text is the timer unit that starts the entry's service on its schedule.
timer_text :: proc(e: Entry, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"[Unit]\nDescription=sonar: scan %s %s\n",
		escape_specifiers(e.target),
		describe(e.timing),
	)
	fmt.sbprintf(&b, "X-Sonar-Target=%s\nX-Sonar-Schedule=%s\n\n", e.target, describe(e.timing))
	fmt.sbprintf(&b, "[Timer]\nOnCalendar=%s\nPersistent=true\n", on_calendar(e.timing))
	if e.timing.every == .Hourly {
		fmt.sbprintf(&b, "RandomizedDelaySec=%s\n", HOURLY_SPREAD)
	}
	strings.write_string(&b, "\n[Install]\nWantedBy=timers.target\n")
	return strings.to_string(b)
}

/*
systemd_quote is arg as one word of a systemd command line: quoted when it holds
what would split or escape it, with '%' and '$' doubled so systemd expands
neither a specifier nor a variable in it.
*/
systemd_quote :: proc(arg: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	quote := arg == "" || strings.index_any(arg, " \t\n\"'\\;") >= 0
	if quote {
		strings.write_byte(&b, '"')
	}
	for c in transmute([]byte)arg {
		switch c {
		case '"', '\\':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case '\n':
			strings.write_string(&b, `\n`)
		case '\t':
			strings.write_string(&b, `\t`)
		case '%', '$':
			strings.write_byte(&b, c)
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, c)
		}
	}
	if quote {
		strings.write_byte(&b, '"')
	}
	return strings.to_string(b)
}

// escape_specifiers doubles each '%' in s, so systemd shows it as written
// rather than expanding a specifier in it.
escape_specifiers :: proc(s: string, allocator := context.temp_allocator) -> string {
	out, _ := strings.replace_all(s, "%", "%%", allocator)
	return out
}

// unit_value is the value of key= in a unit's text, or "" when it has none.
unit_value :: proc(text, key: string) -> string {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if len(line) > len(key) && line[len(key)] == '=' && strings.has_prefix(line, key) {
			return strings.trim_space(line[len(key) + 1:])
		}
	}
	return ""
}
