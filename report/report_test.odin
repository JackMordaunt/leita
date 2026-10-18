package report

import "core:encoding/base64"
import "core:encoding/csv"
import "core:encoding/json"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

import "jm:debug"

import "../kinds"
import "../pdf"
import "../reclaim"
import "../scan"
import "../survey"

// FIVE_GIB is past what 32 bits hold, so a size that went through one shows.
@(private = "file")
FIVE_GIB :: u64(5) << 30

// Names chosen to break a writer that trusts them.
@(private = "file")
QUOTED :: `/data/a "quoted", name`
@(private = "file")
NEWLINE :: "/data/line\nbreak.txt"
@(private = "file")
SCRIPT :: "/data/<script>alert(1)</script>"
@(private = "file")
FORMULA :: "=cmd|' /C calc'!A0"
@(private = "file")
INVALID :: "/data/bad\xff\xfename"
@(private = "file")
EMOJI :: "/data/\U0001F600.mp4"

/*
A report as build would make one, built by hand: a 5 GiB target compared with
an earlier scan, its largest entries named to break whatever writes them.
*/
@(private = "file")
sample :: proc() -> Report {
	dirs := slice.clone(
		[]Entry {
			{path = QUOTED, bytes = 3 << 30, kind = .Folder, was = u64(1) << 30},
			{path = SCRIPT, bytes = 1 << 20, kind = .Cache},
		},
		context.temp_allocator,
	)
	files := slice.clone(
		[]Entry {
			{path = EMOJI, bytes = FIVE_GIB - 1, kind = .Multimedia, was = FIVE_GIB},
			{path = NEWLINE, bytes = 300, kind = .Text},
			{path = FORMULA, bytes = 200, kind = .Other},
			{path = INVALID, bytes = 100, kind = .Other},
		},
		context.temp_allocator,
	)
	items := slice.clone(
		[]Candidate{{path = "/data/app/node_modules", bytes = 1 << 20}},
		context.temp_allocator,
	)
	groups := slice.clone(
		[]Group{{category = .Dependencies, bytes = 1 << 20, items = items}},
		context.temp_allocator,
	)
	r := Report {
		generated = time.unix(1790160062, 0),
		version = "test",
		target = "/data",
		volume = "/dev/sda1",
		filesystem = .Other,
		engine = .Walk,
		started = time.unix(1790160000, 0),
		duration = 1500 * time.Millisecond,
		bytes = FIVE_GIB + 600,
		files = 4,
		directories = 2,
		space = Space{total = 1 << 40, free = 1 << 39},
		compared = Baseline{taken = time.unix(1789555200, 0), bytes = FIVE_GIB},
		largest_directories = dirs,
		largest_files = files,
		reclaim = groups,
	}
	r.kinds[.Multimedia] = {FIVE_GIB - 1, 1}
	r.kinds[.Text] = {300, 1}
	r.kinds[.Other] = {301, 2}
	return r
}

