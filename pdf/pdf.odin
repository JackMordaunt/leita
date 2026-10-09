/*
Package pdf writes PDF documents: pages of text, rectangles and lines, with fonts
embedded so the text reads the same everywhere and copies back out as typed.

	doc: pdf.Document
	pdf.init(&doc)
	defer pdf.destroy(&doc)
	sans, _ := pdf.add_font_file(&doc, "/usr/share/fonts/liberation/LiberationSans-Regular.ttf")
	pdf.add_page(&doc, pdf.A4)
	pdf.draw_text(&doc, 50, 60, "日本語のファイル.txt", sans, 12)
	pdf.fill_rect(&doc, 50, 70, 120, 6, {0.2, 0.4, 0.8})
	data := pdf.to_bytes(&doc)

Coordinates are points (1/72 in) from the page's top-left corner, y growing
down, as a report is laid out; a text's y is its baseline.

Text: any Unicode text can be drawn. A font is embedded as a Type 0 font with
Identity-H codes and a ToUnicode map, which a reader's search and copy turn
codes back into text by (ISO 32000-1, 9.10.2); pdftotext and pdf.js gave back
the demo's strings (pdf/demo) when checked by hand on 2026-10-09. Only the glyphs drawn are
embedded (subset.odin).
TrueType and CFF-flavoured OpenType fonts and collections are read; CFF2
(variable CFF) and bitmap-only fonts, such as colour emoji, are not. A rune
missing from a font is taken from its fallbacks (add_fallback), else drawn as
the font's .notdef box, and still copies out as itself. Text is laid out one
glyph per rune at the font's advance widths: no kerning, ligatures or
shaping, so Arabic and Indic scripts draw unjoined, and no bidi reordering, so
right-to-left text draws in logical order.

Output is PDF 1.7, its streams compressed with deflate (deflate.odin), and the
same for the same calls: nothing in it comes from the clock, the environment
or map order, so a test can compare whole files.

Memory: a Document allocates from the allocator init was given and frees it
all in destroy. Strings passed in are copied; font data passed to add_font is
borrowed. Writing allocates its working state in an arena of its own.
*/
package pdf

import "core:mem"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// Size is a page's width and height in points.
Size :: [2]f32

A4     :: Size{595.276, 841.89}
LETTER :: Size{612, 792}

// Color is red, green and blue, each from 0 to 1.
Color :: [3]f32

BLACK :: Color{0, 0, 0}

// Alignment says which end of a text its x names.
Alignment :: enum {
	Left,
	Center,
	Right,
}

// Info is the document's metadata, shown in a reader's properties. A field
// left empty, or a zero created, is left out.
Info :: struct {
	title, author, subject, creator, producer: string,
	created:                                   time.Time,
}

Document :: struct {
	allocator: mem.Allocator,
	info:      Info, // set through set_info, which copies it
	compress:  bool, // deflate streams; true from init
	fonts:     [dynamic]^Face,
	pages:     [dynamic]Page,
	page:      int, // the page drawn on, -1 before the first
}

@(private)
Page :: struct {
	size:    Size,
	content: [dynamic]byte,
	links:   [dynamic]Link,
}

@(private)
Link :: struct {
	rect: [4]f32, // left, bottom, right, top, in PDF space
	uri:  string,
}

init :: proc(doc: ^Document, allocator := context.allocator) {
	doc^ = {
		allocator = allocator,
		compress  = true,
		page      = -1,
		fonts     = make([dynamic]^Face, allocator),
		pages     = make([dynamic]Page, allocator),
	}
}

destroy :: proc(doc: ^Document) {
	for f in doc.fonts {
		face_destroy(f, doc.allocator)
	}
	delete(doc.fonts)
	for &p in doc.pages {
		delete(p.content)
		for l in p.links {
			delete(l.uri, doc.allocator)
		}
		delete(p.links)
	}
	delete(doc.pages)
	info_destroy(doc)
	doc^ = {}
}

// set_info sets the document's metadata to a copy of info.
set_info :: proc(doc: ^Document, info: Info) {
	info_destroy(doc)
	a := doc.allocator
	doc.info = {
		title    = strings.clone(info.title, a),
		author   = strings.clone(info.author, a),
		subject  = strings.clone(info.subject, a),
		creator  = strings.clone(info.creator, a),
		producer = strings.clone(info.producer, a),
		created  = info.created,
	}
}

