package leita_cli

import "core:fmt"
import jm_path "jm:path"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import "../history"
import "../report"

/*
Once the 30-day Pro evaluation is over and no licence is in use, a scan, a
CSV or JSON of that scan, Reclaim's candidates and the deletion log still
work. PDF and HTML are refused, and an earlier scan is kept but not compared.
The program does not ask whether the person is an organisation: this no-licence
path is Free for everyone.
*/

@(test)
a_scan_is_free_after_the_trial :: proc(t: ^testing.T) {
	root := scratch(t, "scan")
	defer os.remove_all(root)
	code, _, err := capture(t, {target = root}, "", true)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, !strings.contains(err, "needs a licence"), err)
}

@(test)
csv_and_json_of_the_current_scan_are_free_after_the_trial :: proc(t: ^testing.T) {
	root := scratch(t, "export")
	defer os.remove_all(root)
	exts := [?]string{".csv", ".json"}
	for ext in exts {
		out := fmt.tprintf("%s%s", root, ext)
		code, _, err := capture(t, {target = root, report = out}, "", true)
		testing.expect_value(t, code, EXIT_OK)
		testing.expect(t, !strings.contains(err, "needs a licence"), err)
		testing.expect(t, os.exists(out), ext)
		text := read_file(t, out)
		testing.expect(t, strings.contains(text, report.FREE_EXPORT), text)
		if ext == ".csv" {
			testing.expect(t, strings.contains(text, report.NONE_EARLIER), text)
		}
		if ext == ".json" {
			testing.expect(t, strings.contains(text, "\"compared\": null"), text)
		}
		os.remove(out)
	}
}

@(test)
pdf_and_html_are_refused_after_the_trial :: proc(t: ^testing.T) {
	root := scratch(t, "pro-report")
	defer os.remove_all(root)
	exts := [?]string{".pdf", ".html"}
	for ext in exts {
		out := fmt.tprintf("%s%s", root, ext)
		code, _, err := capture(t, {target = root, report = out}, "", true)
		testing.expect_value(t, code, EXIT_ERROR)
		testing.expect(t, strings.contains(err, "30-day Pro evaluation"), err)
		testing.expect(t, strings.contains(err, "csv or json"), err)
		testing.expect(t, !os.exists(out), "nothing is written")
	}
}

// Reclaim's candidates are part of the current scan. A CSV that lists them is
// still written with no licence. Reading the deletion log is the same: leita
// history prints a row it was given and does not ask for a licence. Neither
// half deletes; reclaim's own tests do.
@(test)
a_reclaim_report_and_the_deletion_log_stay_free :: proc(t: ^testing.T) {
	root := scratch(t, "reclaim")
	defer os.remove_all(root)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/package.json", root), "{}") == nil)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/node_modules", root)) == nil)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/node_modules/left.js", root), "x") == nil,
	)
	out := fmt.tprintf("%s.csv", root)
	defer os.remove(out)
	code, _, err := capture(t, {target = root, report = out, reclaim = true}, "", true)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, !strings.contains(err, "needs a licence"), err)
	text := read_file(t, out)
	testing.expect(t, strings.contains(text, report.FREE_EXPORT), text)
	testing.expect(t, strings.contains(text, "Installed dependencies"), text)

	// The deletion log is not a Pro action. leita history never asks for a licence.
	log_dir, mk := jm_path.make_directory_temp("", "leita-free-log-", context.temp_allocator)
	testing.expect(t, mk == nil)
	defer os.remove_all(log_dir)
	kept := fmt.tprintf("%s/history.db", log_dir)
	st: history.Store
	testing.expect(t, history.open(&st, kept) == nil)
	testing.expect(
		t,
		history.record(
			&st,
			[]history.Action {
				{1_800_014_400, .Delete, fmt.tprintf("%s/node_modules", root), "", 9, false},
			},
		) ==
		nil,
	)
	history.close(&st)
	b := strings.builder_make(context.temp_allocator)
	testing.expect_value(t, history_dispatch({kept = kept}, nil, strings.to_writer(&b)), EXIT_OK)
	testing.expect(t, strings.contains(strings.to_string(b), "node_modules"), strings.to_string(b))
}

