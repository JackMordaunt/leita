package report

import "base:runtime"

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "jm:timefmt"

import "../human"
import "../kinds"
import "../pdf"
import "../reclaim"

/*
write_pdf writes r as a printable document, laid out on paper in the HTML
report's order: what was scanned and when, its totals, the largest directories
and files, what it holds by kind, and Reclaim's groups when asked for. Every
page's foot names the target and says "Page n of N", and a table that runs
onto another page starts there again with its title and column heads.

Text is set in the machine's own fonts (pdf.add_system_fonts), embedded, with
the ToUnicode maps pdf writes: pdftotext gave back Latin, Cyrillic, CJK and
emoji names from one on 2026-10-09, the emoji drawn as boxes, having no font.
A path too long for its column is wrapped onto a second line (path_lines); one
too long for two keeps its start and its end, the middle left out for an
ellipsis, so the text layer holds that path cut, not whole. On a machine with
no font: No_Font, and nothing is written.
*/
write_pdf :: proc(w: io.Writer, r: ^Report, paper: Paper) -> Error {
	doc: pdf.Document
	pdf.init(&doc)
	defer pdf.destroy(&doc)
	p := Pen {
		doc   = &doc,
		r     = r,
		sheet = PAPER_SIZES[paper],
	}
	regular, ok := pdf.add_system_fonts(&doc, &p.bold)
	if !ok {
		return .No_Font
	}
	p.regular = regular
	p.left = MARGIN
	p.right = p.sheet.x - MARGIN
	p.bottom = p.sheet.y - FOOT
	pdf.set_info(
		&doc,
		{
			title = strings.concatenate(
				{"Disk report: ", readable(r.target)},
				context.temp_allocator,
			),
			subject = "Disk usage report",
			creator = strings.concatenate({"leita ", r.version}, context.temp_allocator),
			producer = "leita",
			created = r.generated,
		},
	)

	page(&p)
	pdf_header(&p)
	pdf_entries(&p, "Largest directories", r.largest_directories)
	pdf_entries(&p, "Largest files", r.largest_files)
	pdf_kinds(&p)
	if groups, asked := r.reclaim.?; asked {
		pdf_reclaim(&p, groups)
	}
	pdf_footers(&p)

	if err := pdf.write(&doc, w); err != nil {
		return .Write_Failed
	}
	return .None
}

// Paper is the sheet a PDF is laid out on.
Paper :: enum u8 {
	A4,
	Letter,
}

PAPER_NAMES := [Paper]string {
	.A4     = "a4",
	.Letter = "letter",
}

@(private)
PAPER_SIZES := [Paper]pdf.Size {
	.A4     = pdf.A4,
	.Letter = pdf.LETTER,
}

// paper_named is the paper a name says, as the command line takes it.
paper_named :: proc(name: string) -> (Paper, bool) {
	for p in Paper {
		if strings.equal_fold(name, PAPER_NAMES[p]) {
			return p, true
		}
	}
	return {}, false
}

/*
paper_of_locale is the paper the user's locale prints on: Letter where the
locale that decides paper (LC_ALL, else LC_PAPER, else LANG, the order setlocale(3)
gives them) names a region that prints on it, else A4, as it is where none
is set.
*/
paper_of_locale :: proc() -> Paper {
	locale := os.get_env("LC_ALL", context.temp_allocator)
	if locale == "" {
		locale = os.get_env("LC_PAPER", context.temp_allocator)
	}
	if locale == "" {
		locale = os.get_env("LANG", context.temp_allocator)
	}
	return paper_of(locale)
}

/*
paper_of is the paper a POSIX locale name prints on. The regions are those of
glibc's localedata whose LC_PAPER is 279 mm high or copies one that is, found by
reading each locale's LC_PAPER (glibc 2.44, read 2026-10-09): every locale of BO, CA,
CL, CO, CR, GT, MX, NI, PA, PH, PR, SV, US and VE but miq_NI and nhn_MX, taken
here by region, and of South Africa en_ZA alone.
*/
@(private)
paper_of :: proc(locale: string) -> Paper {
	if strings.has_prefix(locale, "en_ZA") {
		return .Letter
	}
	region := locale
	if i := strings.index_byte(region, '_'); i >= 0 {
		region = region[i + 1:]
	} else {
		return .A4
	}
	if i := strings.index_any(region, ".@"); i >= 0 {
		region = region[:i]
	}
	letter := []string {
		"BO",
		"CA",
		"CL",
		"CO",
		"CR",
		"GT",
		"MX",
		"NI",
		"PA",
		"PH",
		"PR",
		"SV",
		"US",
		"VE",
	}
	for r in letter {
		if region == r {
			return .Letter
		}
	}
	return .A4
}

