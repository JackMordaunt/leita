package leita_cli

/*
The machine's time zone is read from TZ at each use, so a test that wants a zone
sets it for a process of its own: this same test binary run again with the case
named in its environment (ZONE_CASE). zone_serve notices that before the test
runner starts, runs the one case, prints what it says on standard output and
exits, so no other test sees the zone. The test reads that output back.

The zone is TZ on Linux and macOS (Odin's core:time/timezone, tz_unix.odin).
Its Windows reader takes the zone from the registry (tz_windows.odin) and not from
TZ, so the cases that need a named zone return at once there.
*/

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:timefmt"

import "../history"
import "../report"
import "../testtmp"

ZONE_CASE :: "LEITA_ZONE_CASE"
ZONE_ARG :: "LEITA_ZONE_ARG"

@(init)
zone_serve :: proc "contextless" () {
	context = runtime.default_context()
	name_buf, arg_buf: [4096]u8
	name := os.get_env(name_buf[:], ZONE_CASE)
	if name == "" {
		return
	}
	arg := os.get_env(arg_buf[:], ZONE_ARG)
	said := zone_case(name, arg)
	if said == "" {
		fmt.eprintfln("zone: no case %q", name)
		os.exit(71)
	}
	fmt.print(said)
	os.exit(0)
}

// zone_case runs the case name on arg and returns what it says, or "" for a case
// there is none of. A case that says nothing says "\n".
@(private = "file")
zone_case :: proc(name, arg: string) -> string {
	switch name {
	case "record":
		// arg is Unix seconds, comma apart: an action taken at each, the record as
		// leita history writes it.
		dir, _ := testtmp.make_dir("", "leita-zone-*", context.temp_allocator)
		defer os.remove_all(dir)

		kept := fmt.tprintf("%s/history.db", dir)
		done: [dynamic]history.Action
		for part in strings.split(arg, ",", context.temp_allocator) {
			at, _ := strconv.parse_i64(part)
			append(&done, history.Action{at, .Trash, "/home/ann/f", "", 1000, false})
		}

		st: history.Store
		if history.open(&st, kept) != nil || history.record(&st, done[:]) != nil {
			return "cannot seed\n"
		}
		history.close(&st)

		b := strings.builder_make(context.temp_allocator)
		history_dispatch({kept = kept}, nil, strings.to_writer(&b))
		return strings.to_string(b)
	case "since":
		// arg is a date: the Unix second --since reads it as.
		since, ok := since_date(arg)
		return fmt.tprintf("%d %v\n", since, ok)
	case "when":
		// arg is Unix seconds: the time a monitor's run is shown at.
		at, _ := strconv.parse_i64(arg)
		return fmt.tprintf("%s\n", monitor_when_(at))
	case "kept":
		// arg is Unix seconds: what a scan says of the last one, taken then.
		at, _ := strconv.parse_i64(arg)
		k := Kept {
			place    = "/home/ann",
			previous = report.Snapshot{time.unix(at, 0), nil},
			bytes    = 5000,
		}
		say_kept(k, 5000, false, true)
		return "\n"
	}
	return ""
}

// in_zone runs case on arg in a process whose zone is tz ("" leaves the host's)
// and whose locale is the environment kv sets, and returns what it printed.
@(private = "file")
in_zone :: proc(t: ^testing.T, tz, name, arg: string, locale: []string = nil) -> string {
	env := make([dynamic]string, context.temp_allocator)
	parent, _ := os.environ(context.temp_allocator)
	for kv in parent {
		key, _, _ := strings.partition(kv, "=")
		switch key {
		case "TZ", "LANG", "LANGUAGE", ZONE_CASE, ZONE_ARG:
			continue
		}
		if strings.has_prefix(key, "LC_") {
			continue
		}
		append(&env, kv)
	}

	if tz != "" {
		append(&env, fmt.tprintf("TZ=%s", tz))
	}
	append(&env, fmt.tprintf("%s=%s", ZONE_CASE, name), fmt.tprintf("%s=%s", ZONE_ARG, arg))
	append(&env, "ASAN_OPTIONS=detect_leaks=0")
	append(&env, ..locale)

	self, _ := os.get_executable_path(context.temp_allocator)
	state, out, err_out, err := os.process_exec(
		{command = {self}, env = env[:]},
		context.temp_allocator,
	)
	testing.expectf(t, err == nil, "cannot run the zone case: %v", err)
	testing.expectf(
		t,
		state.exit_code == 0,
		"zone case %s in %q: exit %d: %s",
		name,
		tz,
		state.exit_code,
		string(err_out),
	)
	return string(out)
}