@(test)
json_reads_back_with_every_name_intact :: proc(t: ^testing.T) {
	r := sample()
	sb := strings.builder_make(context.temp_allocator)
	write_json(&sb, &r)
	text := strings.to_string(sb)
	testing.expect(t, utf8.valid_string(text), "JSON must be UTF-8")

	v, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	top := v.(json.Object)
	testing.expect_value(t, top["schema"].(json.String), "leita.report/1")
	testing.expect_value(t, top["generated"].(json.String), "2026-09-23T10:41:02Z")
	testing.expect_value(t, top["scan"].(json.Object)["duration"].(json.String), "PT1.500S")
	// FIVE_GIB + 600, past 32 bits, comes back exact.
	testing.expect_value(
		t,
		top["totals"].(json.Object)["bytes"].(json.Integer),
		i64(FIVE_GIB + 600),
	)

	files := top["largest_files"].(json.Array)
	testing.expect_value(t, len(files), 4)
	testing.expect_value(t, files[0].(json.Object)["path"].(json.String), EMOJI)
	testing.expect_value(t, files[0].(json.Object)["change"].(json.Integer), -1)
	testing.expect_value(t, files[1].(json.Object)["path"].(json.String), NEWLINE)
	testing.expect(t, files[1].(json.Object)["bytes_before"].(json.Null) == nil)
	testing.expect_value(t, files[2].(json.Object)["path"].(json.String), FORMULA)

	// Not UTF-8: readable with U+FFFD, and exact in base64 beside it.
	bad := files[3].(json.Object)
	testing.expect_value(t, bad["path"].(json.String), "/data/bad\uFFFD\uFFFDname")
	raw, _ := base64.decode(bad["path_base64"].(json.String), allocator = context.temp_allocator)
	testing.expect_value(t, string(raw), INVALID)
	_, has_raw := files[0].(json.Object)["path_base64"]
	testing.expect(t, !has_raw, "a UTF-8 path needs no base64")

	dirs := top["largest_directories"].(json.Array)
	testing.expect_value(t, dirs[0].(json.Object)["path"].(json.String), QUOTED)
	testing.expect_value(t, dirs[1].(json.Object)["path"].(json.String), SCRIPT)
	testing.expect_value(t, dirs[1].(json.Object)["kind"].(json.String), "cache")

	kind_rows := top["kinds"].(json.Array)
	testing.expect_value(t, len(kind_rows), len(kinds.Kind))
	media := kind_rows[int(kinds.Kind.Multimedia)].(json.Object)
	testing.expect_value(t, media["kind"].(json.String), "multimedia")
	testing.expect_value(t, media["bytes"].(json.Integer), i64(FIVE_GIB - 1))
	testing.expect_value(t, media["files"].(json.Integer), 1)
	groups := top["reclaim"].(json.Object)["groups"].(json.Array)
	testing.expect_value(t, groups[0].(json.Object)["category"].(json.String), "dependencies")
	testing.expect(t, top["thresholds"].(json.Null) == nil, "none was asked for")
}

// An empty scan is written in full, every member there, so a reader never has
// to ask whether one is missing.
@(test)
json_of_an_empty_report :: proc(t: ^testing.T) {
	r := Report {
		generated = time.unix(1790160062, 0),
		version   = "test",
		target    = "/empty",
	}
	sb := strings.builder_make(context.temp_allocator)
	write_json(&sb, &r)
	testing.expect_value(t, strings.to_string(sb), EMPTY_JSON)
}

@(private = "file")
EMPTY_JSON :: `{
  "schema": "leita.report/1",
  "generated": "2026-09-23T10:41:02Z",
  "generator": {"name": "leita", "version": "test", "licensee": null},
  "target": {"path": "/empty", "volume": null, "filesystem": null, "engine": null},
  "scan": {"started": null, "duration": "PT0.000S"},
  "totals": {"bytes": 0, "files": 0, "directories": 0, "unread": 0},
  "space": null,
  "compared": null,
  "largest_directories": [],
  "largest_files": [],
  "kinds": [
    {"kind": "folder", "name": "Folder", "bytes": 0, "files": 0, "share": 0.000000},
    {"kind": "multimedia", "name": "Multimedia", "bytes": 0, "files": 0, "share": 0.000000},
    {"kind": "image", "name": "Image", "bytes": 0, "files": 0, "share": 0.000000},
    {"kind": "archive", "name": "Archive", "bytes": 0, "files": 0, "share": 0.000000},
    {"kind": "document", "name": "Document", "bytes": 0, "files": 0, "share": 0.000000},
    {"kind": "text", "name": "Text", "bytes": 0, "files": 0, "share": 0.000000},
    {"kind": "binary", "name": "Binary", "bytes": 0, "files": 0, "share": 0.000000},
    {"kind": "cache", "name": "Cache", "bytes": 0, "files": 0, "share": 0.000000},
    {"kind": "other", "name": "Other", "bytes": 0, "files": 0, "share": 0.000000}
  ],
  "reclaim": null,
  "thresholds": null,
  "generated_by": "Generated by leita test on 2026-09-23T10:41:02Z. Unlicensed copy made during the 30-day trial."
}
`

