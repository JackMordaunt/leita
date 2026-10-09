package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

import "jm:sqlite3"

import "history"
import "report"

// --version names the build and where it runs.
@(test)
the_version_says_which_estoile_this_is :: proc(t: ^testing.T) {
	line := version_line()
	want := fmt.tprintf(
		"estoile %s (%s/%s, built ",
		report.VERSION,
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
	)
	testing.expectf(t, strings.has_prefix(line, want), "%q does not start %q", line, want)
	testing.expect_value(t, len(line), len(want) + len("2026-10-09)"))
}

/*
The command line asked for a JSON report of a directory writes one that reads
back, counting what the directory holds:

	<root>/a.txt           100 bytes
	<root>/sub/b.mp4       5000 bytes
	<root>/sub/c,"d".txt   1 byte
*/
@(test)
a_report_of_a_directory_reads_back :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/estoile_report_cli", dir)
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory(fmt.tprintf("%s/sub", root)) == nil)
	write :: proc(t: ^testing.T, path: string, size: int) {
		body := make([]byte, size, context.temp_allocator)
		testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
	}
	write(t, fmt.tprintf("%s/a.txt", root), 100)
	write(t, fmt.tprintf("%s/sub/b.mp4", root), 5000)
	write(t, fmt.tprintf("%s/sub/c,\"d\".txt", root), 1)
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
	testing.expect_value(t, top["schema"].(json.String), "estoile.report/1")
	totals := top["totals"].(json.Object)
	testing.expect_value(t, totals["files"].(json.Integer), 3)
	testing.expect_value(t, totals["directories"].(json.Integer), 1)
	files := top["largest_files"].(json.Array)
	testing.expect_value(t, len(files), 3)
	testing.expect_value(
		t,
		files[0].(json.Object)["path"].(json.String),
		fmt.tprintf("%s/sub/b.mp4", root),
	)
	testing.expect(t, top["compared"].(json.Null) == nil, "no store, so no earlier scan")
	space := top["space"].(json.Object)
	testing.expect(t, space["free"].(json.Integer) <= space["total"].(json.Integer))
}

// A report named .pdf is a PDF, on the paper asked for.
@(test)
a_pdf_report_is_written_on_its_paper :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/estoile_report_pdf", dir)
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

// A directory under the temp folder for one test, empty, and its history store
// beside it rather than in it, so the store is not part of what is scanned.
@(private)
fresh :: proc(t: ^testing.T, name: string) -> (root, store: string) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root = fmt.tprintf("%s/%s", dir, name)
	store = fmt.tprintf("%s.history/history.db", root)
	os.remove_all(root)
	os.remove_all(filepath.dir(store))
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	return
}

@(private)
write_zeros :: proc(t: ^testing.T, path: string, size: int) {
	body := make([]byte, size, context.temp_allocator)
	testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
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
	root, store := fresh(t, "estoile_history_cli")
	defer os.remove_all(root)
	defer os.remove_all(filepath.dir(store))
	big := fmt.tprintf("%s/big.bin", root)
	write_zeros(t, big, 2 << 20)

	testing.expect_value(t, scan_and_say({target = root}, store), 0)
	testing.expect_value(t, snapshot_count(t, store), 1)

	write_zeros(t, big, 3 << 20)
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
	files := top["largest_files"].(json.Array)
	testing.expect_value(t, len(files), 1)
	if len(files) == 1 {
		f := files[0].(json.Object)
		testing.expect_value(t, f["bytes_before"].(json.Integer), 2 << 20)
		testing.expect_value(t, f["change"].(json.Integer), 1 << 20)
	}
}

// --no-history neither reads the store nor writes it.
@(test)
no_history_leaves_the_store_alone :: proc(t: ^testing.T) {
	root, store := fresh(t, "estoile_no_history_cli")
	defer os.remove_all(root)
	write_zeros(t, fmt.tprintf("%s/a.bin", root), 1 << 20)

	testing.expect_value(t, scan_and_say({target = root, no_history = true}, store), 0)
	testing.expect(t, !os.exists(store), "the store was made")
}

// A store another program holds locked for writing past history.BUSY_WAIT leaves
// the scan unkept, not failed.
@(test)
a_busy_store_leaves_the_scan_unkept :: proc(t: ^testing.T) {
	root, store := fresh(t, "estoile_busy_history_cli")
	defer os.remove_all(root)
	defer os.remove_all(filepath.dir(store))
	write_zeros(t, fmt.tprintf("%s/a.bin", root), 1 << 20)
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
	root, store := fresh(t, "estoile_wait_history_cli")
	defer os.remove_all(root)
	defer os.remove_all(filepath.dir(store))
	write_zeros(t, fmt.tprintf("%s/a.bin", root), 1 << 20)
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
