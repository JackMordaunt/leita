package pdf

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// ASCII is Arimo's ASCII glyphs (SIL OFL, its licence beside it), the font
// jm's shaper tests with: small, and the same on every machine.
@(private)
ASCII := #load("../jm/ui/shape/testdata/ascii.ttf", []byte)

// xref_ok checks data's cross-reference table: startxref names it, and every
// entry it lists is where that object begins.
@(private)
xref_ok :: proc(t: ^testing.T, data: []byte, loc := #caller_location) -> bool {
	s := string(data)
	testing.expect(t, strings.has_prefix(s, "%PDF-1.7\n"), loc = loc) or_return
	testing.expect(t, strings.has_suffix(s, "%%EOF\n"), loc = loc) or_return
	sx := strings.last_index(s, "startxref\n")
	testing.expect(t, sx > 0, loc = loc) or_return
	nl := strings.index_byte(s[sx + 10:], '\n')
	xref, _ := strconv.parse_int(s[sx + 10:][:nl])
	testing.expect(t, strings.has_prefix(s[xref:], "xref\n0 "), loc = loc) or_return
	rest := s[xref + 7:]
	nl = strings.index_byte(rest, '\n')
	count, _ := strconv.parse_int(rest[:nl])
	entries := rest[nl + 1:]
	testing.expect(t, strings.has_prefix(entries, "0000000000 65535 f \n"), loc = loc) or_return
	for n in 1 ..< count {
		entry := entries[20 * n:][:20]
		testing.expectf(
			t,
			strings.has_suffix(entry, " 00000 n \n"),
			"entry %d: %q",
			n,
			entry,
			loc = loc,
		) or_return
		off, _ := strconv.parse_int(entry[:10])
		want := fmt.tprintf("%d 0 obj\n", n)
		testing.expectf(
			t,
			strings.has_prefix(s[off:], want),
			"object %d is not at %d",
			n,
			off,
			loc = loc,
		) or_return
	}
	trailer := entries[20 * count:]
	testing.expect(
		t,
		strings.has_prefix(trailer, fmt.tprintf("trailer\n<< /Size %d ", count)),
		loc = loc,
	)
	return true
}

@(private)
contains :: proc(data: []byte, s: string) -> bool {
	return bytes.contains(data, transmute([]byte)s)
}

@(test)
xref_offsets_name_each_object :: proc(t: ^testing.T) {
	doc: Document
	init(&doc)
	defer destroy(&doc)
	font, err := add_font(&doc, ASCII)
	testing.expect_value(t, err, Font_Error.None)
	add_page(&doc)
	draw_text(&doc, 50, 50, "Hello (world)", font, 12)
	add_link(&doc, 50, 40, 60, 12, "https://example.com/a(b)")
	add_page(&doc, LETTER)
	fill_rect(&doc, 10, 10, 100, 5, {0.2, 0.4, 0.8})
	data := to_bytes(&doc)
	defer delete(data)
	xref_ok(t, data)
	testing.expect(t, contains(data, "/Count 2"))
	testing.expect(t, contains(data, "/MediaBox [0 0 612 792]"))
	testing.expect(t, contains(data, "/URI (https://example.com/a\\(b\\))"))
}

@(test)
strings_are_escaped :: proc(t: ^testing.T) {
	out: [dynamic]byte
	defer delete(out)
	put_literal(&out, "a(b)\\c\n\xff")
	testing.expect_value(t, string(out[:]), `(a\(b\)\\c\012\377)`)
	clear(&out)
	put_text_string(&out, "Disk report")
	testing.expect_value(t, string(out[:]), "(Disk report)")
	clear(&out)
	put_text_string(&out, "Größe 😀")
	testing.expect_value(t, string(out[:]), "<FEFF0047007200F600DF00650020D83DDE00>")
	clear(&out)
	for v in ([?]f32{0, 12, 1.5, -2.25, 595.276, -0.0001, 0.1}) {
		put_num(&out, v)
		put(&out, " ")
	}
	testing.expect_value(t, string(out[:]), "0 12 1.5 -2.25 595.276 0 0.1 ")
	clear(&out)
	put_date(&out, time.unix(1791547200, 0))
	testing.expect_value(t, string(out[:]), "(D:20261009120000Z)")
}