@(test)
csv_reads_back_one_row_per_entry :: proc(t: ^testing.T) {
	r := sample()
	sb := strings.builder_make(context.temp_allocator)
	write_csv(&sb, &r)
	text := strings.to_string(sb)
	testing.expect(t, strings.has_prefix(text, "\xef\xbb\xbf"), "the byte order mark leads")
	testing.expect(t, utf8.valid_string(text), "CSV must be UTF-8")
	// Every line ends CRLF: no bare newline is left once the CRLFs are gone.
	bare, _ := strings.replace_all(text, "\r\n", "", context.temp_allocator)
	testing.expect(t, !strings.contains(bare, "\n"))

	rd: csv.Reader
	csv.reader_init_with_string(&rd, text[3:], context.temp_allocator)
	rows, err := csv.read_all(&rd, context.temp_allocator)
	testing.expect_value(t, err, nil)
	// A header, the total, 2 directories, 4 files, every kind, 1 candidate, 1 note.
	testing.expect_value(t, len(rows), 1 + 1 + 2 + 4 + len(kinds.Kind) + 1 + 1)
	for row in rows {
		testing.expect_value(t, len(row), 9)
	}
	testing.expect_value(t, rows[0][0], "section")
	testing.expect_value(t, rows[1][4], "5368709720")
	testing.expect_value(t, rows[2][2], QUOTED)
	testing.expect_value(t, rows[2][7], "1073741824")
	testing.expect_value(t, rows[2][8], "2147483648")
	testing.expect_value(t, rows[3][2], "/data/<script>alert(1)</script>")
	testing.expect_value(t, rows[4][2], "/data/\U0001F600.mp4")
	testing.expect_value(t, rows[4][8], "-1")
	// A newline in a name stays in its row, as a control picture.
	testing.expect_value(t, rows[5][2], "/data/line\u240Abreak.txt")
	// A cell starting = gets an apostrophe in front (csv.odin's FORMULA_LEADERS).
	testing.expect_value(t, rows[6][2], "'=cmd|' /C calc'!A0")
	testing.expect_value(t, rows[7][2], "/data/bad\uFFFD\uFFFDname")
	last := rows[len(rows) - 1]
	testing.expect_value(t, last[0], "note")
	testing.expect_value(
		t,
		last[2],
		"Generated by leita test on 2026-09-23T10:41:02Z. Unlicensed copy made during the 30-day trial.",
	)
}

@(test)
csv_of_an_empty_report :: proc(t: ^testing.T) {
	r := Report {
		generated = time.unix(1790160062, 0),
		version   = "test",
		target    = "/empty",
	}
	sb := strings.builder_make(context.temp_allocator)
	write_csv(&sb, &r)
	testing.expect_value(t, strings.to_string(sb), EMPTY_CSV)
}

@(private = "file")
EMPTY_CSV ::
	"\xef\xbb\xbfsection,rank,name,kind,bytes,percent,files,bytes_before,change\r\n" +
	"total,,/empty,,0,0.00,0,,\r\n" +
	"kind,,Folder,,0,0.00,0,,\r\n" +
	"kind,,Multimedia,,0,0.00,0,,\r\n" +
	"kind,,Image,,0,0.00,0,,\r\n" +
	"kind,,Archive,,0,0.00,0,,\r\n" +
	"kind,,Document,,0,0.00,0,,\r\n" +
	"kind,,Text,,0,0.00,0,,\r\n" +
	"kind,,Binary,,0,0.00,0,,\r\n" +
	"kind,,Cache,,0,0.00,0,,\r\n" +
	"kind,,Other,,0,0.00,0,,\r\n" +
	"note,,No earlier scan to compare with.,,,,,,\r\n" +
	"note,,Generated by leita test on 2026-09-23T10:41:02Z. Unlicensed copy made during the 30-day trial.,,,,,,\r\n"

@(test)
html_escapes_every_name_and_fetches_nothing :: proc(t: ^testing.T) {
	r := sample()
	sb := strings.builder_make(context.temp_allocator)
	write_html(&sb, &r)
	text := strings.to_string(sb)
	testing.expect(t, utf8.valid_string(text), "HTML must be UTF-8")
	testing.expect(t, !strings.contains(text, "<script"), "a name became markup")
	testing.expect(t, strings.contains(text, "/data/&lt;script&gt;alert(1)&lt;/script&gt;"))
	testing.expect(t, strings.contains(text, "/data/a &quot;quoted&quot;, name"))
	testing.expect(t, strings.contains(text, "/data/line\u240Abreak.txt"))
	testing.expect(t, strings.contains(text, "/data/bad\uFFFD\uFFFDname"))
	testing.expect(t, strings.contains(text, "/data/\U0001F600.mp4"))
	testing.expect(t, strings.contains(text, "title=\"5368709119 bytes\""))
	// Nothing the page could fetch, and a policy saying so.
	testing.expect(t, !strings.contains(text, "http:"))
	testing.expect(t, !strings.contains(text, "https:"))
	testing.expect(t, !strings.contains(text, "url("))
	testing.expect(t, !strings.contains(text, "@import"))
	testing.expect(t, strings.contains(text, "default-src 'none'"))
	testing.expect(t, strings.contains(text, "prefers-color-scheme: dark"))
	testing.expect(t, strings.contains(text, "@media print"))
	testing.expect(t, strings.contains(text, "Generated by leita test on 2026-09-23T10:41:02Z"))
}

