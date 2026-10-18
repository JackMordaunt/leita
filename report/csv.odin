package report

import "base:runtime"
import "core:fmt"
import "core:strings"

import "../kinds"
import "../reclaim"

/*
write_csv writes r as one table, RFC 4180 with CRLF line endings, behind a UTF-8
byte order mark.

One table rather than one per section: a spreadsheet opens a CSV as one sheet,
and a report has several lists. Each row says which list it is in, so a filter
on the first column brings any of them back, and every column means the same
in every row:

	section       total, directory, file, kind, reclaim, or note
	rank          1 for the largest in its list; empty for total, kind and note
	name          the path; a kind's name; the note's text
	kind          what a directory or file is; a candidate's Reclaim category
	bytes         on disk, a whole number
	percent       of the target's bytes, to two places
	files         how many files: the target's, or a kind's
	bytes_before  in the scan compared with; empty when it kept none
	change        bytes less bytes_before

The byte order mark is written so that Excel takes the file as UTF-8 rather than
guessing an encoding, which would garble every name that is not ASCII. A program
reading the file as plain UTF-8 sees it as U+FEFF before the first header.

A cell holding a name from the disk, or the licensee, that starts = + - @ tab or CR, the leaders
OWASP's "CSV Injection" page (owasp.org/www-community/attacks/CSV_Injection)
says a spreadsheet may run as a formula, gets an apostrophe in front, since
whoever made a file chose its name. Numbers are written bare.
*/
write_csv :: proc(sb: ^strings.Builder, r: ^Report) {
	strings.write_string(sb, "\xef\xbb\xbf")
	row := Row{sb, 0}
	for header in CSV_HEADERS {
		cell_text(&row, header)
	}
	row_end(&row)

	row = {sb, 0}
	cell_text(&row, "total")
	cell_text(&row, "")
	cell_name(&row, r.target)
	cell_text(&row, "")
	cell_number(&row, r.bytes)
	cell_percent(&row, r, r.bytes)
	cell_number(&row, r.files)
	if c, ok := r.compared.?; ok {
		cell_number(&row, c.bytes)
		cell_signed(&row, i64(r.bytes) - i64(c.bytes))
	} else {
		cell_text(&row, "")
		cell_text(&row, "")
	}
	row_end(&row)

	csv_entries(sb, r, "directory", r.largest_directories)
	csv_entries(sb, r, "file", r.largest_files)
	for kind in kinds.Kind {
		k := r.kinds[kind]
		row = {sb, 0}
		cell_text(&row, "kind")
		cell_text(&row, "")
		cell_text(&row, kinds.NAMES[kind])
		cell_text(&row, "")
		cell_number(&row, k.bytes)
		cell_percent(&row, r, k.bytes)
		cell_number(&row, k.files)
		cell_text(&row, "")
		cell_text(&row, "")
		row_end(&row)
	}
	if groups, ok := r.reclaim.?; ok {
		for g in groups {
			for c, i in g.items {
				row = {sb, 0}
				cell_text(&row, "reclaim")
				cell_number(&row, u64(i + 1))
				cell_name(&row, c.path)
				cell_text(&row, reclaim.CATEGORY_NAMES[g.category])
				cell_number(&row, c.bytes)
				cell_percent(&row, r, c.bytes)
				cell_text(&row, "")
				cell_text(&row, "")
				cell_text(&row, "")
				row_end(&row)
			}
		}
	}
	if r.compared == nil {
		csv_note(sb, "No earlier scan to compare with.")
	}
	if retained, ok := r.retention.?; ok {
		state := "unchecked"
		switch retained.snapshots {
		case .None:
			state = "none"
		case .Present:
			state = "present"
		case .Unchecked:
		}
		csv_note(sb, fmt.tprintf("APFS local snapshots: %s", state))
		for name in retained.names {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			csv_note(sb, fmt.tprintf("Local snapshot: %s", name))
		}
		if bytes, known := retained.purgeable.?; known {
			csv_note(sb, fmt.tprintf("Purgeable space: %d bytes", bytes))
		} else {
			csv_note(sb, "Purgeable space: unknown")
		}
	}
	csv_note(sb, generated_by(r))
}

