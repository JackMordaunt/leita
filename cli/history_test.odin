package leita_cli

import "core:fmt"
import jm_path "jm:path"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:timefmt"

import "../history"
import "../scan"

// A data folder for one test, and the history store in it, holding done.
@(private = "file")
seeded :: proc(t: ^testing.T, done: []history.Action) -> (dir, kept: string) {
	err: os.Error
	dir, err = jm_path.make_directory_temp("", "leita-history-cli-*", context.temp_allocator)
	testing.expect(t, err == nil)
	kept = fmt.tprintf("%s/data/history.db", dir)
	st: history.Store
	testing.expect(t, history.open(&st, kept) == nil)
	testing.expect(t, history.record(&st, done) == nil)
	history.close(&st)
	return dir, kept
}

// history_says runs leita history args, returning the exit code and what it
// wrote on standard output.
@(private = "file")
history_says :: proc(kept: string, args: ..string) -> (int, string) {
	stdio_shared()
	defer stdio_done()
	b := strings.builder_make(context.temp_allocator)
	code := history_dispatch({kept = kept}, args, strings.to_writer(&b))
	return code, strings.to_string(b)
}

// host_path is the path written with / as the host writes it: on Windows with
// \ and a drive, where PLACE is made whole by the drive it is on, so a place
// typed as /home/ann would be C:\home\ann and match nothing seeded without one.
@(private = "file")
host_path :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		whole, _ := strings.replace_all(path, "/", scan.SEPARATOR, context.temp_allocator)
		return strings.concatenate({"C:", whole}, context.temp_allocator)
	} else {
		return path
	}
}

// seed_actions are five actions at noon UTC on 2027-01-15 and each day after, so a date
// in any zone within twelve hours of UTC splits them the same way.
@(private = "file")
seed_actions :: proc() -> [5]history.Action {
	return {
		{1_800_014_400, .Trash, host_path("/home/ann/old.iso"), "", 4_000_000_000, false},
		{1_800_100_800, .Delete, host_path("/home/ann/app/node_modules"), "permission denied", 9_000_000, true},
		{1_800_187_200, .Rename, host_path("/home/ann/photos"), "pictures", 2_000_000, false},
		{1_800_273_600, .Empty_Trash, host_path("/home/ann/.Trash/bell\a\nname"), "", 12, false},
		{1_800_360_000, .Delete, host_path("/home/anna/cache"), "", 1_500, false},
	}
}

// The record is written newest first, a line to an action: when in local time with
// its offset, what, how much, and why when it failed. A control character in a
// name does not reach the terminal.
@(test)
the_record_is_printed_newest_first :: proc(t: ^testing.T) {
	done := seed_actions()
	dir, kept := seeded(t, done[:])
	defer os.remove_all(dir)

	code, said := history_says(kept)
	testing.expect_value(t, code, EXIT_OK)
	lines := strings.split_lines(strings.trim_right(said, "\n"), context.temp_allocator)
	testing.expect_value(t, len(lines), len(done))
	if len(lines) != len(done) {
		return
	}
	want := [?]string {
		strings.concatenate({"  ", host_path("/home/anna/cache"), "  1.5 kB"}, context.temp_allocator),
		strings.concatenate({"  ", host_path("/home/ann/.Trash/bell␇␊name"), "  12 B"}, context.temp_allocator),
		strings.concatenate({"  ", host_path("/home/ann/photos"), " (renamed to pictures)  2.0 MB"}, context.temp_allocator),
		strings.concatenate({"  ", host_path("/home/ann/app/node_modules"), "  9.0 MB  failed: permission denied"}, context.temp_allocator),
		strings.concatenate({"  ", host_path("/home/ann/old.iso"), "  4.0 GB"}, context.temp_allocator),
	}
	for line, i in lines {
		testing.expectf(t, strings.has_suffix(line, want[i]), "line %d is %q", i, line)
	}
	testing.expect(t, !strings.contains(said, "\a"), "no bell reaches the terminal")

	// Each time is the action's own, in the zone it is written with.
	for line, i in lines {
		testing.expect_value(t, taken_of(line), done[len(done) - 1 - i].taken)
	}
}