// A report of a made-up disk says so under its title, in HTML, and a report of
// a real one does not.
@(test)
html_of_a_made_up_disk_carries_a_banner :: proc(t: ^testing.T) {
	r := sample()
	sb := strings.builder_make(context.temp_allocator)
	write_html(&sb, &r)
	testing.expect(
		t,
		!strings.contains(strings.to_string(sb), "made-up"),
		"a real disk had a banner",
	)

	r.engine = .Synthetic
	strings.builder_reset(&sb)
	write_html(&sb, &r)
	text := strings.to_string(sb)
	banner := "<p class=\"banner\">This report is of a made-up disk: LEITA_SYNTHETIC was set.</p>"
	testing.expect(t, strings.contains(text, banner), "no banner")
	title := strings.index(text, "<h1")
	testing.expect(
		t,
		title >= 0 && strings.index(text, banner) > title,
		"the banner is not under the title",
	)
	testing.expect(
		t,
		strings.index(text, banner) < strings.index(text, "<section"),
		"the banner is not in the header",
	)
}

// A name that is a bidi override, a C1 control and markup comes out of the page
// as text, with nothing in it that reorders, runs or hides.
@(test)
html_shows_a_hostile_name_without_its_controls :: proc(t: ^testing.T) {
	r := sample()
	r.target = "/data/\x1b]52;c;AAAA\x07\nfdp.\u202etxt\u009b<img src=x>=1+1"
	sb := strings.builder_make(context.temp_allocator)
	write_html(&sb, &r)
	text := strings.to_string(sb)
	testing.expect(
		t,
		strings.contains(
			text,
			"/data/\u241b]52;c;AAAA\u2407\u240afdp.\uFFFDtxt\uFFFD&lt;img src=x&gt;=1+1",
		),
	)
	testing.expect(t, !strings.contains_any(text, "\x1b\x07\u202e\u009b"), "a control survived")
	testing.expect(t, !strings.contains(text, "<img"), "a name became markup")
}

@(test)
html_of_an_empty_report :: proc(t: ^testing.T) {
	r := Report {
		version = "test",
		target  = "/empty",
	}
	sb := strings.builder_make(context.temp_allocator)
	write_html(&sb, &r)
	text := strings.to_string(sb)
	testing.expect(t, strings.contains(text, "<p class=\"note\">None.</p>"))
	testing.expect(t, strings.contains(text, "No earlier scan to compare with."))
	testing.expect(t, strings.has_suffix(text, "</html>\n"))
}

@(test)
a_format_is_named_by_its_extension :: proc(t: ^testing.T) {
	cases := [?]struct {
		path:   string,
		format: Format,
		ok:     bool,
	} {
		{"out.csv", .Csv, true},
		{"out.JSON", .Json, true},
		{"report.html", .Html, true},
		{"report.htm", .Html, true},
		{"a.pdf", .Pdf, true},
		{"a.txt", {}, false},
		{"-", {}, false},
	}
	for c in cases {
		f, ok := format_of(c.path)
		testing.expect_value(t, ok, c.ok)
		testing.expect_value(t, f, c.format)
	}
	f, ok := format_named("HTML")
	testing.expect(t, ok && f == .Html)
}

