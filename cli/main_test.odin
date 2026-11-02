package leita_cli

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import win "core:sys/windows"
import "core:testing"
import "core:thread"
import "core:time"

import "jm:sqlite3"

import "../changes"
import "../history"
import "../human"
import "../scan"
import "../term"
import "../version"

// The allocation oracle calls the platform API selected below.
_ :: posix
_ :: win

// --version names the build and where it runs.
@(test)
the_version_says_which_leita_this_is :: proc(t: ^testing.T) {
	line := version_line()
	want := fmt.tprintf(
		"leita %s (%s/%s, built ",
		version.VERSION,
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
	)
	testing.expectf(t, strings.has_prefix(line, want), "%q does not start %q", line, want)
	testing.expect_value(t, len(line), len(want) + len("2026-10-09)"))
}

// USAGE, written by hand, names every flag Options has, as --its-name, and
// the target as [TARGET]; a flag added to one without the other fails here.
@(test)
the_usage_names_every_flag :: proc(t: ^testing.T) {
	for name in reflect.struct_field_names(Options) {
		kebab, _ := strings.replace_all(name, "_", "-", context.temp_allocator)
		flag := fmt.tprintf("--%s ", kebab)
		if name == "target" {
			flag = "[TARGET]"
		}
		testing.expectf(t, strings.contains(USAGE, flag), "USAGE does not name %s", flag)
	}
}

// The usage's first line names the short name install puts beside leita, the
// one the build was given.
@(test)
the_usage_names_the_short_form :: proc(t: ^testing.T) {
	first, _, _ := strings.partition(USAGE, "\n")
	short := fmt.tprintf("(or %s)", version.SHORT)
	testing.expectf(t, strings.contains(first, short), "%q does not name %s", first, short)
}

// Styled, the usage carries weight; plain, it is USAGE byte for byte.
@(test)
the_usage_is_styled_only_for_a_person :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	term.write_usage(&b, {}, PROGRAM, USAGE)
	testing.expect_value(t, strings.to_string(b), USAGE)
	strings.builder_reset(&b)
	term.write_usage(&b, {depth = .Three_Bit}, PROGRAM, USAGE)
	styled := strings.to_string(b)
	testing.expect(t, strings.contains(styled, "\x1b[1mScan\x1b[0m"), "headings are bold")
	testing.expect(t, strings.contains(styled, "\x1b[1m--report\x1b[0m"), "flags are bold")
}

// --color is found before the flags are parsed, in either form, so it
// governs -h and a bad flag too; the last one given wins.
@(test)
color_is_read_before_the_flags :: proc(t: ^testing.T) {
	word, given := find_color({"--top", "3", "--color=never", "-h"})
	testing.expect(t, given && word == "never", "--color=WORD")
	word, given = find_color({"--color", "always", "--color=auto"})
	testing.expect(t, given && word == "auto", "--color WORD, the last wins")
	_, given = find_color({"--top", "3", "--color"})
	testing.expect(t, !given, "--color with no word is left to the parser")
}