// A rune the font lacks draws as .notdef but keeps a CID of its own, so the
// ToUnicode map still gives it back.
@(test)
missing_glyphs_copy_out_as_themselves :: proc(t: ^testing.T) {
	doc: Document
	init(&doc)
	defer destroy(&doc)
	doc.compress = false
	font, _ := add_font(&doc, ASCII)
	draw_text(&doc, 50, 50, "a日😀é a", font, 12)
	f := doc.fonts[font]
	testing.expect_value(t, len(f.runes), 5)
	testing.expect_value(t, glyph(f, '日'), 0)
	data := to_bytes(&doc)
	defer delete(data)
	xref_ok(t, data)
	testing.expect(t, contains(data, "<0001> <0061>"))
	testing.expect(t, contains(data, "<0002> <65E5>"))
	testing.expect(t, contains(data, "<0003> <D83DDE00>"))
	testing.expect(t, contains(data, "<0004> <00E9>"))
	testing.expect(t, contains(data, "<000100020003000400050001>"))
}

@(test)
text_measures_and_fits :: proc(t: ^testing.T) {
	doc: Document
	init(&doc)
	defer destroy(&doc)
	font, _ := add_font(&doc, ASCII)
	w := text_width(&doc, "MMMM", font, 10)
	testing.expect(t, w > 20 && w < 40)
	testing.expect_value(t, text_width(&doc, "MM", font, 20), w)
	prefix, ellipsis := fit(&doc, "MMMM", font, 10, w)
	testing.expect_value(t, prefix, "MMMM")
	testing.expect_value(t, ellipsis, "")
	prefix, ellipsis = fit(&doc, "MMMM", font, 10, w - 1)
	testing.expect_value(t, ellipsis, "...") // Arimo's ASCII glyphs have no "…"
	testing.expect(
		t,
		text_width(&doc, prefix, font, 10) + text_width(&doc, ellipsis, font, 10) <= w - 1,
	)
	testing.expect(t, len(prefix) < 4)
	prefix, _ = fit(&doc, "MMMM", font, 10, 0)
	testing.expect_value(t, prefix, "")
	m := font_metrics(&doc, font, 10)
	testing.expect(t, m.ascent > 5 && m.descent > 0 && m.line_height >= m.ascent + m.descent)
}

@(test)
empty_documents_still_open :: proc(t: ^testing.T) {
	doc: Document
	init(&doc)
	defer destroy(&doc)
	data := to_bytes(&doc)
	defer delete(data)
	xref_ok(t, data)
	testing.expect(t, contains(data, "/Count 1"))

	// A font never drawn with is not embedded.
	add_font(&doc, ASCII)
	add_page(&doc)
	draw_text(&doc, 0, 0, "", 0, 12)
	again := to_bytes(&doc)
	defer delete(again)
	xref_ok(t, again)
	testing.expect(t, !contains(again, "FontFile"))

	// A bad font is refused, and a bad handle draws nothing.
	_, err := add_font(&doc, ASCII[:100])
	testing.expect_value(t, err, Font_Error.Malformed)
	testing.expect_value(t, draw_text(&doc, 0, 0, "x", 7, 12), 0)
}

// A table of 300 rows, 40 to a page, on 8 pages; written twice, the same bytes.
@(test)
long_tables_span_pages_and_write_the_same_twice :: proc(t: ^testing.T) {
	render :: proc() -> []byte {
		doc: Document
		init(&doc)
		defer destroy(&doc)
		set_info(
			&doc,
			{title = "Table", producer = "pdf test", created = time.unix(1791547200, 0)},
		)
		font, _ := add_font(&doc, ASCII)
		for row in 0 ..< 300 {
			if row % 40 == 0 {
				add_page(&doc)
			}
			y := 60 + f32(row % 40) * 18
			draw_text(&doc, 40, y, fmt.tprintf("file-%03d.bin", row), font, 10)
			draw_text(&doc, 555, y, fmt.tprintf("%d KiB", row * 37), font, 10, align = .Right)
			fill_rect(&doc, 300, y - 8, f32(row % 100) * 1.5, 8, {0.3, 0.5, 0.9})
			stroke_line(&doc, 40, y + 4, 555, y + 4, {0.8, 0.8, 0.8}, 0.5)
		}
		return to_bytes(&doc)
	}
	a := render()
	defer delete(a)
	b := render()
	defer delete(b)
	xref_ok(t, a)
	testing.expect(t, contains(a, "/Count 8"))
	testing.expect(t, contains(a, "/CreationDate (D:20261009120000Z)"))
	testing.expect(t, bytes.equal(a, b), "the same document wrote different bytes")
}

