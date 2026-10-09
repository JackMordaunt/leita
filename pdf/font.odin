package pdf

import "core:os"
import "core:strings"

// Font names a font added to a Document.
Font :: distinct int

Font_Error :: enum {
	None,
	Unreadable, // the file could not be read
	Malformed, // not an OpenType font, or a table it needs is missing or short
	Unsupported, // outlines this package cannot embed: CFF2, or bitmaps only
	Not_Embeddable, // the font's licence bits forbid embedding it (OS/2 fsType)
}

// Outlines is how a font draws its glyphs, which decides how it is embedded:
// TrueType outlines as a CIDFontType2, CFF ones as a CIDFontType0 (ISO
// 32000-1, 9.7.4).
@(private)
Outlines :: enum {
	TrueType,
	CFF,
}

// Face is a font file's tables and what has been drawn with it. Codes in the
// page content are CIDs this package hands out, one per distinct rune drawn,
// from 1; CID 0 is .notdef. A rune the font lacks still gets its own CID, drawn
// as .notdef, so the ToUnicode map gives the rune back to a reader copying the
// text.
@(private)
Face :: struct {
	data:         []byte, // the whole file
	owned:        bool, // data was read by add_font_file, freed by destroy
	outlines:     Outlines,
	using tables: Tables,
	glyph_count:  int,
	metric_count: int, // hhea.numberOfHMetrics
	upem:         f32,
	loca_long:    bool,
	ascent:       f32, // in font units, from hhea
	descent:      f32, // negative, below the baseline
	cap_height:   f32,
	ps_name:      string, // PostScript name, letters, digits and hyphens only
	cmap_at:      int, // where the chosen subtable starts in cmap
	cmap_format:  u16,
	glyphs:       map[rune]u16, // cmap lookups so far, misses as 0
	cids:         map[rune]u16, // the CID each drawn rune was given
	runes:        [dynamic]rune, // the rune of each CID, from CID 1
	fallbacks:    [dynamic]Font,
}

// Tables are the font tables this package reads, each borrowed from its
// Face's data; empty when the font has none.
@(private)
Tables :: struct {
	head, hhea, hmtx, maxp, cmap, loca, glyf: []byte,
	cff, os2, post, name, cvt, fpgm, prep:    []byte,
}

@(private)
be16 :: #force_inline proc(b: []byte, at: int) -> u16 {
	if at < 0 || at + 2 > len(b) {
		return 0
	}
	return u16(b[at]) << 8 | u16(b[at + 1])
}

@(private)
be32 :: #force_inline proc(b: []byte, at: int) -> u32 {
	if at < 0 || at + 4 > len(b) {
		return 0
	}
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

@(private)
tag :: #force_inline proc(s: string) -> u32 {
	return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

// add_font adds the OpenType or TrueType font in data, or face index of a
// collection (.ttc), and returns its name for drawing. data is borrowed and
// must outlive doc. Only the glyphs drawn are embedded.
add_font :: proc(doc: ^Document, data: []byte, index := 0) -> (Font, Font_Error) {
	f := new(Face, doc.allocator)
	f.glyphs = make(map[rune]u16, doc.allocator)
	f.cids = make(map[rune]u16, doc.allocator)
	f.runes = make([dynamic]rune, doc.allocator)
	f.fallbacks = make([dynamic]Font, doc.allocator)
	if err := face_init(f, data, index, doc.allocator); err != .None {
		face_destroy(f, doc.allocator)
		return -1, err
	}
	append(&doc.fonts, f)
	return Font(len(doc.fonts) - 1), .None
}

// add_font_file reads the font at path and adds it as add_font does; doc
// keeps the file's bytes until destroy.
add_font_file :: proc(doc: ^Document, path: string, index := 0) -> (Font, Font_Error) {
	data, err := os.read_entire_file(path, doc.allocator)
	if err != nil {
		return -1, .Unreadable
	}
	font, ferr := add_font(doc, data, index)
	if ferr != .None {
		delete(data, doc.allocator)
		return -1, ferr
	}
	doc.fonts[font].owned = true
	return font, .None
}

// add_fallback has text drawn in font take a rune font lacks from fallback,
// or from the next fallback added after it; a rune none of them has is drawn
// as font's .notdef box.
add_fallback :: proc(doc: ^Document, font, fallback: Font) {
	if font_ok(doc, font) && font_ok(doc, fallback) && font != fallback {
		append(&doc.fonts[font].fallbacks, fallback)
	}
}