// The page's margins and the room its foot takes, in points: 48 is 17 mm.
@(private)
MARGIN :: f32(48)
@(private)
FOOT :: f32(56)

// Type sizes, in points.
@(private)
TITLE_SIZE :: f32(20)
@(private)
HEADING_SIZE :: f32(12)
@(private)
BODY_SIZE :: f32(8.5)
@(private)
SMALL_SIZE :: f32(7.5)

// A table row: one line of BODY_SIZE text, and LINE more for each a path wraps onto.
@(private)
ROW :: f32(15)
@(private)
LINE :: f32(10.5)

// The gap between a table's columns.
@(private)
GUTTER :: f32(8)

// The colours: near-black ink, a muted grey for what supports it, hairlines,
// and the HTML report's print palette for bars and change.
@(private)
INK :: pdf.Color{0.12, 0.14, 0.16}
@(private)
MUTED :: pdf.Color{0.36, 0.4, 0.45}
@(private)
RULE :: pdf.Color{0.78, 0.82, 0.86}
@(private)
HAIRLINE :: pdf.Color{0.89, 0.91, 0.93}
@(private)
BAR :: pdf.Color{0.18, 0.39, 0.65}
@(private)
TRACK :: pdf.Color{0.9, 0.92, 0.95}
@(private)
GREW :: pdf.Color{0.6, 0.27, 0}
@(private)
SHRANK :: pdf.Color{0.02, 0.31, 0.68}

// Pen is where the PDF is being drawn: the document, its fonts and the page's
// edges, how far down the page it has come, and the table being drawn, which
// a page break starts again.
@(private)
Pen :: struct {
	doc:                 ^pdf.Document,
	r:                   ^Report,
	regular, bold:       pdf.Font,
	sheet:               pdf.Size,
	left, right, bottom: f32,
	y:                   f32, // the top of what is drawn next
	table:               Maybe(Table),
}

// Column is one column of a table: its head, width (0 for the one that takes
// what the others leave), which side its text keeps to, and where it starts,
// set by columns.
@(private)
Column :: struct {
	head:  string,
	width: f32,
	align: pdf.Alignment,
	x:     f32,
}

@(private)
Table :: struct {
	title:   string,
	columns: []Column,
}

// page starts a new page, the table being drawn starting again at its top.
@(private)
page :: proc(p: ^Pen) {
	pdf.add_page(p.doc, p.sheet)
	p.y = MARGIN
	if t, ok := p.table.?; ok {
		pdf.draw_text(
			p.doc,
			p.left,
			p.y + 10,
			fmt.tprintf("%s (continued)", t.title),
			p.bold,
			10,
			INK,
		)
		p.y += 18
		table_head(p, t.columns)
	}
}

// make_room starts a new page unless h more points fit on this one.
@(private)
make_room :: proc(p: ^Pen, h: f32) {
	if p.y + h > p.bottom {
		page(p)
	}
}

// columns lays cols across the page, the flexible one taking what is left.
@(private)
columns :: proc(p: ^Pen, cols: []Column) -> []Column {
	fixed: f32
	for c in cols {
		fixed += c.width
	}
	flex := p.right - p.left - fixed - GUTTER * f32(len(cols) - 1)
	x := p.left
	for &c in cols {
		if c.width == 0 {
			c.width = flex
		}
		c.x = x
		x += c.width + GUTTER
	}
	return cols
}

// heading draws a section's title, keeping it on a page with what follows: at
// least `with` points of it.
@(private)
heading :: proc(p: ^Pen, title: string, with: f32) {
	p.table = nil
	make_room(p, 30 + with)
	p.y += 12
	pdf.draw_text(p.doc, p.left, p.y + HEADING_SIZE, title, p.bold, HEADING_SIZE, INK)
	p.y += 20
}

