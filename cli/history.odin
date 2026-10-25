package leita_cli

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "jm:timefmt"

import "../changes"
import "../history"
import "../human"
import "../report"
import "../term"

/*
leita history: what leita deleted or changed on this disk at your request, newest
first, one line each: when, in your time zone, what, how much, and why it failed
when it did. The window's History is the same record. It is read from the store
the scans are kept in, which the window and the command line share.
*/

HISTORY_USAGE :: `leita history — what leita deleted or changed on disk at your request.

  leita history [PLACE]     the record, newest first, one line each: when, in your
                            time zone, what, how much, and "failed: why" if it did
                            not work; only what was under PLACE if one is named
  --since DATE              only from DATE on, YYYY-MM-DD, your time zone
  --json                    the record as a JSON array instead, times in UTC; the
                            members are in report/SCHEMA.md under leita.history/1

Exit codes: 0 the record was read, however short; 1 a bad flag, or a record that
could not be opened.
`

/*
History_Context is what leita history works with: the history store the record is
kept in.
*/
History_Context :: struct {
	kept: string,
}

// history_command_line runs leita history on this machine, writing the record on
// standard output, and returns the exit code.
history_command_line :: proc(args: []string) -> int {
	mode, _ := term.parse_mode(os.get_env("LEITA_COLOR", context.temp_allocator))
	set_style(mode)
	c := History_Context {
		kept = history.default_path(context.temp_allocator),
	}
	return history_dispatch(c, args, os.to_writer(os.stdout))
}

// History_Request is what leita history was asked for.
@(private = "file")
History_Request :: struct {
	place: string, // "" for anywhere
	since: i64, // Unix seconds; 0 for from the start
	json:  bool,
}

// history_dispatch carries out the leita history command args names, writing the
// record on w and what went wrong on standard error.
history_dispatch :: proc(c: History_Context, args: []string, w: io.Writer) -> int {
	if slice.contains(args, "-h") || slice.contains(args, "--help") {
		b := strings.builder_make(context.temp_allocator)
		term.write_usage(&b, style, "leita history", HISTORY_USAGE)
		fmt.wprint(w, strings.to_string(b))
		return EXIT_OK
	}
	asked, ok := ask_history(args)
	if !ok {
		return EXIT_ERROR
	}
	// The store makes its errors in the allocator it was opened in.
	context.allocator = context.temp_allocator
	st: history.Store
	if err := history.open(&st, c.kept); err != nil {
		say_error("cannot open the record at %s: %s", c.kept, history.describe(err))
		return EXIT_ERROR
	}
	defer history.close(&st)
	done, err := history.actions(&st, asked.since)
	if err != nil {
		say_error("cannot read the record at %s: %s", c.kept, history.describe(err))
		return EXIT_ERROR
	}
	if asked.place != "" {
		done = under(done, asked.place)
	}
	b := strings.builder_make(context.temp_allocator)
	switch {
	case asked.json:
		report.write_record_json(&b, done)
	case len(done) == 0:
		strings.write_string(&b, "nothing recorded\n")
	case:
		for a in done {
			write_action(&b, a)
		}
	}
	fmt.wprint(w, strings.to_string(b))
	return EXIT_OK
}

// ask_history reads args, saying on standard error what is wrong with them.
@(private = "file")
ask_history :: proc(args: []string) -> (asked: History_Request, ok: bool) {
	date := ""
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--json":
			asked.json = true
		case a == "--since" && i + 1 < len(args):
			i += 1
			date = args[i]
		case strings.has_prefix(a, "--since="):
			date = a[len("--since="):]
		case a == "--since":
			say_error("--since takes a date, YYYY-MM-DD")
			return {}, false
		case strings.has_prefix(a, "-") && a != "-":
			say_error("leita history has no flag %s", a)
			fmt.eprintln("leita history -h lists what it takes")
			return {}, false
		case asked.place != "":
			say_error("leita history takes one place, not %q and %q", asked.place, a)
			return {}, false
		case:
			asked.place = place_given(a)
		}
	}
	if date != "" {
		since, valid := since_date(date)
		if !valid {
			say_error("cannot read --since %q: a date such as 2026-10-17", date)
			return {}, false
		}
		asked.since = since
	}
	return asked, true
}

// place_given is place as the record names paths: whole, so a folder named from
// where you stand matches. A place that is gone is taken as it was written.
@(private = "file")
place_given :: proc(place: string) -> string {
	whole, err := filepath.abs(place, context.temp_allocator)
	return place if err != nil else whole
}

// since_date is the start of the day date names, YYYY-MM-DD, in the machine's time
// zone, in Unix seconds.
@(private)
since_date :: proc(date: string) -> (since: i64, ok: bool) {
	day := timefmt.parse(date, "%Y-%m-%d") or_return
	// parse reads the day as UTC. The zone's offset at that moment is not the one
	// at local midnight when the clock changed between the two, as it does on the
	// day a zone east of UTC changes it, so the offset is asked again at the
	// midnight the first guess gives.
	midnight := time.time_to_unix(day)
	guess := midnight - i64(timefmt.local_parts(day).offset)
	offset := timefmt.local_parts(time.unix(guess, 0)).offset
	return midnight - i64(offset), true
}

// under is the actions whose path is place or beneath it.
@(private = "file")
under :: proc(done: []history.Action, place: string) -> []history.Action {
	kept := make([dynamic]history.Action, context.temp_allocator)
	for a in done {
		if _, inside := changes.under(place, a.path); inside {
			append(&kept, a)
		}
	}
	return kept[:]
}

// write_action writes one line of the record: when, what, how much, and why it
// failed, two spaces apart. A path is as the reports show it, so a control
// character in a name does not reach the terminal.
@(private = "file")
write_action :: proc(b: ^strings.Builder, a: history.Action) {
	fmt.sbprintf(b, "%s  %s", local_iso(time.unix(a.taken, 0)), report.readable(a.path))
	if a.kind == .Rename && !a.failed {
		fmt.sbprintf(b, " (renamed to %s)", report.readable(a.detail))
	}
	fmt.sbprintf(b, "  %s", human.bytes(a.bytes))
	if a.failed {
		why := report.readable(a.detail)
		fmt.sbprintf(b, "  failed: %s" if why != "" else "  failed", why)
	}
	strings.write_byte(b, '\n')
}

// local_iso is t as ISO 8601 in the machine's time zone, to the second, with its
// offset from UTC: 2026-10-17T21:49:02+10:00.
@(private = "file")
local_iso :: proc(t: time.Time) -> string {
	at := timefmt.local(t, "%Y-%m-%dT%H:%M:%S", context.temp_allocator)
	zone := timefmt.local(t, "%z", context.temp_allocator)
	return strings.concatenate({at, zone[:3], ":", zone[3:]}, context.temp_allocator)
}