// A zone as the record writes it: the instant, and the local time with its offset.
@(private = "file")
Moment :: struct {
	zone: string,
	at:   i64,
	iso:  string,
}

// MOMENTS are instants around changes of the clock, each with its local time as
// the zone database gives it (python's zoneinfo, 2026-10-25).
@(private = "file", rodata)
MOMENTS := [?]Moment {
	// London sets the clock back at 01:00 UTC: 01:30 happens twice.
	{"Europe/London", 1792888200, "2026-10-25T01:30:00+01:00"},
	{"Europe/London", 1792891800, "2026-10-25T01:30:00+00:00"},
	// ...and forward an hour later in the spring: 01:00 to 02:00 is missing.
	{"Europe/London", 1774745999, "2026-03-29T00:59:59+00:00"},
	// One second past each change into summer time: at the very second the zone
	// database's reader still gives the old offset (see the draft card).
	{"Europe/London", 1774746001, "2026-03-29T02:00:01+01:00"},
	{"America/New_York", 1772953199, "2026-03-08T01:59:59-05:00"},
	{"America/New_York", 1772953201, "2026-03-08T03:00:01-04:00"},
	{"America/New_York", 1793511000, "2026-11-01T01:30:00-04:00"},
	{"America/New_York", 1793514600, "2026-11-01T01:30:00-05:00"},
	// Lord Howe Island moves its clock half an hour: +11:00 and +10:30.
	{"Australia/Lord_Howe", 1775313900, "2026-04-05T01:45:00+11:00"},
	{"Australia/Lord_Howe", 1775315700, "2026-04-05T01:45:00+10:30"},
	{"Australia/Lord_Howe", 1791040500, "2026-10-04T01:45:00+10:30"},
	{"Australia/Lord_Howe", 1791042300, "2026-10-04T02:45:00+11:00"},
	// Far and odd offsets, no change of clock.
	{"Asia/Kolkata", 1800014400, "2027-01-15T17:30:00+05:30"},
	{"Asia/Kathmandu", 1800014400, "2027-01-15T17:45:00+05:45"},
	{"Pacific/Kiritimati", 1800014400, "2027-01-16T02:00:00+14:00"},
	{"Pacific/Pago_Pago", 1800014400, "2027-01-15T01:00:00-11:00"},
	{"UTC", 1800014400, "2027-01-15T12:00:00+00:00"},
}

// The record gives each action its own moment in the host's zone, with the offset
// that told the two 01:30s of a repeated hour apart, and lists them newest first
// as the instants fall, not as the clocks read.
@(test)
the_record_tells_the_repeated_hour_from_the_missing_one :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	zones := make([dynamic]string, context.temp_allocator)
	for m in MOMENTS {
		if !slice_has(zones[:], m.zone) {
			append(&zones, m.zone)
		}
	}
	for zone in zones {
		mine := make([dynamic]Moment, context.temp_allocator)
		ats := make([dynamic]string, context.temp_allocator)
		for m in MOMENTS {
			if m.zone == zone {
				append(&mine, m)
				append(&ats, fmt.tprintf("%d", m.at))
			}
		}
		// Kept oldest first, so the record, which goes by when each was kept,
		// lists them newest first.
		slice.sort_by(mine[:], proc(a, b: Moment) -> bool {return a.at > b.at})
		clear(&ats)
		#reverse for m in mine {
			append(&ats, fmt.tprintf("%d", m.at))
		}
		said := in_zone(t, zone, "record", strings.join(ats[:], ",", context.temp_allocator))
		lines := strings.split_lines(strings.trim_right(said, "\n"), context.temp_allocator)
		if !testing.expectf(t, len(lines) == len(mine), "%s: %q", zone, said) {
			continue
		}
		for m, i in mine {
			testing.expectf(t, strings.has_prefix(lines[i], m.iso), "%s line %d: %q, want %s", zone, i, lines[i], m.iso)
			testing.expect_value(t, taken_of_line(lines[i]), m.at)
		}
	}
}

@(private = "file")
slice_has :: proc(all: []string, one: string) -> bool {
	for s in all {
		if s == one {
			return true
		}
	}
	return false
}