@(private)
CSV_HEADERS := [?]string {
	"section",
	"rank",
	"name",
	"kind",
	"bytes",
	"percent",
	"files",
	"bytes_before",
	"change",
}

@(private)
csv_entries :: proc(sb: ^strings.Builder, r: ^Report, section: string, entries: []Entry) {
	for e, i in entries {
		row := Row{sb, 0}
		cell_text(&row, section)
		cell_number(&row, u64(i + 1))
		cell_name(&row, e.path)
		cell_text(&row, kinds.NAMES[e.kind])
		cell_number(&row, e.bytes)
		cell_percent(&row, r, e.bytes)
		cell_text(&row, "")
		if was, ok := e.was.?; ok {
			delta, _ := change(e)
			cell_number(&row, was)
			cell_signed(&row, delta)
		} else {
			cell_text(&row, "")
			cell_text(&row, "")
		}
		row_end(&row)
	}
}

// csv_note writes a note row. The text is a name from outside as far as a
// spreadsheet is concerned, since the last note carries the licensee, so it
// is written as cell_name writes one.
@(private)
csv_note :: proc(sb: ^strings.Builder, text: string) {
	row := Row{sb, 0}
	cell_text(&row, "note")
	cell_text(&row, "")
	cell_name(&row, text)
	for _ in 3 ..< len(CSV_HEADERS) {
		cell_text(&row, "")
	}
	row_end(&row)
}

// Row is a record being written, and how many cells it has so far: each after
// the first follows a comma.
@(private)
Row :: struct {
	sb:    ^strings.Builder,
	cells: int,
}

@(private)
cell_start :: proc(row: ^Row) {
	if row.cells > 0 {
		strings.write_byte(row.sb, ',')
	}
	row.cells += 1
}

@(private)
row_end :: proc(row: ^Row) {
	strings.write_string(row.sb, "\r\n")
}

@(private)
cell_number :: proc(row: ^Row, n: u64) {
	cell_start(row)
	fmt.sbprintf(row.sb, "%d", n)
}

@(private)
cell_signed :: proc(row: ^Row, n: i64) {
	cell_start(row)
	fmt.sbprintf(row.sb, "%d", n)
}

// cell_percent writes bytes as a percentage of the target's, to two places.
@(private)
cell_percent :: proc(row: ^Row, r: ^Report, bytes: u64) {
	cell_start(row)
	fmt.sbprintf(row.sb, "%.2f", 100 * share(r, bytes))
}

// FORMULA_LEADERS are the first characters that can make a spreadsheet run a
// cell as a formula.
@(private)
FORMULA_LEADERS :: "=+-@\t\r"

// cell_name writes a name from the disk: readable, and kept from running as a
// formula.
@(private)
cell_name :: proc(row: ^Row, s: string) {
	defused := len(s) > 0 && strings.index_byte(FORMULA_LEADERS, s[0]) >= 0
	text := readable(s)
	if !defused && strings.index_any(text, ",\"\r\n") < 0 {
		cell_start(row)
		strings.write_string(row.sb, text)
		return
	}
	cell_quoted(row, "'" if defused else "", text)
}

// cell_text writes text leita chose, quoted only if it must be.
@(private)
cell_text :: proc(row: ^Row, s: string) {
	if strings.index_any(s, ",\"\r\n") < 0 {
		cell_start(row)
		strings.write_string(row.sb, s)
		return
	}
	cell_quoted(row, "", s)
}

// cell_quoted writes lead and s in quotes, a quote inside doubled, as RFC 4180
// has a field that holds a comma, a quote, a CR or a newline.
@(private)
cell_quoted :: proc(row: ^Row, lead, s: string) {
	cell_start(row)
	strings.write_byte(row.sb, '"')
	strings.write_string(row.sb, lead)
	for i in 0 ..< len(s) {
		if s[i] == '"' {
			strings.write_byte(row.sb, '"')
		}
		strings.write_byte(row.sb, s[i])
	}
	strings.write_byte(row.sb, '"')
}