// Font_Metrics are a font's vertical extents at a size, in points: ascent
// above the baseline, descent below it (positive), and the line height the
// font asks for.
Font_Metrics :: struct {
	ascent, descent, line_height, cap_height: f32,
}

font_metrics :: proc(doc: ^Document, font: Font, size: f32) -> Font_Metrics {
	if !font_ok(doc, font) {
		return {}
	}
	f := doc.fonts[font]
	k := size / f.upem
	gap := f32(i16(be16(f.hhea, 8)))
	return {
		ascent = f.ascent * k,
		descent = -f.descent * k,
		line_height = (f.ascent - f.descent + gap) * k,
		cap_height = f.cap_height * k,
	}
}

@(private)
font_ok :: proc(doc: ^Document, font: Font) -> bool {
	return font >= 0 && int(font) < len(doc.fonts)
}

@(private)
face_destroy :: proc(f: ^Face, allocator := context.allocator) {
	if f.owned {
		delete(f.data, allocator)
	}
	delete(f.ps_name, allocator)
	delete(f.glyphs)
	delete(f.cids)
	delete(f.runes)
	delete(f.fallbacks)
	free(f, allocator)
}

@(private)
face_init :: proc(
	f: ^Face,
	data: []byte,
	index: int,
	allocator := context.allocator,
) -> Font_Error {
	f.data = data
	dir := 0
	if be32(data, 0) == tag("ttcf") {
		if index < 0 || index >= int(be32(data, 8)) {
			return .Malformed
		}
		dir = int(be32(data, 12 + 4 * index))
	}
	switch be32(data, dir) {
	case 0x00010000, tag("true"), tag("OTTO"):
	case:
		return .Malformed
	}
	count := int(be16(data, dir + 4))
	cff2 := false
	for i in 0 ..< count {
		rec := dir + 12 + 16 * i
		off, length := int(be32(data, rec + 8)), int(be32(data, rec + 12))
		if off + length > len(data) || rec + 16 > len(data) {
			return .Malformed
		}
		t := data[off:][:length]
		switch be32(data, rec) {
		case tag("head"):
			f.head = t
		case tag("hhea"):
			f.hhea = t
		case tag("hmtx"):
			f.hmtx = t
		case tag("maxp"):
			f.maxp = t
		case tag("cmap"):
			f.cmap = t
		case tag("loca"):
			f.loca = t
		case tag("glyf"):
			f.glyf = t
		case tag("CFF "):
			f.cff = t
		case tag("CFF2"):
			cff2 = true
		case tag("OS/2"):
			f.os2 = t
		case tag("post"):
			f.post = t
		case tag("name"):
			f.name = t
		case tag("cvt "):
			f.cvt = t
		case tag("fpgm"):
			f.fpgm = t
		case tag("prep"):
			f.prep = t
		}
	}
	if len(f.head) < 54 || len(f.hhea) < 36 || len(f.maxp) < 6 || len(f.cmap) < 4 {
		return .Malformed
	}
	switch {
	case len(f.glyf) > 0 && len(f.loca) > 0:
		f.outlines = .TrueType
	case len(f.cff) > 0:
		f.outlines = .CFF
	case cff2:
		return .Unsupported
	case:
		return .Unsupported
	}
	// fsType: bit 1 is a restricted licence, bit 9 allows bitmaps only
	// (OpenType spec, OS/2 table, fsType).
	if len(f.os2) >= 10 && be16(f.os2, 8) & 0x0202 != 0 {
		return .Not_Embeddable
	}
	f.upem = f32(be16(f.head, 18))
	if f.upem < 16 {
		return .Malformed
	}
	f.loca_long = be16(f.head, 50) == 1
	f.glyph_count = int(be16(f.maxp, 4))
	f.metric_count = int(be16(f.hhea, 34))
	if f.metric_count == 0 || len(f.hmtx) < 4 * f.metric_count {
		return .Malformed
	}
	f.ascent = f32(i16(be16(f.hhea, 4)))
	f.descent = f32(i16(be16(f.hhea, 6)))
	f.cap_height = f.ascent * 0.7
	if len(f.os2) >= 90 && be16(f.os2, 0) >= 2 {
		f.cap_height = f32(i16(be16(f.os2, 88)))
	}
	if !choose_cmap(f) {
		return .Malformed
	}
	f.ps_name = postscript_name(f, allocator)
	if f.outlines == .CFF {
		notdef := [1]u16{0}
		probe := make([dynamic]byte, context.temp_allocator)
		if !subset_cff(f, notdef[:], &probe) {
			return .Malformed
		}
	}
	return .None
}