// taken_of_line reads back the time a line of the record starts with,
// 2027-01-15T08:00:00+10:00, in Unix seconds, or -1 if it is not one.
@(private = "file")
taken_of_line :: proc(line: string) -> i64 {
	if len(line) < 25 || (line[19] != '+' && line[19] != '-') || line[22] != ':' {
		return -1
	}
	at, ok := timefmt.parse(line[:19], "%Y-%m-%dT%H:%M:%S")
	if !ok {
		return -1
	}
	hours, minutes := int(line[20] - '0') * 10 + int(line[21] - '0'), int(line[23] - '0') * 10 + int(line[24] - '0')
	offset := i64(hours * 3600 + minutes * 60)
	return time.time_to_unix(at) - (offset if line[19] == '+' else -offset)
}

// SINCE are the first second of a day in a zone, as --since DATE reads it. The
// day may have 23, 24 or 25 hours, or 23.5, and its midnight is where the zone's
// offset is just then, not where it was at midnight UTC.
@(private = "file", rodata)
SINCE := [?]struct {
	zone, date: string,
	start:      i64,
} {
	{"UTC", "2026-10-25", 1792886400},
	{"Australia/Sydney", "2026-10-04", 1791036000}, // forward at 02:00, after midnight
	{"Australia/Sydney", "2026-04-05", 1775307600}, // back at 03:00, after midnight
	{"Australia/Lord_Howe", "2026-10-04", 1791034200},
	{"Australia/Lord_Howe", "2026-04-05", 1775307600},
	{"Europe/London", "2026-10-25", 1792882800},
	{"Europe/London", "2026-03-29", 1774742400},
	{"Europe/Berlin", "2026-10-25", 1792879200},
	{"America/New_York", "2026-03-08", 1772946000},
	{"America/New_York", "2026-11-01", 1793505600},
	{"Pacific/Auckland", "2026-09-27", 1790424000},
	{"Asia/Kolkata", "2027-01-16", 1800037800},
	{"Asia/Kathmandu", "2027-01-16", 1800036900},
	{"Pacific/Kiritimati", "2027-01-16", 1800007200},
	{"Pacific/Pago_Pago", "2027-01-16", 1800097200},
}

// --since DATE is the start of that day in the machine's zone, on the days a clock
// changes too: a day that opens at midnight on the clock, not an hour into the
// last one or the next.
@(test)
since_a_date_starts_at_local_midnight_on_the_days_clocks_change :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	for s in SINCE {
		said := in_zone(t, s.zone, "since", s.date)
		want := fmt.tprintf("%d true\n", s.start)
		testing.expectf(t, said == want, "--since %s in %s: %q, want %q", s.date, s.zone, said, want)
	}
}

// The time of a run, and of the last scan a new one is compared with, are written
// on the local clock in every zone, the half-hour ones too.
@(test)
a_run_and_the_last_scan_are_shown_on_the_local_clock :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	for m in MOMENTS {
		want := fmt.tprintf("%s %s", m.iso[:10], m.iso[11:16])
		said := in_zone(t, m.zone, "when", fmt.tprintf("%d", m.at))
		testing.expectf(t, strings.trim_space(said) == want, "%s at %d: %q, want %q", m.zone, m.at, said, want)

		said = in_zone(t, m.zone, "kept", fmt.tprintf("%d", m.at))
		line := fmt.tprintf("unchanged since %s", want)
		testing.expectf(t, strings.contains(said, line), "%s at %d: %q lacks %q", m.zone, m.at, said, line)
	}
}

// Between two scans the person flies: the second scan is written in the new zone,
// and the first still says the same instant it was taken, in the new zone's words.
@(test)
a_change_of_zone_between_two_scans_moves_the_wording_not_the_instant :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	at := fmt.tprintf("%d", i64(1800014400))
	in_kolkata := in_zone(t, "Asia/Kolkata", "kept", at)
	in_pago := in_zone(t, "Pacific/Pago_Pago", "kept", at)
	testing.expect(t, strings.contains(in_kolkata, "unchanged since 2027-01-15 17:30"), in_kolkata)
	testing.expect(t, strings.contains(in_pago, "unchanged since 2027-01-15 01:00"), in_pago)
	// The same history record, read in each: the same instant at both ends.
	a := in_zone(t, "Asia/Kolkata", "record", at)
	b := in_zone(t, "Pacific/Pago_Pago", "record", at)
	testing.expect_value(t, taken_of_line(a), i64(1800014400))
	testing.expect_value(t, taken_of_line(b), i64(1800014400))
}