// table_head draws the columns' heads over a rule.
@(private)
table_head :: proc(p: ^Pen, cols: []Column) {
	for c in cols {
		pdf.draw_text(p.doc, anchor(c), p.y + 8, c.head, p.bold, SMALL_SIZE, MUTED, c.align)
	}
	pdf.stroke_line(p.doc, p.left, p.y + 12, p.right, p.y + 12, RULE, 0.75)
	p.y += 13
}

// table opens a table under the section just headed: its heads now, and again
// on each page it runs onto.
@(private)
table :: proc(p: ^Pen, title: string, cols: []Column) {
	table_head(p, cols)
	p.table = Table{title, cols}
}

// anchor is the x a column's text is drawn from, for its alignment.
@(private)
anchor :: proc(c: Column) -> f32 {
	switch c.align {
	case .Right:
		return c.x + c.width
	case .Center:
		return c.x + c.width / 2
	case .Left:
	}
	return c.x
}

// row makes room for row i of n, h high, and returns the baseline of its first
// line, drawing the hairline under it. The last row never goes onto a page by
// itself: the one before it goes too.
@(private)
row :: proc(p: ^Pen, h: f32, i, n: int) -> f32 {
	make_room(p, h + (ROW if i == n - 2 else 0))
	base := p.y + 10
	pdf.stroke_line(p.doc, p.left, p.y + h - 0.5, p.right, p.y + h - 0.5, HAIRLINE, 0.5)
	p.y += h
	return base
}

// cell draws s in c at baseline y.
@(private)
cell :: proc(p: ^Pen, c: Column, y: f32, s: string, color := INK, font := pdf.Font(-1)) {
	f := p.regular if font < 0 else font
	pdf.draw_text_fit(p.doc, anchor(c), y, s, f, BODY_SIZE, c.width, color, c.align)
}

// share_cell draws bytes' share of the report in c: a bar, and its
// percentage at the column's end.
@(private)
share_cell :: proc(p: ^Pen, c: Column, y: f32, bytes: u64) {
	s := share(p.r, bytes)
	bar := c.width - 32
	pdf.fill_rect(p.doc, c.x, y - 6, bar, 6, TRACK)
	if s > 0 {
		pdf.fill_rect(p.doc, c.x, y - 6, max(f32(s) * bar, 0.75), 6, BAR)
	}
	pdf.draw_text(
		p.doc,
		c.x + c.width,
		y,
		fmt.tprintf("%.1f%%", 100 * s),
		p.regular,
		SMALL_SIZE,
		MUTED,
		.Right,
	)
}

