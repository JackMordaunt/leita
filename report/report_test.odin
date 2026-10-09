package report

import "core:encoding/base64"
import "core:encoding/csv"
import "core:encoding/json"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

import "../kinds"
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
	testing.expect_value(t, top["schema"].(json.String), "estoile.report/1")
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
  "schema": "estoile.report/1",
  "generated": "2026-09-23T10:41:02Z",
  "generator": {"name": "estoile", "version": "test"},
  "target": {"path": "/empty", "volume": null, "filesystem": null, "engine": null},
  "scan": {"started": null, "duration": "PT0.000S"},
  "totals": {"bytes": 0, "files": 0, "directories": 0},
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
  "generated_by": "Generated by estoile test on 2026-09-23T10:41:02Z"
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
	testing.expect_value(t, last[2], "Generated by estoile test on 2026-09-23T10:41:02Z")
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
	"note,,Generated by estoile test on 2026-09-23T10:41:02Z,,,,,,\r\n"

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
	testing.expect(t, strings.contains(text, "Generated by estoile test on 2026-09-23T10:41:02Z"))
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

@(test)
a_pdf_is_not_built_yet :: proc(t: ^testing.T) {
	r := sample()
	sb := strings.builder_make(context.temp_allocator)
	testing.expect_value(t, export(strings.to_writer(&sb), &r, .Pdf), Error.Pdf_Not_Built)
	testing.expect_value(t, strings.builder_len(sb), 0)
	testing.expect_value(t, export(strings.to_writer(&sb), &r, .Json), Error.None)
	testing.expect(t, strings.has_prefix(strings.to_string(sb), "{"))
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
@(private = "file")
small_tree :: proc(t: ^testing.T, tree: ^scan.Tree, roll: ^survey.Rollup) {
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
			home = "/nowhere",
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
	testing.expect_value(t, r.largest_files[0].path, "/r/film.mkv")
	testing.expect_value(t, r.largest_files[0].kind, kinds.Kind.Multimedia)
	testing.expect_value(t, r.largest_files[1].path, "/r/proj/node_modules/x.js")
	testing.expect_value(t, r.largest_files[1].kind, kinds.Kind.Cache)

	testing.expect_value(t, len(r.largest_directories), 2)
	testing.expect_value(t, r.largest_directories[0].path, "/r/proj")
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
		testing.expect_value(t, groups[0].items[0].path, "/r/proj/node_modules")
		testing.expect_value(t, groups[0].bytes, 100)
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