@(private)
info_destroy :: proc(doc: ^Document) {
	a := doc.allocator
	delete(doc.info.title, a)
	delete(doc.info.author, a)
	delete(doc.info.subject, a)
	delete(doc.info.creator, a)
	delete(doc.info.producer, a)
	doc.info = {}
}

// add_page adds a page and draws on it from now on; it returns its index.
add_page :: proc(doc: ^Document, size := A4) -> int {
	append(
		&doc.pages,
		Page {
			size = size,
			content = make([dynamic]byte, doc.allocator),
			links = make([dynamic]Link, doc.allocator),
		},
	)
	doc.page = len(doc.pages) - 1
	return doc.page
}

// set_page draws on page index from now on, as a footer naming the page count
// is drawn once every page exists.
set_page :: proc(doc: ^Document, index: int) {
	if index >= 0 && index < len(doc.pages) {
		doc.page = index
	}
}

page_count :: proc(doc: ^Document) -> int {
	return len(doc.pages)
}

// page_size is the size of the page drawn on, A4 before the first page.
page_size :: proc(doc: ^Document) -> Size {
	if doc.page < 0 {
		return A4
	}
	return doc.pages[doc.page].size
}

// current is the page drawn on, an A4 page added for a draw before any.
@(private)
current :: proc(doc: ^Document) -> ^Page {
	if doc.page < 0 {
		add_page(doc)
	}
	return &doc.pages[doc.page]
}

// draw_text draws s with its baseline at y, starting, centred or ending at x as
// align says, and returns its width. Control characters are skipped.
draw_text :: proc(
	doc: ^Document,
	x, y: f32,
	s: string,
	font: Font,
	size: f32,
	color := BLACK,
	align := Alignment.Left,
) -> f32 {
	parts := [1]string{s}
	return draw_parts(doc, x, y, parts[:], font, size, color, align)
}

// text_width is how wide draw_text draws s.
text_width :: proc(doc: ^Document, s: string, font: Font, size: f32) -> f32 {
	if !font_ok(doc, font) {
		return 0
	}
	units := 0
	for r in s {
		if skipped(r) {
			continue
		}
		fnt, g := resolve(doc, font, r)
		units += width1000(doc.fonts[fnt], g)
	}
	return f32(units) * size / 1000
}

// fit is the longest prefix of s that, followed by an ellipsis, draws no
// wider than width, with the ellipsis; s itself and an empty ellipsis when s
// fits whole. The ellipsis is "…", or "..." where the font has no "…".
fit :: proc(
	doc: ^Document,
	s: string,
	font: Font,
	size, width: f32,
) -> (
	prefix, ellipsis: string,
) {
	if !font_ok(doc, font) || text_width(doc, s, font, size) <= width {
		return s, ""
	}
	ellipsis = "…"
	if _, g := resolve(doc, font, '…'); g == 0 {
		ellipsis = "..."
	}
	room := width - text_width(doc, ellipsis, font, size)
	used: f32
	end := 0
	for r, i in s {
		if !skipped(r) {
			fnt, g := resolve(doc, font, r)
			used += f32(width1000(doc.fonts[fnt], g)) * size / 1000
		}
		if used > room {
			break
		}
		end = i + utf8.rune_size(r)
	}
	return s[:end], ellipsis
}

// draw_text_fit draws s as draw_text does, cut short with an ellipsis where it would
// draw wider than width, and says whether it was.
draw_text_fit :: proc(
	doc: ^Document,
	x, y: f32,
	s: string,
	font: Font,
	size, width: f32,
	color := BLACK,
	align := Alignment.Left,
) -> (
	truncated: bool,
) {
	prefix, ellipsis := fit(doc, s, font, size, width)
	parts := [2]string{prefix, ellipsis}
	draw_parts(doc, x, y, parts[:], font, size, color, align)
	return ellipsis != ""
}

@(private)
skipped :: proc(r: rune) -> bool {
	return r < 0x20 || r == 0x7f
}

