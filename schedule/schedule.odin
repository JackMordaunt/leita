/*
Package schedule hands sonar's scheduled scans to the operating system's scheduler
rather than keeping a process of its own running: a systemd timer on Linux, a Task
Scheduler task on Windows. Each entry runs `sonar <target> --keep` at its time with
whatever alert flags it was given; sonar only writes, lists and removes the entries.

Times are the local wall clock, as a person sets them. A run missed while the
machine was asleep or off runs once when it is next up, never once a slot.

What the entries say is made by pure procedures, so the tests read them on any
system: service_text and timer_text (systemd.odin), task_xml (task.odin), command.
What touches the system goes through a Host (host.odin), whose runner a test
replaces to record the commands rather than run them.
*/
package sonar_schedule

import "core:fmt"
import "core:strconv"
import "core:strings"

// PREFIX begins the name of every entry sonar makes, so it can tell its own.
PREFIX :: "sonar-"

// Exit codes of a kept scan, as an entry's last result reports them.
EXIT_OK     :: 0
EXIT_FAILED :: 1 // the scan or keeping it failed, or a webhook did not take the report
EXIT_ALERT  :: 3 // an alert fired, and no webhook was given to tell

// Frequency is how often an entry runs.
Frequency :: enum {
	Hourly,
	Daily,
	Weekly,
}

// Weekday is a day of the week, Monday first, as ISO 8601 has it.
Weekday :: enum {
	Monday,
	Tuesday,
	Wednesday,
	Thursday,
	Friday,
	Saturday,
	Sunday,
}

// Timing is when an entry runs: hour and minute on the local clock for a daily
// or weekly entry, and the weekday for a weekly one. An hourly entry runs on the
// hour.
Timing :: struct {
	every:   Frequency,
	hour:    int,
	minute:  int,
	weekday: Weekday,
}

// Entry is one scheduled scan.
Entry :: struct {
	name:   string, // safe to name a file, a unit or a task with: safe_name
	target: string,
	timing: Timing,
	// The flags the scan runs with besides --keep: --history, --alert-*, --webhook.
	flags:  []string,
	// Run as the system, not the user: /etc/systemd/system, or SYSTEM on Windows.
	system: bool,
}

// parse_clock reads "HH:MM" on the 24 hour clock.
parse_clock :: proc(s: string) -> (hour, minute: int, ok: bool) {
	colon := strings.index_byte(s, ':')
	if colon < 1 || len(s) - colon != 3 {
		return
	}
	hour = strconv.parse_int(s[:colon], 10) or_return
	minute = strconv.parse_int(s[colon + 1:], 10) or_return
	if hour < 0 || hour > 23 || minute < 0 || minute > 59 {
		return 0, 0, false
	}
	return hour, minute, true
}

// parse_weekday reads a day of the week by its English name or its first three
// letters, in any case.
parse_weekday :: proc(s: string) -> (day: Weekday, ok: bool) {
	lower := strings.to_lower(s, context.temp_allocator)
	for d in Weekday {
		name := strings.to_lower(fmt.tprint(d), context.temp_allocator)
		if lower == name || (len(lower) == 3 && strings.has_prefix(name, lower)) {
			return d, true
		}
	}
	return {}, false
}

// describe says when timing runs, as a person would: "daily at 03:00".
describe :: proc(timing: Timing, allocator := context.temp_allocator) -> string {
	switch timing.every {
	case .Hourly:
		return strings.clone("hourly", allocator)
	case .Daily:
		return fmt.aprintf("daily at %02d:%02d", timing.hour, timing.minute, allocator = allocator)
	case .Weekly:
		return fmt.aprintf(
			"weekly on %v at %02d:%02d",
			timing.weekday,
			timing.hour,
			timing.minute,
			allocator = allocator,
		)
	}
	return ""
}

/*
safe_name is s made fit to name a systemd unit, a file, and a task alike: lower
case letters, digits and '_' kept, every other run of characters made one '-',
none at either end, at most 64 bytes. "root" when nothing is left, as for "/".
*/
safe_name :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	dash := false
	for c in transmute([]byte)s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_':
			if dash && strings.builder_len(b) > 0 {
				strings.write_byte(&b, '-')
			}
			dash = false
			strings.write_byte(&b, c)
		case 'A' ..= 'Z':
			if dash && strings.builder_len(b) > 0 {
				strings.write_byte(&b, '-')
			}
			dash = false
			strings.write_byte(&b, c + ('a' - 'A'))
		case:
			dash = true
		}
		if strings.builder_len(b) >= 64 {
			break
		}
	}
	name := strings.trim_right(strings.to_string(b), "-")
	if name == "" {
		return strings.clone("root", allocator)
	}
	return name
}

// unit is the name an entry's units or task go by: PREFIX and its name.
unit :: proc(name: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({PREFIX, name}, allocator)
}

// command is the command line an entry runs: the sonar at exe, keeping a scan of
// the target with the entry's flags.
command :: proc(exe: string, e: Entry, allocator := context.temp_allocator) -> []string {
	argv := make([dynamic]string, allocator)
	append(&argv, exe, e.target, "--keep")
	append(&argv, ..e.flags)
	return argv[:]
}

// last_result says how a run that exited with code went.
last_result :: proc(code: int, allocator := context.temp_allocator) -> string {
	switch code {
	case EXIT_OK:
		return strings.clone("ok", allocator)
	case EXIT_ALERT:
		return strings.clone("alert fired", allocator)
	}
	return fmt.aprintf("failed (exit %d)", code, allocator = allocator)
}