// The TrueType subset keeps the glyphs drawn, glyph ids unchanged, and drops
// the rest.
@(test)
truetype_subsets_keep_only_drawn_glyphs :: proc(t: ^testing.T) {
	doc: Document
	init(&doc)
	defer destroy(&doc)
	font, _ := add_font(&doc, ASCII)
	f := doc.fonts[font]
	a, z := glyph(f, 'A'), glyph(f, 'z')
	out: [dynamic]byte
	defer delete(out)
	used := [1]u16{a}
	subset_truetype(f, used[:], &out)
	testing.expect(t, len(out) < len(ASCII))

	sub: Document
	init(&sub)
	defer destroy(&sub)
	sf, err := add_font(&sub, out[:])
	testing.expect_value(t, err, Font_Error.None)
	s := sub.fonts[sf]
	testing.expect_value(t, s.glyph_count, f.glyph_count)
	testing.expect(t, bytes.equal(glyph_bytes(s, a), glyph_bytes(f, a)))
	testing.expect(t, len(glyph_bytes(s, z)) == 0 && len(glyph_bytes(f, z)) > 0)
	testing.expect_value(t, sfnt_checksum(out[:]), 0xB1B0AFBA)
}

// Latin, accented, CJK and emoji text in the fonts this machine has: the CJK
// is set in the fallback when there is one, and the CFF subset holds the
// glyphs drawn, with no subroutines left. Skipped where no system font is.
@(test)
unicode_text_in_system_fonts :: proc(t: ^testing.T) {
	doc: Document
	init(&doc)
	defer destroy(&doc)
	// A machine with none of SYSTEM_FONTS cannot set a report: that fails.
	font, ok := add_system_fonts(&doc)
	if !testing.expect(t, ok, "add_system_fonts found none of SYSTEM_FONTS") {
		return
	}
	add_page(&doc)
	lines := [?]string {
		"Latin: report.txt",
		"Accented: Größe, café, Ærøskøbing",
		"CJK: 日本語のファイル.txt",
		"Emoji: 😀 📁",
	}
	for s, i in lines {
		draw_text(&doc, 50, 60 + 20 * f32(i), s, font, 12)
	}
	data := to_bytes(&doc)
	defer delete(data)
	xref_ok(t, data)

	cjk := Font(-1)
	for fb in doc.fonts[font].fallbacks {
		if len(doc.fonts[fb].runes) > 0 {
			cjk = fb
		}
	}
	if cjk < 0 {
		log.info("no CJK font: CJK checks skipped")
		return
	}
	f := doc.fonts[cjk]
	testing.expect_value(t, len(f.runes), 8) // 日本語のファイル
	log.infof("CJK set in a %v font, %d glyphs", f.outlines, f.glyph_count)
	if f.outlines != .CFF {
		log.info("CJK font is not CFF: CFF subset checks skipped")
		return
	}
	gids := make([]u16, len(f.runes) + 1)
	defer delete(gids)
	for r, i in f.runes {
		gids[i + 1] = glyph(f, r)
	}
	out: [dynamic]byte
	defer delete(out)
	testing.expect(t, subset_cff(f, gids, &out))
	testing.expect(t, len(out) < 20_000)
	names, _ := cff_index(out[:], 4)
	tops, _ := cff_index(out[:], names.end)
	strs, _ := cff_index(out[:], tops.end)
	gsubrs, _ := cff_index(out[:], strs.end)
	testing.expect_value(t, gsubrs.count, 0)
	top, _ := cff_dict(cff_item(tops, 0))
	cs, _ := cff_index(out[:], dict_find(&top, 17).args[0])
	testing.expect_value(t, cs.count, len(gids))
	for i in 1 ..< cs.count {
		g := cff_item(cs, i)
		testing.expect(t, len(g) > 10 && g[len(g) - 1] == 14, "a drawn glyph lost its outline")
	}
}