/*
path_lines is how a path is drawn in width at size: whole on one line when it
fits; else on two, the first as much as fits and the second the rest. Where
the rest would fit as well, the first ends after its last separator instead,
so the break falls between names. Where the rest does not fit, the second is
an ellipsis and as much of the rest's end as fits, so the name at the end is
always seen and only the middle is lost.
*/
@(private)
path_lines :: proc(
	p: ^Pen,
	path: string,
	width: f32,
	size := BODY_SIZE,
) -> (
	first, second: string,
) {
	if measure(p, path, size) <= width {
		return path, ""
	}
	end := len(head(p, path, width, size))
	if end == 0 {
		return path, ""
	}
	if cut := strings.last_index_any(path[:end], `/\`);
	   cut > 0 && measure(p, path[cut + 1:], size) <= width {
		end = cut + 1
	}
	first, second = path[:end], path[end:]
	if measure(p, second, size) <= width {
		return
	}
	rest := tail(p, second, width - measure(p, "…", size), size)
	return first, strings.concatenate({"…", rest}, context.temp_allocator)
}

@(private)
measure :: proc(p: ^Pen, s: string, size: f32) -> f32 {
	return pdf.text_width(p.doc, s, p.regular, size)
}

// head is the longest start of s that draws no wider than width at size.
@(private)
head :: proc(p: ^Pen, s: string, width, size: f32) -> string {
	used: f32
	end := 0
	for r, i in s {
		buf, n := utf8.encode_rune(r)
		used += measure(p, string(buf[:n]), size)
		if used > width {
			break
		}
		end = i + n
	}
	return s[:end]
}

// tail is the longest end of s that draws no wider than width at size.
@(private)
tail :: proc(p: ^Pen, s: string, width, size: f32) -> string {
	used: f32
	start := len(s)
	for start > 0 {
		r, n := utf8.decode_last_rune_in_string(s[:start])
		buf, m := utf8.encode_rune(r)
		used += measure(p, string(buf[:m]), size)
		if used > width {
			break
		}
		start -= n
	}
	return s[start:]
}

// wrap breaks s into lines no wider than width at its spaces.
@(private)
wrap :: proc(p: ^Pen, s: string, font: pdf.Font, size, width: f32) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	start, last_space := 0, -1
	for i := 0; i <= len(s); i += 1 {
		if i < len(s) && s[i] != ' ' {
			continue
		}
		if pdf.text_width(p.doc, s[start:i], font, size) > width && last_space > start {
			append(&lines, s[start:last_space])
			start = last_space + 1
		}
		last_space = i
	}
	if start < len(s) {
		append(&lines, s[start:])
	}
	return lines[:]
}

// prose draws s wrapped to the page's width, and moves down past it.
@(private)
prose :: proc(p: ^Pen, s: string, size: f32, color: pdf.Color) {
	lead := size * 1.4
	for line in wrap(p, s, p.regular, size, p.right - p.left) {
		make_room(p, lead)
		pdf.draw_text(p.doc, p.left, p.y + size, line, p.regular, size, color)
		p.y += lead
	}
}

// when_ is t as a person reads it on a ticket: to the second, in UTC.
@(private)
when_ :: proc(t: time.Time) -> string {
	return timefmt.format(t, "%Y-%m-%d %H:%M:%S UTC", context.temp_allocator)
}

// Fact is one figure in the header's grid: what it is, its value, and a line
// under that.
@(private)
Fact :: struct {
	term, value, under: string,
}

@(private)
pdf_header :: proc(p: ^Pen) {
	r := p.r
	doc := p.doc
	pdf.draw_text(doc, p.left, p.y + 18, "Disk report", p.bold, TITLE_SIZE, INK)
	pdf.draw_text(
		doc,
		p.right,
		p.y + 18,
		fmt.tprintf("leita %s", r.version),
		p.regular,
		SMALL_SIZE,
		MUTED,
		.Right,
	)
	p.y += 28

	// The target, whole where it fits on two lines.
	first, second := path_lines(p, readable(r.target), p.right - p.left, BODY_SIZE + 2)
	pdf.draw_text(doc, p.left, p.y + 9, first, p.regular, BODY_SIZE + 2, INK)
	p.y += 14
	if second != "" {
		pdf.draw_text(doc, p.left, p.y + 9, second, p.regular, BODY_SIZE + 2, INK)
		p.y += 14
	}

	sb := strings.builder_make(context.temp_allocator)
	if r.started != {} {
		fmt.sbprintf(&sb, "Scanned %s, ", when_(r.started))
	}
	fmt.sbprintf(&sb, "in %s", timefmt.duration(r.duration, context.temp_allocator))
	if engine := ENGINE_KEYS[r.engine]; engine != "" {
		fmt.sbprintf(&sb, " by %s", "reading the MFT" if r.engine == .Mft else engine)
	}
	fmt.sbprintf(&sb, ". Generated by leita %s on %s.", r.version, when_(r.generated))
	prose(p, strings.to_string(sb), SMALL_SIZE + 0.5, MUTED)
	p.y += 6

	facts := make([dynamic]Fact, context.temp_allocator)
	append(
		&facts,
		Fact{"On disk", human.bytes(r.bytes), fmt.tprintf("%s bytes", human.count(r.bytes))},
	)
	append(&facts, Fact{"Files", human.count(r.files), ""})
	append(&facts, Fact{"Directories", human.count(r.directories), ""})
	if space, ok := r.space.?; ok {
		used := 100 * (1 - f64(space.free) / f64(max(space.total, 1)))
		append(
			&facts,
			Fact {
				"Free space",
				human.bytes(space.free),
				fmt.tprintf("of %s, %.0f%% used", human.bytes(space.total), used),
			},
		)
	}
	if fs := FILESYSTEM_NAMES[r.filesystem]; fs != "" {
		append(&facts, Fact{"Filesystem", fs, ""})
	}
	if r.volume != "" {
		append(&facts, Fact{"Volume", readable(r.volume), ""})
	}
	if c, ok := r.compared.?; ok {
		append(
			&facts,
			Fact {
				"Compared with",
				timefmt.format(c.taken, "%Y-%m-%d %H:%M", context.temp_allocator),
				fmt.tprintf("UTC, a scan of %s", human.bytes(c.bytes)),
			},
		)
	} else {
		append(&facts, Fact{"Compared with", "None", "no earlier scan was kept"})
	}

	// Four to a row, each a box of the same height.
	across :: 4
	gap    :: f32(8)
	box := (p.right - p.left - gap * (across - 1)) / across
	for f, i in facts {
		if i > 0 && i % across == 0 {
			p.y += 44 + gap
		}
		x := p.left + f32(i % across) * (box + gap)
		pdf.stroke_rect(doc, x, p.y, box, 44, RULE, 0.5)
		pdf.draw_text(doc, x + 8, p.y + 12, f.term, p.regular, SMALL_SIZE, MUTED)
		pdf.draw_text_fit(doc, x + 8, p.y + 26, f.value, p.bold, 11, box - 16, INK)
		if f.under != "" {
			pdf.draw_text_fit(
				doc,
				x + 8,
				p.y + 37,
				f.under,
				p.regular,
				SMALL_SIZE - 0.5,
				box - 16,
				MUTED,
			)
		}
	}
	p.y += 44 + 4
}

// pdf_entries is a table of the largest directories or files, with what each
// changed by when there is a scan to compare with.
@(private)
pdf_entries :: proc(p: ^Pen, title: string, entries: []Entry) {
	heading(p, title, 13 + 2 * ROW)
	if len(entries) == 0 {
		prose(p, "None.", BODY_SIZE, MUTED)
		return
	}
	compared := p.r.compared != nil
	cols := make([dynamic]Column, context.temp_allocator)
	append(&cols, Column{head = "#", width = 16, align = .Right})
	append(&cols, Column{head = "Path"})
	append(&cols, Column{head = "Kind", width = 50})
	append(&cols, Column{head = "Size", width = 50, align = .Right})
	append(&cols, Column{head = "Share", width = 82})
	if compared {
		append(&cols, Column{head = "Change", width = 52, align = .Right})
	}
	c := columns(p, cols[:])
	table(p, title, c)
	for e, i in entries {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		first, second := path_lines(p, readable(e.path), c[1].width)
		y := row(p, ROW + (LINE if second != "" else 0), i, len(entries))
		cell(p, c[0], y, fmt.tprintf("%d", i + 1), MUTED)
		pdf.draw_text(p.doc, c[1].x, y, first, p.regular, BODY_SIZE, INK)
		if second != "" {
			pdf.draw_text(p.doc, c[1].x, y + LINE, second, p.regular, BODY_SIZE, INK)
		}
		cell(p, c[2], y, kinds.NAMES[e.kind], MUTED)
		cell(p, c[3], y, human.bytes(e.bytes))
		share_cell(p, c[4], y, e.bytes)
		if compared {
			if delta, ok := change(e); ok {
				switch {
				case delta > 0:
					cell(p, c[5], y, fmt.tprintf("+%s", human.bytes(u64(delta))), GREW)
				case delta < 0:
					cell(p, c[5], y, fmt.tprintf("−%s", human.bytes(u64(-delta))), SHRANK)
				case:
					cell(p, c[5], y, "no change", MUTED)
				}
			} else {
				cell(p, c[5], y, "new", MUTED)
			}
		}
	}
	if compared {
		p.y += 4
		prose(
			p,
			"Change is since the scan compared with; new is an entry it did not keep: under 1 MiB then, or not there.",
			SMALL_SIZE,
			MUTED,
		)
	}
}

@(private)
pdf_kinds :: proc(p: ^Pen) {
	// At most one row a kind, so kept whole on one page.
	shown := 0
	for k in p.r.kinds {
		shown += 0 if k.bytes == 0 && k.files == 0 else 1
	}
	heading(p, "By kind", 13 + f32(shown) * ROW)
	cols := []Column {
		{head = "Kind"},
		{head = "Files", width = 70, align = .Right},
		{head = "Size", width = 60, align = .Right},
		{head = "Share", width = 200},
	}
	c := columns(p, cols)
	table(p, "By kind", c)
	for kind in kinds.Kind {
		k := p.r.kinds[kind]
		if k.bytes == 0 && k.files == 0 {
			continue
		}
		y := row(p, ROW, 0, 0)
		cell(p, c[0], y, kinds.NAMES[kind])
		cell(p, c[1], y, human.count(k.files), MUTED)
		cell(p, c[2], y, human.bytes(k.bytes))
		share_cell(p, c[3], y, k.bytes)
	}
}

@(private)
pdf_reclaim :: proc(p: ^Pen, groups: []Group) {
	heading(p, "Reclaim", 2 * LINE + 40 + 13 + 2 * ROW)
	total: u64
	for g in groups {
		total += g.bytes
	}
	if len(groups) == 0 {
		prose(p, "Nothing found that can be deleted and made again.", BODY_SIZE, MUTED)
		return
	}
	prose(
		p,
		fmt.tprintf(
			"%s can be deleted without losing anything: each is made again by the tool that made it.",
			human.bytes(total),
		),
		BODY_SIZE,
		MUTED,
	)
	for g in groups {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		name := reclaim.CATEGORY_NAMES[g.category]
		p.table = nil
		make_room(p, 40 + 13 + 2 * ROW)
		p.y += 10
		w := pdf.draw_text(p.doc, p.left, p.y + 10, name, p.bold, 10, INK)
		pdf.draw_text(p.doc, p.left + w + 6, p.y + 10, human.bytes(g.bytes), p.regular, 10, MUTED)
		p.y += 15
		prose(p, reclaim.CATEGORY_REASONS[g.category], SMALL_SIZE, MUTED)
		p.y += 2
		cols := []Column {
			{head = "#", width = 16, align = .Right},
			{head = "Path"},
			{head = "Size", width = 50, align = .Right},
			{head = "Share", width = 82},
		}
		c := columns(p, cols)
		table(p, fmt.tprintf("Reclaim: %s", name), c)
		for item, i in g.items {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			first, second := path_lines(p, readable(item.path), c[1].width)
			y := row(p, ROW + (LINE if second != "" else 0), i, len(g.items))
			cell(p, c[0], y, fmt.tprintf("%d", i + 1), MUTED)
			pdf.draw_text(p.doc, c[1].x, y, first, p.regular, BODY_SIZE, INK)
			if second != "" {
				pdf.draw_text(p.doc, c[1].x, y + LINE, second, p.regular, BODY_SIZE, INK)
			}
			cell(p, c[2], y, human.bytes(item.bytes))
			share_cell(p, c[3], y, item.bytes)
		}
	}
	// Its tables' titles were made in the loop, and are gone with it.
	p.table = nil
}

// pdf_footers draws every page's foot, now that the pages are counted: the
// target, and which page of how many.
@(private)
pdf_footers :: proc(p: ^Pen) {
	n := pdf.page_count(p.doc)
	for i in 0 ..< n {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		pdf.set_page(p.doc, i)
		y := p.sheet.y - 30
		pdf.stroke_line(p.doc, p.left, y - 12, p.right, y - 12, HAIRLINE, 0.5)
		number := fmt.tprintf("Page %d of %d", i + 1, n)
		w := pdf.draw_text(p.doc, p.right, y, number, p.regular, SMALL_SIZE, MUTED, .Right)
		pdf.draw_text_fit(
			p.doc,
			p.left,
			y,
			fmt.tprintf("Disk report of %s", readable(p.r.target)),
			p.regular,
			SMALL_SIZE,
			p.right - p.left - w - 24,
			MUTED,
		)
	}
}