// resolve is the font that draws r, font or one of its fallbacks, and the
// glyph there; font and glyph 0 when none has it.
@(private)
resolve :: proc(doc: ^Document, font: Font, r: rune) -> (Font, u16) {
	f := doc.fonts[font]
	if g := glyph(f, r); g != 0 {
		return font, g
	}
	for fb in f.fallbacks {
		if g := glyph(doc.fonts[fb], r); g != 0 {
			return fb, g
		}
	}
	return font, 0
}

// cid is the code r is drawn with in f, given it the first time.
@(private)
cid :: proc(f: ^Face, r: rune) -> u16 {
	if c, ok := f.cids[r]; ok {
		return c
	}
	if len(f.runes) >= 0xfffe {
		return 0
	}
	append(&f.runes, r)
	c := u16(len(f.runes))
	f.cids[r] = c
	return c
}

@(private)
draw_parts :: proc(
	doc: ^Document,
	x, y: f32,
	parts: []string,
	font: Font,
	size: f32,
	color: Color,
	align: Alignment,
) -> f32 {
	if !font_ok(doc, font) {
		return 0
	}
	w: f32
	for s in parts {
		w += text_width(doc, s, font, size)
	}
	x := x
	switch align {
	case .Left:
	case .Center:
		x -= w / 2
	case .Right:
		x -= w
	}
	p := current(doc)
	out := &p.content
	put(out, "BT\n")
	put_color(out, color, "rg")
	put_num(out, x)
	put(out, " ")
	put_num(out, p.size.y - y)
	put(out, " Td\n")
	on := Font(-1)
	for s in parts {
		for r in s {
			if skipped(r) {
				continue
			}
			fnt, _ := resolve(doc, font, r)
			if fnt != on {
				if on >= 0 {
					put(out, "> Tj\n")
				}
				put(out, "/F")
				put_int(out, int(fnt))
				put(out, " ")
				put_num(out, size)
				put(out, " Tf\n<")
				on = fnt
			}
			put_hex16(out, cid(doc.fonts[fnt], r))
		}
	}
	if on >= 0 {
		put(out, "> Tj\n")
	}
	put(out, "ET\n")
	return w
}

// fill_rect fills the rectangle whose top-left corner is x, y.
fill_rect :: proc(doc: ^Document, x, y, w, h: f32, color: Color) {
	p := current(doc)
	out := &p.content
	put_color(out, color, "rg")
	put_rect(out, p, x, y, w, h)
	put(out, " re f\n")
}

// stroke_rect outlines the rectangle whose top-left corner is x, y, the
// line centred on its edges.
stroke_rect :: proc(doc: ^Document, x, y, w, h: f32, color: Color, line_width: f32 = 1) {
	p := current(doc)
	out := &p.content
	put_color(out, color, "RG")
	put_num(out, line_width)
	put(out, " w\n")
	put_rect(out, p, x, y, w, h)
	put(out, " re S\n")
}

stroke_line :: proc(doc: ^Document, x0, y0, x1, y1: f32, color: Color, line_width: f32 = 1) {
	p := current(doc)
	out := &p.content
	put_color(out, color, "RG")
	put_num(out, line_width)
	put(out, " w\n")
	put_num(out, x0)
	put(out, " ")
	put_num(out, p.size.y - y0)
	put(out, " m ")
	put_num(out, x1)
	put(out, " ")
	put_num(out, p.size.y - y1)
	put(out, " l S\n")
}

// add_link makes the rectangle whose top-left corner is x, y open uri when
// clicked.
add_link :: proc(doc: ^Document, x, y, w, h: f32, uri: string) {
	p := current(doc)
	append(
		&p.links,
		Link{{x, p.size.y - y - h, x + w, p.size.y - y}, strings.clone(uri, doc.allocator)},
	)
}

@(private)
put_rect :: proc(out: ^[dynamic]byte, p: ^Page, x, y, w, h: f32) {
	put_num(out, x)
	put(out, " ")
	put_num(out, p.size.y - y - h)
	put(out, " ")
	put_num(out, w)
	put(out, " ")
	put_num(out, h)
}

@(private)
put_color :: proc(out: ^[dynamic]byte, c: Color, op: string) {
	for v in c {
		put_num(out, clamp(v, 0, 1))
		put(out, " ")
	}
	put(out, op)
	put(out, "\n")
}