// A PDF of the sample is a whole file, the same each time it is written; one
// with more rows than a page holds runs onto more pages. A machine with none
// of pdf's system fonts cannot set one: that fails, as it does in pdf's tests.
@(test)
a_pdf_is_written_whole_and_runs_onto_pages :: proc(t: ^testing.T) {
	r := sample()
	sb := strings.builder_make(context.temp_allocator)
	if !testing.expect_value(t, export(strings.to_writer(&sb), &r, .Pdf), Error.None) {
		return
	}
	one := strings.clone(strings.to_string(sb), context.temp_allocator)
	testing.expect(t, strings.has_prefix(one, "%PDF-1.7"))
	testing.expect(t, strings.has_suffix(one, "%%EOF\n"))
	testing.expect(t, strings.contains(one, "/Count 1 "), "the sample fits one page")

	strings.builder_reset(&sb)
	testing.expect_value(t, export(strings.to_writer(&sb), &r, .Pdf), Error.None)
	testing.expect(t, strings.to_string(sb) == one, "the same report makes the same file")

	many := make([]Entry, 150, context.temp_allocator)
	for &e, i in many {
		e = {
			path  = strings.concatenate(
				{"/data/", strings.repeat("deep/", i % 40, context.temp_allocator), "file.bin"},
				context.temp_allocator,
			),
			bytes = u64(1000 - i),
		}
	}
	r.largest_files = many
	strings.builder_reset(&sb)
	testing.expect_value(t, export(strings.to_writer(&sb), &r, .Pdf, .Letter), Error.None)
	text := strings.to_string(sb)
	testing.expect(t, !strings.contains(text, "/Count 1 "), "150 rows take more than a page")
	testing.expect(t, strings.contains(text, "/MediaBox [0 0 612 792]"), "on Letter")
}

// A path too long for its column breaks after a separator onto a second line,
// and one too long for two keeps its start and its end.
@(test)
a_long_path_wraps_then_loses_its_middle :: proc(t: ^testing.T) {
	r := sample()
	doc: pdf.Document
	pdf.init(&doc)
	defer pdf.destroy(&doc)
	p := Pen {
		doc = &doc,
		r   = &r,
	}
	font, ok := pdf.add_system_fonts(&doc)
	if !testing.expect(t, ok, "no system font to measure with") {
		return
	}
	p.regular = font
	path := "/home/someone/projects/website/node_modules/.cache/babel-loader/index.js"
	first, second := path_lines(&p, path, 1000)
	testing.expect_value(t, first, path)
	testing.expect_value(t, second, "")

	width := pdf.text_width(&doc, path, font, BODY_SIZE) * 0.7
	first, second = path_lines(&p, path, width)
	testing.expect(t, strings.has_suffix(first, "/"), "the break falls after a separator")
	testing.expect_value(t, strings.concatenate({first, second}, context.temp_allocator), path)

	width = pdf.text_width(&doc, path, font, BODY_SIZE) * 0.3
	first, second = path_lines(&p, path, width)
	testing.expect(t, strings.has_prefix(path, first), "the start is kept")
	testing.expect(t, strings.has_prefix(second, "…"), "the middle is left out")
	testing.expect(t, strings.has_suffix(second, "/index.js"), "the end is kept")
	testing.expect(t, pdf.text_width(&doc, second, font, BODY_SIZE) <= width)
}

@(test)
a_locale_says_its_paper :: proc(t: ^testing.T) {
	testing.expect_value(t, paper_of("en_US.UTF-8"), Paper.Letter)
	testing.expect_value(t, paper_of("es_MX"), Paper.Letter)
	testing.expect_value(t, paper_of("en_GB.UTF-8"), Paper.A4)
	testing.expect_value(t, paper_of("de_DE@euro"), Paper.A4)
	testing.expect_value(t, paper_of("C"), Paper.A4)
	testing.expect_value(t, paper_of("C.UTF-8"), Paper.A4)
}

/*
A small scan, built by hand:

	0  /r/                      directory, 4 KiB of its own
	1  /r/proj/                 directory
	2  /r/proj/package.json     10 bytes
	3  /r/proj/node_modules/    directory
	4  /r/proj/node_modules/x.js  100 bytes
	5  /r/film.mkv              5 GiB
	6  /r/notes.txt             0 bytes
*/
// A path built by hand below must join "/r" to a child the same way scan
// does, or the comparison reads a mix of slashes scan never produced. "/r"
// is a stand-in root, not a real drive letter, so on Windows that join
// still inserts a backslash rather than skip it.
@(private = "file")
R_FILM :: "/r" + scan.SEPARATOR + "film.mkv"
@(private = "file")
R_PROJ :: "/r" + scan.SEPARATOR + "proj"
@(private = "file")
R_PROJ_NODE_MODULES_XJS :: R_PROJ + scan.SEPARATOR + "node_modules" + scan.SEPARATOR + "x.js"
// Reclaim's own candidate path, which it joins on the host's separator as scan
// does (visit, reclaim.odin).
@(private = "file")
RECLAIM_NODE_MODULES :: R_PROJ + scan.SEPARATOR + "node_modules"