/*
The command line asked for a JSON report of a directory writes one that reads
back, counting what the directory holds:

	<root>/a.txt           2000 bytes
	<root>/sub/b.mp4       5000 bytes
	<root>/sub/QUOTED_NAME 1500 bytes

Each large enough to need a cluster of its own on NTFS. A file small enough to be
stored in its MFT record is charged nothing on Windows, as the MFT reader charges it,
and a file charged nothing is not among the largest files.
*/
@(test)
a_report_of_a_directory_reads_back :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	// A quote in a file name forces CSV quoting the way a comma does; this
	// fixture differs by OS so the file can be created on every one of
	// them, and the quote itself, doubled inside a quoted field, has its
	// own test: QUOTED in report/report_test.odin.
	QUOTED_NAME :: "c,\"d\".txt" when ODIN_OS != .Windows else "c,d.txt"

	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	// Where the fixture is made. The comparison below uses the path
	// scan.resolve stores for this directory, the name the report writes.
	info, stat_err := os.stat(dir, context.temp_allocator)
	testing.expect(t, stat_err == nil, "the temp directory is not there")
	dir = strings.trim_right(info.fullpath, `/\`)
	root := fmt.tprintf("%s%sleita_report_cli_%d", dir, scan.SEPARATOR, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory(fmt.tprintf("%s/sub", root)) == nil)
	write_payload(t, fmt.tprintf("%s/a.txt", root), 2000)
	write_payload(t, fmt.tprintf("%s/sub/b.mp4", root), 5000)
	write_payload(t, fmt.tprintf("%s/sub/%s", root, QUOTED_NAME), 1500)
	out := fmt.tprintf("%s.json", root)
	defer os.remove(out)

	testing.expect_value(t, scan_and_say({target = root, report = out}), 0)

	data, read_err := os.read_entire_file(out, context.temp_allocator)
	testing.expect(t, read_err == nil, "no report written")
	v, err := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	top, is_object := v.(json.Object)
	testing.expect(t, is_object, "a report is one object")
	if !is_object {
		return
	}
	schema, schema_string := top["schema"].(json.String)
	totals, totals_object := top["totals"].(json.Object)
	if !testing.expect(
		t,
		schema_string && totals_object,
		"schema and totals have their documented types",
	) {return}
	testing.expect_value(t, schema, "leita.report/1")
	file_count, file_integer := totals["files"].(json.Integer)
	directory_count, directory_integer := totals["directories"].(json.Integer)
	total_bytes, total_integer := totals["bytes"].(json.Integer)
	if !testing.expect(
		t,
		file_integer && directory_integer && total_integer,
		"totals are integer counts",
	) {return}
	testing.expect_value(t, file_count, 3)
	testing.expect_value(t, directory_count, 1)
	files, files_array := top["largest_files"].(json.Array)
	if !testing.expect(t, files_array, "largest_files is an array") {return}
	testing.expect_value(t, len(files), 3)
	// The report joins names under the target as scan.resolve spells it, with
	// the platform separator. That spelling is what the assertion compares.
	named, _, name_err := scan.resolve(root)
	testing.expect_value(t, name_err, scan.Error.None)
	defer scan.target_destroy(&named)
	canonical := root
	if name_err == nil {
		canonical = scan.location(named, context.temp_allocator)
	}
	allocations := make(map[string]i64)
	for c in ([]struct {
			path:  string,
			bytes: i64,
		}{{fmt.tprintf("%s%sa.txt", canonical, scan.SEPARATOR), fixture_allocation(t, fmt.tprintf("%s/a.txt", root))}, {fmt.tprintf("%s%ssub%sb.mp4", canonical, scan.SEPARATOR, scan.SEPARATOR), fixture_allocation(t, fmt.tprintf("%s/sub/b.mp4", root))}, {fmt.tprintf("%s%ssub%s%s", canonical, scan.SEPARATOR, scan.SEPARATOR, QUOTED_NAME), fixture_allocation(t, fmt.tprintf("%s/sub/%s", root, QUOTED_NAME))}}) {
		allocations[c.path] = c.bytes
	}
	defer delete(allocations)
	previous: i64 = max(i64)
	charged: i64
	for value in files {
		entry, entry_ok := value.(json.Object)
		if !testing.expect(t, entry_ok, "a file entry is an object") {return}
		path, path_ok := entry["path"].(json.String)
		bytes, bytes_ok := entry["bytes"].(json.Integer)
		if !testing.expect(
			t,
			path_ok && bytes_ok,
			"a file carries its path and allocation",
		) {return}
		want, found := allocations[path]
		testing.expect(t, found, "the report named a fixture file")
		testing.expect_value(t, bytes, want)
		testing.expect(t, bytes <= previous, "largest files are sorted by allocation")
		previous = bytes
		charged += bytes
		delete_key(&allocations, path)
	}
	testing.expect_value(t, len(allocations), 0)
	testing.expect_value(t, total_bytes, charged)
	_, compared_null := top["compared"].(json.Null)
	testing.expect(t, compared_null, "no store, so no earlier scan")
	space, space_object := top["space"].(json.Object)
	if !testing.expect(t, space_object, "the disk it is on was measured") {return}
	capacity, capacity_integer := space["total"].(json.Integer)
	free, free_integer := space["free"].(json.Integer)
	if !testing.expect(
		t,
		capacity_integer && free_integer,
		"capacity is measured in integer bytes",
	) {return}
	testing.expect(t, capacity > 0, "the disk it is on was measured")
	testing.expect(t, free <= capacity)
}

// A report named .pdf is a PDF, on the paper asked for.
@(test)
a_pdf_report_is_written_on_its_paper :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_report_pdf_%d", dir, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a.txt", root), "hello") == nil)
	out := fmt.tprintf("%s.pdf", root)
	defer os.remove(out)

	testing.expect_value(t, scan_and_say({target = root, report = out, paper = "letter"}), 0)
	data, read_err := os.read_entire_file(out, context.temp_allocator)
	testing.expect(t, read_err == nil, "no report written")
	text := string(data)
	testing.expect(t, strings.has_prefix(text, "%PDF-"), "it is a PDF")
	testing.expect(t, strings.contains(text, "/MediaBox [0 0 612 792]"), "on Letter")
}

// A report the command line cannot write is refused before anything is read.
@(test)
a_report_it_cannot_write_is_refused :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	cases := [?]Options {
		{report = "out.pdf", paper = "a5"},
		{report = "out.csv", paper = "a4"},
		{report = "out.txt"},
		{report = "-"},
		{report = "out.json", format = "xml"},
		{format = "csv"},
		{top = 10},
		{report = "out.json", live = true},
	}
	for c in cases {
		testing.expectf(t, scan_and_say(c) == 1, "%v was not refused", c)
	}
}

// A threshold flag that cannot be read is refused before anything is scanned.
@(test)
a_bad_threshold_flag_is_refused :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	cases := [?]Options {
		{min_free = "big"},
		{warn_used = 101},
		{warn_used = -1},
		{fail_used = 101},
		{fail_used = -1},
	}
	for c in cases {
		testing.expectf(t, scan_and_say(c) == EXIT_ERROR, "%v was not refused", c)
	}
}

/*
With no threshold flag given, a plain scan exits 0 as it always did, whether
or not this engine knows the volume's space. The report it writes still names
what was actually found (a real file's bytes, not a stub's zero value), and
its "thresholds" member stays null, since none was asked for.
*/
@(test)
no_threshold_flags_leaves_the_exit_code_unchanged :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_threshold_unconfigured_%d", dir, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	write_payload(t, fmt.tprintf("%s/a.bin", root), 4096)
	out := fmt.tprintf("%s.json", root)
	defer os.remove(out)

	testing.expect_value(
		t,
		scan_and_say({target = root, report = out, no_history = true}),
		EXIT_OK,
	)

	data, read_err := os.read_entire_file(out, context.temp_allocator)
	testing.expect(t, read_err == nil, "no report written")
	v, err := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	top, is_object := v.(json.Object)
	testing.expect(t, is_object, "a report is one object")
	if !is_object {
		return
	}
	allocated := fixture_allocation(t, fmt.tprintf("%s/a.bin", root))
	testing.expect(t, allocated > 0, "the written fixture occupies disk space")
	totals, totals_object := top["totals"].(json.Object)
	if !testing.expect(t, totals_object, "the report has totals") {return}
	bytes, bytes_integer := totals["bytes"].(json.Integer)
	if !testing.expect(t, bytes_integer, "charged bytes are an integer") {return}
	testing.expect_value(t, bytes, allocated)
	_, thresholds_null := top["thresholds"].(json.Null)
	testing.expect(t, thresholds_null, "none was asked for")
}

/*
A full LEITA_SYNTHETIC scan (--warn-used, --fail-used and --min-free read the
volume's space synth.space makes up) is deliberately not exercised here as an
automated test: a manual run (card 40's log has the session, including the
built binary's command and output, and the reproduction below) took on the
order of 10s to scan the made-up disk to completion. Running it beside this
suite's real scans once mixed the two, one scan's paths prefixed by the other's;
that was LEITA_SYNTHETIC being read from the process's environment on every
resolve, so a real scan resolved while it was set read the made-up disk (card 81).
The day is now passed to scan.resolve, and survey's
a_made_up_scan_and_a_real_one_do_not_mix runs the two side by side.

The pipeline from --warn-used/--fail-used/--min-free down to the exit code and
the JSON "thresholds" member was checked by hand against the built binary
instead (same card 40 log): LEITA_SYNTHETIC=350 with --warn-used 80
--fail-used 95 --min-free 50GiB --report - --format json exited 3 and wrote a
"thresholds" object with verdict "fail" and all three reasons. Everything
below that line in the pipeline (report.build's wiring from Options into
Report.thresholds, and write_json's rendering of it) is exercised without any
scan by json_carries_the_threshold_verdict in report/report_test.odin, which
builds a Report by hand.
*/

// exit_code is what a script reads, read_me the way report.threshold_of's own
// cases are checked (report/report_test.odin): no scan needed for this part.
@(test)
exit_code_reads_a_verdict_back :: proc(t: ^testing.T) {
	testing.expect_value(t, exit_code(.Ok), EXIT_OK)
	testing.expect_value(t, exit_code(.Warn), EXIT_WARN)
	testing.expect_value(t, exit_code(.Fail), EXIT_FAIL)
}

// A directory under the temp folder for one test, empty, and its history store
// beside it rather than in it, so the store is not part of what is scanned.
// The name carries this process's id so two test runs do not share the path.
@(private)
fresh :: proc(t: ^testing.T, name: string) -> (root, store: string) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root = fmt.tprintf("%s/%s_%d", dir, name, os.get_pid())
	store = fmt.tprintf("%s.history/history.db", root)
	os.remove_all(root)
	os.remove_all(filepath.dir(store))
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	return
}

// keeps_events says whether root's volume keeps a change history, which a baseline
// needs; changes.now names a network share and a read-only image as volumes without
// one. A volume without one fails the test with that reason.
@(private)
keeps_events :: proc(t: ^testing.T, root: string) -> bool {
	_, ok := changes.now(root)
	return testing.expect(t, ok, "no cursor: the temp directory's volume keeps no change history")
}

@(private)
write_payload :: proc(t: ^testing.T, path: string, size: int) {
	body := make([]byte, size, context.temp_allocator)
	// Xorshift64 has no short repeated block for filesystem compression to fold.
	// A zero-filled 2 MiB file on ZFS can occupy 512 bytes, below history's floor.
	state: u64 = 0x4d595df4d0f33173
	for &byte in body {
		state ~= state << 13
		state ~= state >> 7
		state ~= state << 17
		byte = u8(state)
	}
	file, err := os.open(path, {.Write, .Create, .Trunc})
	if !testing.expectf(t, err == nil, "could not open %s: %v", path, err) {return}
	defer os.close(file)
	n, write_err := os.write(file, body)
	testing.expectf(
		t,
		write_err == nil && n == len(body),
		"could not write %s: %v",
		path,
		write_err,
	)
	if size > 0 {
		// Finish delayed compression/allocation before measuring the fixture.
		testing.expect_value(t, os.sync(file), nil)
	}
}

// Allocation is measured independently of the scan so compression and filesystem
// block rounding are not confused with the file's logical length.
@(private)
fixture_allocation :: proc(t: ^testing.T, path: string) -> i64 {
	when ODIN_OS == .Windows {
		wide := win.utf8_to_utf16(path, context.temp_allocator)
		handle := win.CreateFileW(
			win.wstring(raw_data(wide)),
			win.FILE_READ_ATTRIBUTES,
			win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
			nil,
			win.OPEN_EXISTING,
			0,
			nil,
		)
		if !testing.expect(
			t,
			handle != win.INVALID_HANDLE_VALUE,
			"cannot measure fixture allocation",
		) {return -1}
		defer win.CloseHandle(handle)
		info: win.FILE_STANDARD_INFO
		if !testing.expect(
			t,
			bool(
				win.GetFileInformationByHandleEx(handle, .FileStandardInfo, &info, size_of(info)),
			),
		) {return -1}
		return i64(info.AllocationSize)
	} else {
		info: posix.stat_t
		if !testing.expect(
			t,
			posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &info) == .OK,
		) {return -1}
		return i64(info.st_blocks) * 512
	}
}

// snapshot_count is how many scans the store at path keeps, of every place.
@(private)
snapshot_count :: proc(t: ^testing.T, path: string) -> i64 {
	st: history.Store
	if err := history.open(&st, path); err != nil {
		testing.expectf(t, false, "could not open %s: %v", path, err)
		return -1
	}
	defer history.close(&st)
	rows, err := sqlite3.query(
		st.db,
		"SELECT COUNT(*) FROM snapshot",
		allocator = context.temp_allocator,
	)
	testing.expect(t, err == nil)
	n: i64 = -1
	for sqlite3.next(&rows) {
		n = sqlite3.integer(rows, 0)
	}
	_ = sqlite3.finish(&rows)
	return n
}

// Each scan the command line finishes is kept, and a report of the next carries
// what changed since.
@(test)
a_second_scan_reports_what_changed :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	root, store := fresh(t, "leita_history_cli")
	defer os.remove_all(root)
	defer os.remove_all(filepath.dir(store))
	big := fmt.tprintf("%s/big.bin", root)
	write_payload(t, big, 2 << 20)
	before := fixture_allocation(t, big)
	if !testing.expect(
		t,
		before >= 1 << 20,
		"the first file meets history's retained-entry floor",
	) {return}

	testing.expect_value(t, scan_and_say({target = root}, store), 0)
	testing.expect_value(t, snapshot_count(t, store), 1)

	write_payload(t, big, 3 << 20)
	after := fixture_allocation(t, big)
	if !testing.expect(t, after > before, "the fixture grew on disk") {return}
	out := fmt.tprintf("%s.json", root)
	defer os.remove(out)
	testing.expect_value(t, scan_and_say({target = root, report = out}, store), 0)
	testing.expect_value(t, snapshot_count(t, store), 2)

	data, read_err := os.read_entire_file(out, context.temp_allocator)
	testing.expect(t, read_err == nil, "no report written")
	v, _ := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	top, is_object := v.(json.Object)
	testing.expect(t, is_object, "a report is one object")
	if !is_object {
		return
	}
	_, compared := top["compared"].(json.Object)
	testing.expect(t, compared, "the second scan is compared with the first")
	files, files_array := top["largest_files"].(json.Array)
	if !testing.expect(t, files_array, "largest_files is an array") {return}
	testing.expect_value(t, len(files), 1)
	if len(files) == 1 {
		f, file_object := files[0].(json.Object)
		if !testing.expect(t, file_object, "a reported file is an object") {return}
		was, was_integer := f["bytes_before"].(json.Integer)
		change, change_integer := f["change"].(json.Integer)
		if !testing.expect(
			t,
			was_integer && change_integer,
			"a retained file has integer history and change",
		) {return}
		testing.expect_value(t, was, before)
		testing.expect_value(t, change, after - before)
	}
}

// --no-history neither reads the store nor writes it, though the store is given, as
// run gives it whatever the flags.
@(test)
no_history_leaves_the_store_alone :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	root, store := fresh(t, "leita_no_history_cli")
	defer os.remove_all(root)
	write_payload(t, fmt.tprintf("%s/a.bin", root), 1 << 20)

	testing.expect_value(t, scan_and_say({target = root, no_history = true}, store), 0)
	testing.expect(t, !os.exists(store), "the store was made")
	testing.expect(t, !os.exists(filepath.dir(store)), "a baseline was kept")
}

// With history on, a scan keeps the place's whole tree beside the store, where the
// window and the monitor find it, whole or not; the next scan updates from it.
// Reusable baselines require one of these platforms' change cursors.
when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .Windows {
	@(test)
	a_scan_keeps_a_baseline_beside_the_store :: proc(t: ^testing.T) {
		stdio_shared()
		defer stdio_done()
		root, store := fresh(t, "leita_baseline_cli")
		defer os.remove_all(root)
		defer os.remove_all(filepath.dir(store))
		write_payload(t, fmt.tprintf("%s/a.bin", root), 1 << 20)
		target, _, err := scan.resolve(root)
		testing.expect_value(t, err, scan.Error.None)
		defer scan.target_destroy(&target)
		baseline := history.baseline_path(
			store,
			scan.location(target, context.temp_allocator),
			context.temp_allocator,
		)
		if !keeps_events(t, root) {
			return
		}

		testing.expect_value(t, scan_and_say({target = root, whole = true}, store), 0)
		testing.expectf(t, os.exists(baseline), "no baseline at %s", baseline)
		testing.expect(t, os.remove(baseline) == nil, "could not remove the baseline")
		testing.expect_value(t, scan_and_say({target = root}, store), 0)
		testing.expectf(t, os.exists(baseline), "no baseline at %s", baseline)
		testing.expect_value(t, scan_and_say({target = root}, store), 0)
		testing.expect_value(t, snapshot_count(t, store), 3)
	}
}

/*
A live scan with history on keeps the baseline too, though its draw loop frees the
temp allocator every frame while the reader still reads the place and then writes the
baseline. A baseline path in the temp allocator was written over by the next frame's
line, and the baseline renamed to wherever that line's bytes pointed. To show that, the
place takes several frames to read at the gentle pace (50,000 files, 4 frames on an M1
Pro), the line spells a path longer than what the scan put in the temp allocator before
the baseline's, and that allocator is as empty when the scan begins as the binary's is.
Its draw loop frees this test's temp allocator too, so what the test reads after is in
the heap. Without the fix it failed 4 runs in 4 (2026-10-13).
*/
// Reusable baselines require one of these platforms' change cursors.
when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .Windows {
	@(test)
	a_live_scan_keeps_a_baseline_beside_the_store :: proc(t: ^testing.T) {
		stdio_shared()
		defer stdio_done()
		root, store := fresh(t, "leita_live_baseline_cli")
		root = strings.clone(root)
		defer delete(root)
		store = strings.clone(store)
		defer delete(store)
		defer os.remove_all(root)
		defer os.remove_all(filepath.dir(store))
		defer remove_deep(root)
		if !keeps_events(t, root) {
			return
		}
		for d in 0 ..< 50 {
			dir := fmt.tprintf("%s/d%02d", root, d)
			testing.expect(t, os.make_directory(dir) == nil, "could not make a directory")
			for i in 0 ..< 1000 {
				write_payload(t, fmt.tprintf("%s/f%04d", dir, i), 0)
			}
		}
		// The largest thing, whose path each frame's line spells, deep and long enough
		// to reach past where the scan put the baseline's path.
		for depth in 1 ..= DEPTH {
			made := os.make_directory(long(deep(root, depth)))
			testing.expect(t, made == nil, "could not make a deep directory")
		}
		write_payload(t, long(fmt.tprintf("%s/big.bin", deep(root, DEPTH))), 1 << 20)
		target, _, err := scan.resolve(root)
		testing.expect_value(t, err, scan.Error.None)
		defer scan.target_destroy(&target)
		baseline := history.baseline_path(store, scan.location(target, context.temp_allocator))
		defer delete(baseline)

		free_all(context.temp_allocator)
		live := Options {
			target = root,
			live   = true,
			whole  = true,
			gentle = true,
		}
		testing.expect_value(t, scan_and_say(live, store), 0)
		testing.expectf(t, os.exists(baseline), "no baseline at %s", baseline)
	}
}

// How many directories of 200 characters a_live_scan_keeps_a_baseline_beside_the_store
// nests its largest file under.
@(private)
DEPTH :: 4

// The directory `depth` levels down that chain under root.
@(private)
deep :: proc(root: string, depth: int) -> string {
	path := root
	for _ in 0 ..< depth {
		path = fmt.tprintf("%s/%s", path, strings.repeat("x", 200, context.temp_allocator))
	}
	return path
}

// The chain of deep directories and its file, innermost first, by their long form:
// on Windows os.remove_all hands the tree to SHFileOperationW (core/os/path_windows.odin,
// _remove_all), which takes no \\?\ path and so none past 260 characters.
@(private)
remove_deep :: proc(root: string) {
	os.remove(long(fmt.tprintf("%s/big.bin", deep(root, DEPTH))))
	for depth := DEPTH; depth > 0; depth -= 1 {
		os.remove(long(deep(root, depth)))
	}
}

// `path` as Windows takes one past 260 characters: with the \\?\ prefix, which also
// stops Windows rewriting it, so every separator must be a backslash. Other systems
// have no such limit.
@(private)
long :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		slashed, _ := strings.replace_all(path, "/", `\`, context.temp_allocator)
		return fmt.tprintf(`\\?\%s`, slashed)
	} else {
		return path
	}
}

// A store another program holds locked for writing past history.BUSY_WAIT leaves
// the scan unkept, not failed.
@(test)
a_busy_store_leaves_the_scan_unkept :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	root, store := fresh(t, "leita_busy_history_cli")
	defer os.remove_all(root)
	defer os.remove_all(filepath.dir(store))
	write_payload(t, fmt.tprintf("%s/a.bin", root), 1 << 20)
	testing.expect_value(t, scan_and_say({target = root}, store), 0)

	other: history.Store
	testing.expect(t, history.open(&other, store) == nil)
	defer history.close(&other)
	testing.expect(t, sqlite3.exec(other.db, "BEGIN EXCLUSIVE") == nil)
	testing.expect_value(t, scan_and_say({target = root}, store), 0)
	testing.expect(t, sqlite3.exec(other.db, "ROLLBACK") == nil)
	testing.expect_value(t, snapshot_count(t, store), 1)
}

// A store another program writes to for less than history.BUSY_WAIT is waited
// for, and the scan kept once it is done, as when the window keeps a scan while
// the command line keeps its own.
@(test)
a_store_written_briefly_elsewhere_is_waited_for :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	root, store := fresh(t, "leita_wait_history_cli")
	defer os.remove_all(root)
	defer os.remove_all(filepath.dir(store))
	write_payload(t, fmt.tprintf("%s/a.bin", root), 1 << 20)
	testing.expect_value(t, scan_and_say({target = root}, store), 0)

	other: history.Store
	testing.expect(t, history.open(&other, store) == nil)
	defer history.close(&other)
	testing.expect(t, sqlite3.exec(other.db, "BEGIN EXCLUSIVE") == nil)
	release :: proc(other: ^history.Store) {
		time.sleep(200 * time.Millisecond)
		_ = sqlite3.exec(other.db, "COMMIT")
	}
	th := thread.create_and_start_with_poly_data(&other, release)
	testing.expect_value(t, scan_and_say({target = root}, store), 0)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, snapshot_count(t, store), 2)
}

// HOSTILE is a name that tries a terminal and what reads its output: an OSC 52
// write to the clipboard, a CSI colour, a line break, a right-to-left override,
// markup and, first, a formula. HOSTILE_SHOWN is what the terminal is given.
HOSTILE       :: "=\x1b]52;c;ZXZpbA==\x07\x1b[31m\nname\u202e<img src=x>"
HOSTILE_SHOWN :: "=\u241b]52;c;ZXZpbA==\u2407\u241b[31m\u240aname\uFFFD<img src=x>"

// say_line is a line of standard error, and a name in it is shown without its controls.
@(test)
an_error_or_note_names_a_file_without_its_controls :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	for prefix in ([?]string{"error:", "note:"}) {
		line := say_line(prefix, "cannot read %s: %v", HOSTILE, "denied")
		want := fmt.tprintf("%s cannot read %s: denied", prefix, HOSTILE_SHOWN)
		testing.expect_value(t, line, want)
	}
}

// The summary's first line and its lists of largest files and directories name
// what is on the disk; a name holding an escape sequence is shown as pictures, so
// nothing in it runs in the terminal or starts a line of its own.
@(test)
the_summary_shows_a_hostile_name_without_its_controls :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	root, _ := fresh(t, "leita_hostile_cli")
	defer os.remove_all(root)
	testing.expect(
		t,
		os.make_directory(fmt.tprintf("%s/%s", root, HOSTILE)) == nil,
		"could not make the hostile directory",
	)
	// What the filesystem stored is what the scan prints, which is not always the
	// name given (a filesystem may normalise it), so the expectations are made from it.
	entries, read_err := os.read_all_directory_by_path(root, context.temp_allocator)
	if !testing.expect(
		t,
		read_err == nil && len(entries) == 1,
		"the hostile directory is not listed",
	) {
		return
	}
	stored := entries[0].name
	if stored != HOSTILE {
		log.infof("this filesystem stored the hostile name as %q", stored)
	}
	dir := fmt.tprintf("%s/%s", root, stored)
	write_payload(t, fmt.tprintf("%s/%s", dir, stored), 1 << 20)
	// The scan names the directory by its resolved path, which can differ from the
	// temp directory's own spelling when that is reached through a symbolic link.
	info, stat_err := os.stat(dir, context.temp_allocator)
	if !testing.expect(t, stat_err == nil, "the hostile directory is not there") {
		return
	}
	shown_dir := human.shown(info.fullpath)
	shown_name := human.shown(stored)

	out, code := capture_stdout(t, {target = dir, no_history = true})
	defer delete(out)
	testing.expect_value(t, code, 0)
	testing.expect(
		t,
		!strings.contains_any(out, "\x1b\x07"),
		"the summary carries an escape or a bell",
	)
	testing.expect(t, !strings.contains(out, "\u202e"), "the summary carries a bidi override")
	// The directory heads the summary and begins the file's path, which ends in
	// the file's own name: three times the name, each on the line it began.
	testing.expect_value(t, strings.count(out, shown_name), 3)
	testing.expect_value(t, strings.count(out, shown_dir), 2)
	testing.expect(t, strings.contains(out, "<img src=x>"), "the name was not kept")
	for line in strings.split_lines(out, context.temp_allocator) {
		if strings.contains(line, "<img") {
			testing.expect(t, strings.contains(line, shown_name), line)
		}
	}
}

// capture_stdout runs a scan and returns what it printed on standard output and its
// exit code, by pointing os.stdout at a file for the run. The file's text is in the
// heap, for the caller to delete.
@(private)
capture_stdout :: proc(t: ^testing.T, opt: Options, kept := "") -> (out: string, code: int) {
	sync.rw_mutex_lock(&stdio_rw)
	defer sync.rw_mutex_unlock(&stdio_rw)
	dir, _ := os.temp_directory(context.temp_allocator)
	path := fmt.tprintf("%s/leita_hostile_stdout_%d", dir, os.get_pid())
	defer os.remove(path)
	file, err := os.create(path)
	if !testing.expect(t, err == nil, "could not make a file to capture standard output") {
		return
	}
	saved := os.stdout
	os.stdout = file
	code = scan_and_say(opt, kept)
	os.stdout = saved
	os.close(file)
	data, read_err := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_err == nil, "could not read the captured output")
	return string(data), code
}