// taken_of reads back the time at the start of a line of the record,
// 2027-01-15T08:00:00+10:00, in Unix seconds, or -1 if it is not one.
@(private = "file")
taken_of :: proc(line: string) -> i64 {
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

@(test)
the_record_can_be_narrowed_by_place_and_date :: proc(t: ^testing.T) {
	done := seed_actions()
	dir, kept := seeded(t, done[:])
	defer os.remove_all(dir)

	ann := host_path("/home/ann")
	_, said := history_says(kept, ann)
	testing.expect_value(t, strings.count(said, "\n"), 4)
	testing.expect(t, !strings.contains(said, host_path("/home/anna")), "a sibling with the same start is not under it")
	_, said = history_says(kept, strings.concatenate({ann, scan.SEPARATOR}, context.temp_allocator))
	testing.expect_value(t, strings.count(said, "\n"), 4)
	_, said = history_says(kept, host_path("/home/ann/app/node_modules"))
	testing.expect_value(t, strings.count(said, "\n"), 1)
	testing.expect(t, strings.contains(said, "node_modules"), said)

	_, said = history_says(kept, "--since", "2027-01-17")
	testing.expect_value(t, strings.count(said, "\n"), 3)
	_, said = history_says(kept, "--since=2027-01-17", ann)
	testing.expect_value(t, strings.count(said, "\n"), 2)
	testing.expect(t, strings.contains(said, "photos") && !strings.contains(said, "anna"), said)
	_, said = history_says(kept, "--since", "2100-01-01")
	testing.expect_value(t, said, "nothing recorded\n")
}

// --json is the same record as an array, the report's way: times in UTC, every
// member there, a path that is not text kept whole beside its base64.
@(test)
the_record_can_be_written_as_json :: proc(t: ^testing.T) {
	done := [?]history.Action {
		{1_800_000_000, .Delete, "/home/ann/a \"b\"\n", "permission denied", 9, true},
		{1_800_000_100, .Trash, "/home/ann/\xff", "", 5, false},
	}
	dir, kept := seeded(t, done[:])
	defer os.remove_all(dir)

	code, said := history_says(kept, "--json")
	testing.expect_value(t, code, EXIT_OK)
	want := `[
  {"taken": "2027-01-15T08:01:40Z", "kind": "trash", "path": "/home/ann/\ufffd", "path_base64": "L2hvbWUvYW5uL/8=", "bytes": 5, "failed": false, "detail": null},
  {"taken": "2027-01-15T08:00:00Z", "kind": "delete", "path": "/home/ann/a \"b\"\n", "bytes": 9, "failed": true, "detail": "permission denied"}
]
`
	testing.expect_value(t, said, want)

	_, said = history_says(kept, "--json", "/nowhere")
	testing.expect_value(t, said, "[]\n")
}

// A store that cannot be opened is exit 1, and so is a flag that is not one.
@(test)
a_bad_store_or_flag_is_exit_1 :: proc(t: ^testing.T) {
	dir, kept := seeded(t, nil)
	defer os.remove_all(dir)

	// A folder where the store's file would be.
	blocked := fmt.tprintf("%s/folder.db", dir)
	testing.expect(t, os.make_directory(blocked) == nil)
	code, said := history_says(blocked)
	testing.expect_value(t, code, EXIT_ERROR)
	testing.expect_value(t, said, "")

	for args in ([][]string{{"--since", "yesterday"}, {"--since"}, {"--nope"}, {"/a", "/b"}}) {
		code, said = history_says(kept, ..args)
		testing.expectf(t, code == EXIT_ERROR, "%v", args)
	}
	code, said = history_says(kept)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect_value(t, said, "nothing recorded\n")
	code, said = history_says(kept, "-h")
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.has_prefix(said, "leita history"), said)
}

// Reading the existing audit trail remains available even when its store
// cannot accept a write. The --json stream stays machine-readable.
when ODIN_OS != .Windows {
	@(test)
	a_read_only_record_can_still_be_printed_as_json :: proc(t: ^testing.T) {
		if os.get_euid() == 0 {
			return // root bypasses the fixture's ordinary permission denial
		}
		done := seed_actions()
		dir, kept := seeded(t, done[:])
		defer os.remove_all(dir)
		data := fmt.tprintf("%s/data", dir)
		original := read_file(t, kept)
		testing.expect(t, os.change_mode(data, {.Read_User, .Execute_User}) == nil)
		defer os.change_mode(data, {.Read_User, .Write_User, .Execute_User})
		st: history.Store
		open_err := history.open(&st, kept)
		if !testing.expectf(t, open_err == nil, "%s", history.describe(open_err)) {
			return
		}
		testing.expect(t, st.read_only)
		history.close(&st)
		code, out := history_says(kept, "--json")
		testing.expect_value(t, code, EXIT_OK)
		testing.expect(t, strings.has_prefix(out, "[") && strings.contains(out, "old.iso"), out)
		testing.expect_value(t, read_file(t, kept), original)
	}
}