@(private = "file")
small_tree :: proc(t: ^testing.T, tree: ^scan.Tree, roll: ^survey.Rollup, mounted := false) {
	testing.expect(t, scan.tree_init(tree) == nil)
	testing.expect(t, scan.reserve(tree, 7) == nil)
	place :: proc(tree: ^scan.Tree, i, parent: u32, name: string, disk: u64, dir: bool) {
		n := scan.node(tree, i)
		n.parent = parent
		n.disk = disk
		n.name = scan.name_copy(tree, name)
		scan.node_publish(n, {.Used, .Settled, .Directory} if dir else {.Used, .Settled})
	}
	place(tree, 0, 0, "/r", 4096, true)
	place(tree, 1, 0, "proj", 0, true)
	place(tree, 2, 1, "package.json", 10, false)
	place(tree, 3, 1, "node_modules", 0, true)
	if mounted {
		// As the walk records another filesystem mounted there.
		scan.node_mark(scan.node(tree, 3), {.Mount})
	}
	place(tree, 4, 3, "x.js", 100, false)
	place(tree, 5, 0, "film.mkv", FIVE_GIB, false)
	place(tree, 6, 0, "notes.txt", 0, false)
	tree.root = 0
	roll.linked = true
	survey.rollup_advance(roll, tree)
}

@(test)
build_describes_the_scan :: proc(t: ^testing.T) {
	tree: scan.Tree
	roll: survey.Rollup
	small_tree(t, &tree, &roll)
	defer scan.tree_destroy(&tree)
	defer survey.rollup_destroy(&roll)

	previous := make(map[string]u64)
	defer delete(previous)
	previous[""] = 1000
	previous["proj"] = 50
	r := build(
		&tree,
		&roll,
		{engine = .Walk, duration = time.Second},
		{
			top = 2,
			reclaim = true,
			user = {"/nowhere", ""},
			previous = Snapshot{time.unix(1, 0), previous},
		},
	)
	defer destroy(&r)

	total := FIVE_GIB + 4096 + 110
	testing.expect_value(t, r.target, "/r")
	testing.expect_value(t, r.bytes, total)
	testing.expect_value(t, r.files, 4)
	testing.expect_value(t, r.directories, 2)

	sum: u64
	for k in r.kinds {
		sum += k.bytes
	}
	testing.expect_value(t, sum, total)
	testing.expect_value(t, r.kinds[.Multimedia], Kind_Total{FIVE_GIB, 1})
	testing.expect_value(t, r.kinds[.Cache], Kind_Total{100, 1})
	testing.expect_value(t, r.kinds[.Folder], Kind_Total{4096, 0})
	testing.expect_value(t, r.kinds[.Other], Kind_Total{})
	testing.expect_value(t, r.kinds[.Text], Kind_Total{10, 2})

	// Only as many as asked for, largest first; an empty file is not ranked.
	testing.expect_value(t, len(r.largest_files), 2)
	testing.expect_value(t, r.largest_files[0].path, R_FILM)
	testing.expect_value(t, r.largest_files[0].kind, kinds.Kind.Multimedia)
	testing.expect_value(t, r.largest_files[1].path, R_PROJ_NODE_MODULES_XJS)
	testing.expect_value(t, r.largest_files[1].kind, kinds.Kind.Cache)

	testing.expect_value(t, len(r.largest_directories), 2)
	testing.expect_value(t, r.largest_directories[0].path, R_PROJ)
	testing.expect_value(t, r.largest_directories[0].bytes, 110)
	testing.expect_value(t, r.largest_directories[0].was.? or_else 0, 50)
	testing.expect_value(t, r.largest_directories[1].kind, kinds.Kind.Cache)
	testing.expect(t, r.largest_directories[1].was == nil, "not kept, so nothing to compare")

	c, compared := r.compared.?
	testing.expect(t, compared && c.bytes == 1000)

	groups, asked := r.reclaim.?
	testing.expect(t, asked)
	testing.expect_value(t, len(groups), 1)
	if len(groups) == 1 {
		testing.expect_value(t, groups[0].category, reclaim.Category.Dependencies)
		testing.expect_value(t, groups[0].items[0].path, RECLAIM_NODE_MODULES)
		testing.expect_value(t, groups[0].bytes, 100)
	}
}

