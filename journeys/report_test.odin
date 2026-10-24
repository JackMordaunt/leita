package journeys

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A person writes the scan up in each format and opens what they get.
@(test)
a_scan_is_written_up_in_every_format :: proc(t: ^testing.T) {
	h := home(t, "report")
	defer leave(h)

	// JSON: the totals are the made-up disk's, which are known exactly.
	r := run(
		t,
		h,
		0,
		"--no-history",
		"--report",
		file_in(h, "r.json"),
		"--top",
		"5",
		"/Users/alex",
	)
	expect_code(t, r, 0)
	doc := report(t, read_file(file_in(h, "r.json")))
	testing.expect_value(t, text(doc, "schema"), "leita.report/1")
	totals := member(doc, "totals")
	testing.expect_value(t, whole(totals, "files"), 778414)
	testing.expect_value(t, whole(totals, "bytes"), 320838590464)
	testing.expect_value(t, whole(totals, "unread"), 0)
	testing.expect_value(t, text(member(doc, "target"), "engine"), "synthetic")
	files, _ := doc["largest_files"].(json.Array)
	testing.expect_value(t, len(files), 5)
	if len(files) > 0 {
		first, _ := files[0].(json.Object)
		path, _ := first["path"].(json.String)
		testing.expectf(t, strings.has_suffix(path, "/Docker.raw"), "the largest file is %q", path)
	}

	// CSV: a header, then the total.
	r = run(t, h, 0, "--no-history", "--report", file_in(h, "r.csv"), "/Users/alex")
	expect_code(t, r, 0)
	csv := read_file(file_in(h, "r.csv"))
	testing.expectf(
		t,
		strings.contains(csv, "section,rank,name,kind,bytes"),
		"csv header: %.120s",
		csv,
	)
	testing.expect(
		t,
		strings.contains(csv, "total,,/Users/alex,,320838590464,100.00,778414"),
		"csv total row",
	)

	// HTML and PDF, free while the Pro evaluation runs.
	r = run(t, h, 0, "--no-history", "--report", file_in(h, "r.html"), "/Users/alex")
	expect_code(t, r, 0)
	html := read_file(file_in(h, "r.html"))
	testing.expect(t, strings.has_prefix(html, "<!doctype html>"), "the html report is not a page")
	testing.expect(
		t,
		strings.contains(html, "Docker.raw"),
		"the html report omits the largest file",
	)
	r = run(t, h, 0, "--no-history", "--report", file_in(h, "r.pdf"), "/Users/alex")
	expect_code(t, r, 0)
	testing.expect(
		t,
		strings.has_prefix(read_file(file_in(h, "r.pdf")), "%PDF-"),
		"the pdf report is not a PDF",
	)

	// - writes the report to standard output in place of the summary.
	r = run(
		t,
		h,
		0,
		"--no-history",
		"--report",
		"-",
		"--format",
		"json",
		"--top",
		"1",
		"/Users/alex",
	)
	expect_code(t, r, 0)
	piped := report(t, r.out)
	testing.expect_value(t, whole(member(piped, "totals"), "files"), 778414)
	testing.expect(
		t,
		!strings.contains(r.out, "largest files"),
		"the summary was printed beside the report",
	)
}

// After the evaluation the paid formats ask for a licence and the free ones do not.
@(test)
a_report_that_needs_a_licence_says_so_once_the_evaluation_ends :: proc(t: ^testing.T) {
	h := home(t, "gate")
	defer leave(h)

	r := run(t, h, 0, "licence")
	testing.expect(t, strings.contains(r.out, "Pro evaluation has 30 days left"), r.out)

	// The trial began 2001-09-09 as far as the data folder says.
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/first-use", data(h)), "1000000000\n") == nil,
		"could not age the trial",
	)
	r = run(t, h, 0, "licence")
	testing.expect(t, strings.contains(r.out, "evaluation has ended"), r.out)

	r = run(t, h, 0, "--no-history", "--report", file_in(h, "r.html"), "/Users/alex")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.err, "needs a licence"), r.err)
	testing.expect(t, !os.exists(file_in(h, "r.html")), "a refused report was written anyway")

	r = run(t, h, 0, "--no-history", "--report", file_in(h, "r.csv"), "/Users/alex")
	expect_code(t, r, 0)
	testing.expect(t, os.exists(file_in(h, "r.csv")), "the free csv report was not written")
}