// choose_cmap picks the subtable covering the most of Unicode: a full-range
// format 12 over a BMP-only format 4.
@(private)
choose_cmap :: proc(f: ^Face) -> bool {
	best := 0
	for i in 0 ..< int(be16(f.cmap, 2)) {
		rec := 4 + 8 * i
		platform, encoding := be16(f.cmap, rec), be16(f.cmap, rec + 2)
		off := int(be32(f.cmap, rec + 4))
		if off >= len(f.cmap) {
			continue
		}
		sub := f.cmap[off:]
		format := be16(sub, 0)
		score := 0
		switch {
		case format == 12 && (platform == 3 && encoding == 10 || platform == 0):
			score = 3
		case format == 4 && (platform == 3 && encoding == 1 || platform == 0):
			score = 2
		}
		if score > best {
			best = score
			f.cmap_at, f.cmap_format = off, format
		}
	}
	return best > 0
}

// glyph is the font's glyph for r, 0 when it has none.
@(private)
glyph :: proc(f: ^Face, r: rune) -> u16 {
	if g, ok := f.glyphs[r]; ok {
		return g
	}
	g := cmap_lookup(f, r)
	if int(g) >= f.glyph_count {
		g = 0
	}
	f.glyphs[r] = g
	return g
}

@(private)
cmap_lookup :: proc(f: ^Face, r: rune) -> u16 {
	s := f.cmap[f.cmap_at:]
	c := u32(r)
	switch f.cmap_format {
	case 4:
		if c > 0xffff {
			return 0
		}
		segs := int(be16(s, 6)) / 2
		for i in 0 ..< segs {
			end := u32(be16(s, 14 + 2 * i))
			if c > end {
				continue
			}
			start := u32(be16(s, 16 + 2 * segs + 2 * i))
			if c < start {
				return 0
			}
			delta := u32(be16(s, 16 + 4 * segs + 2 * i))
			ro_at := 16 + 6 * segs + 2 * i
			ro := int(be16(s, ro_at))
			if ro == 0 {
				return u16(c + delta)
			}
			g := u32(be16(s, ro_at + ro + 2 * int(c - start)))
			return g == 0 ? 0 : u16(g + delta)
		}
	case 12:
		lo, hi := 0, int(be32(s, 12))
		for lo < hi {
			mid := (lo + hi) / 2
			at := 16 + 12 * mid
			if c < be32(s, at) {
				hi = mid
			} else if c > be32(s, at + 4) {
				lo = mid + 1
			} else {
				return u16(be32(s, at + 8) + c - be32(s, at))
			}
		}
	}
	return 0
}

// advance is glyph g's advance width in font units.
@(private)
advance :: proc(f: ^Face, g: u16) -> u16 {
	i := min(int(g), f.metric_count - 1)
	return be16(f.hmtx, 4 * i)
}

// width1000 is glyph g's advance in thousandths of the size, as a CIDFont's
// W array states it (ISO 32000-1, 9.7.4.3): measuring and drawing both use this one number, so a
// measured column is the width a reader draws.
@(private)
width1000 :: proc(f: ^Face, g: u16) -> int {
	return int(f32(advance(f, g)) * 1000 / f.upem + 0.5)
}

// postscript_name is name ID 6 cut to ASCII letters, digits and hyphens, none
// of which a PDF name escapes or ends at, by ISO 32000-1, 7.3.5. A font with
// no such name is called Font.
@(private)
postscript_name :: proc(f: ^Face, allocator := context.allocator) -> string {
	buf: [63]byte
	n := 0
	keep :: proc(buf: []byte, n: ^int, c: u32) {
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-'
		if ok && n^ < len(buf) {
			buf[n^] = byte(c)
			n^ += 1
		}
	}
	strings_at := int(be16(f.name, 4))
	for i in 0 ..< int(be16(f.name, 2)) {
		rec := 6 + 12 * i
		platform, id := be16(f.name, rec), be16(f.name, rec + 6)
		if id != 6 || platform != 1 && platform != 3 {
			continue
		}
		length, off := int(be16(f.name, rec + 8)), strings_at + int(be16(f.name, rec + 10))
		if off + length > len(f.name) {
			continue
		}
		s := f.name[off:][:length]
		if platform == 3 {
			for j := 0; j + 1 < len(s); j += 2 {
				keep(buf[:], &n, u32(be16(s, j)))
			}
		} else {
			for c in s {
				keep(buf[:], &n, u32(c))
			}
		}
		if n > 0 {
			break
		}
	}
	if n == 0 {
		return strings.clone("Font", allocator)
	}
	return strings.clone(string(buf[:n]), allocator)
}