// A disk mounted at node_modules beside package.json is not Reclaim's to offer:
// what is there belongs to another volume.
@(test)
a_mount_point_is_never_a_candidate :: proc(t: ^testing.T) {
	for mounted in ([]bool{false, true}) {
		tree: scan.Tree
		roll: survey.Rollup
		small_tree(t, &tree, &roll, mounted)
		defer scan.tree_destroy(&tree)
		defer survey.rollup_destroy(&roll)

		r := build(&tree, &roll, {engine = .Walk}, {reclaim = true, user = {"/nowhere", ""}})
		defer destroy(&r)
		groups, asked := r.reclaim.?
		testing.expect(t, asked)
		// Unmounted, the same folder is offered, so only the mount keeps it out.
		testing.expect_value(t, len(groups), 0 if mounted else 1)
	}
}

// Without a previous scan or a request for Reclaim, neither is there.
@(test)
build_leaves_out_what_was_not_asked :: proc(t: ^testing.T) {
	tree: scan.Tree
	roll: survey.Rollup
	small_tree(t, &tree, &roll)
	defer scan.tree_destroy(&tree)
	defer survey.rollup_destroy(&roll)

	r := build(&tree, &roll, {}, {})
	defer destroy(&r)
	testing.expect(t, r.compared == nil)
	testing.expect(t, r.reclaim == nil)
	testing.expect_value(t, len(r.largest_directories), 2)
	testing.expect_value(t, len(r.largest_files), 3)
}

/*
A report built from a scan, written in every format and destroyed, frees each
block at the size it was made. The test runner's mem.Tracking_Allocator checks
only that a freed pointer was allocated, not its size (its free case looks the
pointer up and drops the entry), so jm's debug allocator stands in: the paths
scan.path made were freed short of their builder's capacity, a Size_Mismatch
issue for every path in an export.
*/
@(test)
every_format_frees_what_build_made_at_its_size :: proc(t: ^testing.T) {
	da: debug.Allocator
	debug.init(&da, context.allocator)
	defer debug.destroy(&da)
	context.allocator = debug.allocator(&da)

	tree: scan.Tree
	roll: survey.Rollup
	small_tree(t, &tree, &roll)
	defer scan.tree_destroy(&tree)
	defer survey.rollup_destroy(&roll)

	previous := make(map[string]u64)
	defer delete(previous)
	previous["proj"] = 50
	before := debug.snapshot(&da)
	for format in Format {
		r := build(
			&tree,
			&roll,
			{engine = .Walk},
			{
				reclaim = true,
				user = {"/nowhere", ""},
				previous = Snapshot{time.unix(1, 0), previous},
			},
		)
		sb := strings.builder_make()
		err := export(strings.to_writer(&sb), &r, format)
		testing.expectf(t, err == .None || err == .No_Font, "%v: %v", format, err)
		// A PDF's text is compressed; the others name the largest directory.
		text := strings.to_string(sb)
		wrote :=
			strings.has_prefix(text, "%PDF-") if format == .Pdf else strings.contains(text, "proj")
		testing.expectf(t, err != .None || wrote, "a %v report was written", format)
		strings.builder_destroy(&sb)
		destroy(&r)
	}
	testing.expect(t, debug.expect_released(&da, before), "the reports freed what they made")
	testing.expect_value(t, debug.issue_count(&da), 0)
}

// A report says whose licence built it, in every format, so one handed on says
// whether it came from a licensed copy.
@(test)
a_report_says_whose_licence_built_it :: proc(t: ^testing.T) {
	r := sample()
	r.licensee = "Acme <Ltd>"
	for format in Format {
		sb := strings.builder_make(context.temp_allocator)
		switch format {
		case .Csv:
			write_csv(&sb, &r)
		case .Json:
			write_json(&sb, &r)
		case .Html:
			write_html(&sb, &r)
		case .Pdf:
			continue // its text is compressed; pdf_test reads it
		}
		text := strings.to_string(sb)
		testing.expectf(t, !strings.contains(text, UNLICENSED), "%v says it is unlicensed", format)
		testing.expectf(
			t,
			strings.contains(text, "Licensed to Acme"),
			"%v names the licensee",
			format,
		)
	}
	testing.expect_value(t, licensed_by(&r), "Licensed to Acme <Ltd>.")
}