// The second scan is kept beside the first. Comparing them is Pro, so the
// free JSON carries no earlier scan and the note says why.
@(test)
an_earlier_scan_is_kept_but_not_compared_after_the_trial :: proc(t: ^testing.T) {
	root := scratch(t, "compare")
	defer os.remove_all(root)
	store := fmt.tprintf("%s.history/history.db", root)
	defer os.remove_all(fmt.tprintf("%s.history", root))
	code, _, err := capture(t, {target = root}, store, true)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, !strings.contains(err, "comparing with earlier scans"), err)

	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/more.txt", root), "hello") == nil)
	out := fmt.tprintf("%s.json", root)
	defer os.remove(out)
	code, _, err = capture(t, {target = root, report = out}, store, true)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(err, "comparing with earlier scans"), err)
	testing.expect(t, strings.contains(err, "this scan is still kept"), err)
	testing.expect(t, !strings.contains(err, "history unavailable"), err)
	text := read_file(t, out)
	testing.expect(t, strings.contains(text, "\"compared\": null"), text)
	testing.expect(t, strings.contains(text, report.FREE_EXPORT), text)

	csv := fmt.tprintf("%s.csv", root)
	defer os.remove(csv)
	code, _, err = capture(t, {target = root, report = csv}, store, true)
	testing.expect_value(t, code, EXIT_OK)
	table := read_file(t, csv)
	testing.expect(t, strings.contains(table, report.EARLIER_KEPT), table)
	testing.expect(t, !strings.contains(table, report.NONE_EARLIER), table)
	testing.expect(t, strings.contains(table, report.FREE_EXPORT), table)
}

// scratch is an empty directory for one test, removed by the caller.
@(private)
scratch :: proc(t: ^testing.T, name: string) -> string {
	root, err := jm_path.make_directory_temp(
		"",
		fmt.tprintf("leita-free-%s-", name),
		context.temp_allocator,
	)
	testing.expect(t, err == nil, "no temp directory")
	return root
}

// stdio_rw keeps the process's standard streams still while any test prints to
// them. The runners share those handles. capture and capture_stdout point them at
// a file of their own, and take the lock alone, so no other test runs a scan then:
// one that did would print into that file (its note landing in this test's text, as
// "database is locked" once did) or into one already closed (a use after free). A
// test that calls the program's printing code holds the lock shared (stdio_shared),
// so any number of them run together.
@(private)
stdio_rw: sync.RW_Mutex

@(private)
stdio_shared :: proc() {
	sync.rw_mutex_shared_lock(&stdio_rw)
}

@(private)
stdio_done :: proc() {
	sync.rw_mutex_shared_unlock(&stdio_rw)
}

// capture runs one scan with Pro locked when locked is set, and returns its
// exit code and what it printed. The text is in the temp allocator.
@(private)
capture :: proc(
	t: ^testing.T,
	opt: Options,
	kept: string,
	locked: bool,
) -> (
	code: int,
	out, err: string,
) {
	sync.rw_mutex_lock(&stdio_rw)
	defer sync.rw_mutex_unlock(&stdio_rw)
	dir, mk := jm_path.make_directory_temp("", "leita-capture-*", context.temp_allocator)
	if !testing.expect(t, mk == nil, "no temp directory") {
		return
	}
	defer os.remove_all(dir)
	out_path := fmt.tprintf("%s/out", dir)
	err_path := fmt.tprintf("%s/err", dir)
	of, oerr := os.open(out_path, {.Write, .Create}, os.Permissions_Default_File)
	ef, eerr := os.open(err_path, {.Write, .Create}, os.Permissions_Default_File)
	if !testing.expect(t, oerr == nil && eerr == nil, "could not capture the scan") {
		return
	}
	saved_out, saved_err := os.stdout, os.stderr
	os.stdout, os.stderr = of, ef
	code = scan_and_say(opt, kept, "", locked)
	os.stdout, os.stderr = saved_out, saved_err
	os.close(of)
	os.close(ef)
	out = read_file(t, out_path)
	err = read_file(t, err_path)
	return
}