// Nothing was asked for: no limit, no check, Ok with nothing to say.
@(test)
threshold_of_is_unconfigured_with_no_limit :: proc(t: ^testing.T) {
	space := Space {
		total = 100,
		free  = 10,
	}
	th, configured, known := threshold_of(space, 0, 0, 0)
	testing.expect(t, !configured, "no limit was given")
	testing.expect(t, !known, "nothing was checked")
	testing.expect_value(t, th.verdict, Verdict.Ok)

	// The same space, this time asked for: a stub that always answered
	// unconfigured would fail here, at 90% used past --warn-used 50.
	th2, configured2, known2 := threshold_of(space, 50, 0, 0, context.temp_allocator)
	testing.expect(t, configured2, "a limit was given")
	testing.expect(t, known2, "space was known")
	testing.expect_value(t, th2.verdict, Verdict.Warn)
}

// A limit was given but the volume's space was not: configured, but not known,
// so a caller never reports Ok for a check it could not make.
@(test)
threshold_of_cannot_check_unknown_space :: proc(t: ^testing.T) {
	_, configured, known := threshold_of(nil, 80, 0, 0)
	testing.expect(t, configured, "a limit was given")
	testing.expect(t, !known, "space is unknown")
}

@(test)
threshold_of_passes_under_every_limit :: proc(t: ^testing.T) {
	th, configured, known := threshold_of(
		Space{total = 100, free = 50},
		80,
		95,
		0,
		context.temp_allocator,
	)
	testing.expect(t, configured && known)
	testing.expect_value(t, th.used_percent, 50)
	testing.expect_value(t, th.verdict, Verdict.Ok)
	testing.expect_value(t, len(th.reasons), 0)
}

@(test)
threshold_of_warns_past_warn_used :: proc(t: ^testing.T) {
	// 85% used: past --warn-used 80, short of --fail-used 95.
	th, _, known := threshold_of(Space{total = 100, free = 15}, 80, 95, 0, context.temp_allocator)
	testing.expect(t, known)
	testing.expect_value(t, th.verdict, Verdict.Warn)
	testing.expect_value(t, len(th.reasons), 1)
	testing.expect(t, strings.contains(th.reasons[0], "--warn-used"))
}

@(test)
threshold_of_fails_past_fail_used :: proc(t: ^testing.T) {
	// 98% used: past both, so both are named even though fail wins the verdict.
	th, _, _ := threshold_of(Space{total = 100, free = 2}, 80, 95, 0, context.temp_allocator)
	testing.expect_value(t, th.verdict, Verdict.Fail)
	testing.expect_value(t, len(th.reasons), 2)
	testing.expect(t, strings.contains(th.reasons[0], "--fail-used"))
	testing.expect(t, strings.contains(th.reasons[1], "--warn-used"))
}

// --min-free has no warning tier: it is either fine or Fail.
@(test)
threshold_of_fails_under_min_free_alone :: proc(t: ^testing.T) {
	th, _, _ := threshold_of(Space{total = 100, free = 50}, 0, 0, 60, context.temp_allocator)
	testing.expect_value(t, th.verdict, Verdict.Fail)
	testing.expect_value(t, len(th.reasons), 1)
	testing.expect(t, strings.contains(th.reasons[0], "--min-free"))
}

// The verdict a caller got from threshold_of is what write_json says, exactly.
// sample's space is 1 TiB total, 512 GiB free (50% used): past --warn-used 40,
// and --min-free 600GiB is past the free it actually has, so both are named
// even though only min_free decides the verdict.
@(test)
json_carries_the_threshold_verdict :: proc(t: ^testing.T) {
	r := sample()
	th, configured, known := threshold_of(r.space, 40, 0, 600 << 30, context.temp_allocator)
	testing.expect(t, configured && known)
	r.thresholds = th

	sb := strings.builder_make(context.temp_allocator)
	write_json(&sb, &r)
	v, err := json.parse_string(
		strings.to_string(sb),
		parse_integers = true,
		allocator = context.temp_allocator,
	)
	testing.expect_value(t, err, json.Error.None)
	top := v.(json.Object)["thresholds"].(json.Object)
	testing.expect_value(t, top["warn_used"].(json.Integer), 40)
	testing.expect(t, top["fail_used"].(json.Null) == nil)
	testing.expect_value(t, top["min_free"].(json.Integer), i64(600) << 30)
	testing.expect_value(t, top["verdict"].(json.String), "fail")
	reasons := top["reasons"].(json.Array)
	testing.expect_value(t, len(reasons), 2)
	testing.expect(t, strings.contains(reasons[0].(json.String), "--warn-used"))
	testing.expect(t, strings.contains(reasons[1].(json.String), "--min-free"))
}
