package pdf

import "core:io"
import "core:math"
import "core:mem/virtual"
import "core:time"

// to_bytes is the document as a PDF file, allocated from allocator.
to_bytes :: proc(doc: ^Document, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	encode(doc, &out)
	return out[:]
}

// write writes the document as a PDF file to w.
write :: proc(doc: ^Document, w: io.Writer) -> io.Error {
	out := make([dynamic]byte, doc.allocator)
	defer delete(out)
	encode(doc, &out)
	_, err := io.write_full(w, out[:])
	return err
}

// encode appends the document as a PDF file to out. A document with no
// pages is written with one blank A4 page rather than an empty page tree,
// so there is always a page to display.
encode :: proc(doc: ^Document, out: ^[dynamic]byte) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)

	w := Objects {
		out      = out,
		start    = len(out),
		compress = doc.compress,
	}
	pages := doc.pages[:]
	if len(pages) == 0 {
		blank := [1]Page{{size = A4}}
		pages = blank[:]
	}

	// Number every object first: the catalog, the page tree, the shared
	// resources and the info, then each font drawn with, then each page.
	CATALOG, PAGES, RESOURCES, INFO :: 1, 2, 3, 4
	next := 5
	font_objs := make([]int, len(doc.fonts), context.temp_allocator)
	for f, i in doc.fonts {
		if len(f.runes) > 0 {
			font_objs[i] = next
			next += f.outlines == .TrueType ? 6 : 5 // Type 0, CIDFont, descriptor, file, ToUnicode, CIDToGIDMap
		}
	}
	page_objs := make([]int, len(pages), context.temp_allocator)
	for p, i in pages {
		page_objs[i] = next
		next += 2 + len(p.links) // page, content, annotations
	}
	w.offsets = make([]int, next, context.temp_allocator)

	put(out, "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")

	obj_begin(&w, CATALOG)
	put(out, "<< /Type /Catalog /Pages 2 0 R >>")
	obj_end(&w)

	obj_begin(&w, PAGES)
	put(out, "<< /Type /Pages /Kids [")
	for n, i in page_objs {
		if i > 0 {
			put(out, " ")
		}
		put_ref(out, n)
	}
	put(out, "] /Count ")
	put_int(out, len(pages))
	put(out, " >>")
	obj_end(&w)

	obj_begin(&w, RESOURCES)
	put(out, "<< /ProcSet [/PDF /Text] /Font <<")
	for n, i in font_objs {
		if n != 0 {
			put(out, " /F")
			put_int(out, i)
			put(out, " ")
			put_ref(out, n)
		}
	}
	put(out, " >> >>")
	obj_end(&w)

	obj_begin(&w, INFO)
	put(out, "<<")
	info_entry(out, "Title", doc.info.title)
	info_entry(out, "Author", doc.info.author)
	info_entry(out, "Subject", doc.info.subject)
	info_entry(out, "Creator", doc.info.creator)
	info_entry(out, "Producer", doc.info.producer)
	if doc.info.created != {} {
		put(out, " /CreationDate ")
		put_date(out, doc.info.created)
		put(out, " /ModDate ")
		put_date(out, doc.info.created)
	}
	put(out, " >>")
	obj_end(&w)

	for f, i in doc.fonts {
		if font_objs[i] != 0 {
			write_font(&w, f, font_objs[i])
		}
	}

	for &p, i in pages {
		n := page_objs[i]
		obj_begin(&w, n)
		put(out, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ")
		put_num(out, p.size.x)
		put(out, " ")
		put_num(out, p.size.y)
		put(out, "] /Resources 3 0 R /Contents ")
		put_ref(out, n + 1)
		if len(p.links) > 0 {
			put(out, " /Annots [")
			for _, k in p.links {
				if k > 0 {
					put(out, " ")
				}
				put_ref(out, n + 2 + k)
			}
			put(out, "]")
		}
		put(out, " >>")
		obj_end(&w)
		put_stream(&w, n + 1, p.content[:], "")
		for l, k in p.links {
			obj_begin(&w, n + 2 + k)
			put(out, "<< /Type /Annot /Subtype /Link /Rect [")
			for v, j in l.rect {
				if j > 0 {
					put(out, " ")
				}
				put_num(out, v)
			}
			put(out, "] /Border [0 0 0] /A << /S /URI /URI ")
			put_literal(out, l.uri)
			put(out, " >> >>")
			obj_end(&w)
		}
	}

	xref := len(out) - w.start
	put(out, "xref\n0 ")
	put_int(out, next)
	put(out, "\n0000000000 65535 f \n")
	for off in w.offsets[1:] {
		put_padded(out, off, 10)
		put(out, " 00000 n \n")
	}
	put(out, "trailer\n<< /Size ")
	put_int(out, next)
	put(out, " /Root 1 0 R /Info 4 0 R >>\nstartxref\n")
	put_int(out, xref)
	put(out, "\n%%EOF\n")
}

// Objects writes numbered objects, noting where each starts for the xref.
@(private)
Objects :: struct {
	out:      ^[dynamic]byte,
	start:    int,
	offsets:  []int,
	compress: bool,
}

@(private)
obj_begin :: proc(w: ^Objects, n: int) {
	w.offsets[n] = len(w.out) - w.start
	put_int(w.out, n)
	put(w.out, " 0 obj\n")
}

@(private)
obj_end :: proc(w: ^Objects) {
	put(w.out, "\nendobj\n")
}

// put_stream writes object n as a stream of data, deflated when that makes
// it smaller; extra is added to its dictionary.
@(private)
put_stream :: proc(w: ^Objects, n: int, data: []byte, extra: string) {
	body := data
	packed := make([dynamic]byte, context.temp_allocator)
	if w.compress && len(data) > 0 {
		zlib_compress(&packed, data)
		if len(packed) < len(data) {
			body = packed[:]
		}
	}
	obj_begin(w, n)
	put(w.out, "<< /Length ")
	put_int(w.out, len(body))
	if len(body) != len(data) {
		put(w.out, " /Filter /FlateDecode")
	}
	put(w.out, extra)
	put(w.out, " >>\nstream\n")
	append(w.out, ..body)
	put(w.out, "\nendstream")
	obj_end(w)
}

// write_font writes f as objects from first: the Type 0 font the pages name,
// its CIDFont, the font descriptor, the subset font file, the ToUnicode map,
// and for TrueType the CIDToGIDMap.
@(private)
write_font :: proc(w: ^Objects, f: ^Face, first: int) {
	out := w.out
	TYPE0, CIDFONT, DESCRIPTOR, FILE, TOUNICODE, CIDTOGID :=
		first, first + 1, first + 2, first + 3, first + 4, first + 5

	gids := make([]u16, len(f.runes) + 1, context.temp_allocator)
	for r, i in f.runes {
		gids[i + 1] = glyph(f, r)
	}
	// The subset's tag: six capitals that differ when its glyphs do.
	sum: u32 = 2166136261
	for g in gids {
		sum = (sum ~ u32(g)) * 16777619
	}
	name: [70]byte
	for i in 0 ..< 6 {
		name[i] = 'A' + byte(sum % 26)
		sum /= 26
	}
	name[6] = '+'
	n := 7 + copy(name[7:], f.ps_name)
	base := string(name[:n])

	obj_begin(w, TYPE0)
	put(out, "<< /Type /Font /Subtype /Type0 /BaseFont /")
	put(out, base)
	put(out, " /Encoding /Identity-H /DescendantFonts [")
	put_ref(out, CIDFONT)
	put(out, "] /ToUnicode ")
	put_ref(out, TOUNICODE)
	put(out, " >>")
	obj_end(w)

	obj_begin(w, CIDFONT)
	put(
		out,
		f.outlines == .TrueType ? "<< /Type /Font /Subtype /CIDFontType2" : "<< /Type /Font /Subtype /CIDFontType0",
	)
	put(out, " /BaseFont /")
	put(out, base)
	put(
		out,
		" /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor ",
	)
	put_ref(out, DESCRIPTOR)
	put(out, " /DW ")
	put_int(out, width1000(f, 0))
	put(out, " /W [1 [")
	for g, i in gids[1:] {
		if i > 0 {
			put(out, " ")
		}
		put_int(out, width1000(f, g))
	}
	put(out, "]]")
	if f.outlines == .TrueType {
		put(out, " /CIDToGIDMap ")
		put_ref(out, CIDTOGID)
	}
	put(out, " >>")
	obj_end(w)

	k := 1000 / f.upem
	italic := f32(i32(be32(f.post, 4))) / 65536
	obj_begin(w, DESCRIPTOR)
	put(out, "<< /Type /FontDescriptor /FontName /")
	put(out, base)
	put(out, " /Flags ")
	put_int(out, italic != 0 ? 4 | 64 : 4) // symbolic, italic
	put(out, " /FontBBox [")
	for i in 0 ..< 4 {
		if i > 0 {
			put(out, " ")
		}
		put_int(out, int(math.round(f32(i16(be16(f.head, 36 + 2 * i))) * k)))
	}
	put(out, "] /ItalicAngle ")
	put_num(out, italic)
	put(out, " /Ascent ")
	put_int(out, int(math.round(f.ascent * k)))
	put(out, " /Descent ")
	put_int(out, int(math.round(f.descent * k)))
	put(out, " /CapHeight ")
	put_int(out, int(math.round(f.cap_height * k)))
	put(out, " /StemV 80 ")
	put(out, f.outlines == .TrueType ? "/FontFile2 " : "/FontFile3 ")
	put_ref(out, FILE)
	put(out, " >>")
	obj_end(w)

	file := make([dynamic]byte, context.temp_allocator)
	if f.outlines == .TrueType {
		subset_truetype(f, gids[1:], &file)
		extra := make([dynamic]byte, context.temp_allocator)
		put(&extra, " /Length1 ")
		put_int(&extra, len(file))
		put_stream(w, FILE, file[:], string(extra[:]))
	} else {
		subset_cff(f, gids, &file)
		put_stream(w, FILE, file[:], " /Subtype /CIDFontType0C")
	}

	cmap := make([dynamic]byte, context.temp_allocator)
	put(
		&cmap,
		"/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" +
		"/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" +
		"/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" +
		"1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n",
	)
	for chunk := 0; chunk < len(f.runes); chunk += 100 {
		end := min(chunk + 100, len(f.runes))
		put_int(&cmap, end - chunk)
		put(&cmap, " beginbfchar\n")
		for i in chunk ..< end {
			put(&cmap, "<")
			put_hex16(&cmap, u16(i + 1))
			put(&cmap, "> <")
			r := f.runes[i]
			if r > 0xffff {
				v := u32(r) - 0x10000
				put_hex16(&cmap, u16(0xd800 + (v >> 10)))
				put_hex16(&cmap, u16(0xdc00 + (v & 0x3ff)))
			} else {
				put_hex16(&cmap, u16(r))
			}
			put(&cmap, ">\n")
		}
		put(&cmap, "endbfchar\n")
	}
	put(&cmap, "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n")
	put_stream(w, TOUNICODE, cmap[:], "")

	if f.outlines == .TrueType {
		m := make([dynamic]byte, 0, 2 * len(gids), context.temp_allocator)
		for g in gids {
			put_u16(&m, g)
		}
		put_stream(w, CIDTOGID, m[:], "")
	}
}

@(private)
info_entry :: proc(out: ^[dynamic]byte, key, value: string) {
	if value == "" {
		return
	}
	put(out, " /")
	put(out, key)
	put(out, " ")
	put_text_string(out, value)
}

// put_text_string writes s as a PDF text string: a literal when it is ASCII,
// else UTF-16BE behind a byte order mark, in hex.
@(private)
put_text_string :: proc(out: ^[dynamic]byte, s: string) {
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 {
			put(out, "<FEFF")
			for r in s {
				if r > 0xffff {
					v := u32(r) - 0x10000
					put_hex16(out, u16(0xd800 + (v >> 10)))
					put_hex16(out, u16(0xdc00 + (v & 0x3ff)))
				} else {
					put_hex16(out, u16(r))
				}
			}
			put(out, ">")
			return
		}
	}
	put_literal(out, s)
}

// put_literal writes s as a literal string: parentheses and backslashes
// escaped, and any byte outside printable ASCII as an octal escape.
@(private)
put_literal :: proc(out: ^[dynamic]byte, s: string) {
	append(out, '(')
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == '(' || c == ')' || c == '\\':
			append(out, '\\', c)
		case c < 0x20 || c >= 0x7f:
			append(out, '\\', '0' + (c >> 6), '0' + (c >> 3) & 7, '0' + c & 7)
		case:
			append(out, c)
		}
	}
	append(out, ')')
}

// put_date writes t, in UTC, as a PDF date string.
@(private)
put_date :: proc(out: ^[dynamic]byte, t: time.Time) {
	y, mon, d := time.date(t)
	h, m, s := time.clock(t)
	put(out, "(D:")
	put_padded(out, y, 4)
	put_padded(out, int(mon), 2)
	put_padded(out, d, 2)
	put_padded(out, h, 2)
	put_padded(out, m, 2)
	put_padded(out, s, 2)
	put(out, "Z)")
}

@(private)
put :: proc(out: ^[dynamic]byte, s: string) {
	append(out, s)
}

@(private)
put_ref :: proc(out: ^[dynamic]byte, n: int) {
	put_int(out, n)
	put(out, " 0 R")
}

@(private)
put_int :: proc(out: ^[dynamic]byte, v: int) {
	buf: [24]byte
	i := len(buf)
	u := v < 0 ? -v : v
	for {
		i -= 1
		buf[i] = byte('0' + u % 10)
		u /= 10
		if u == 0 {
			break
		}
	}
	if v < 0 {
		i -= 1
		buf[i] = '-'
	}
	append(out, ..buf[i:])
}

// put_padded writes v with leading zeros to width digits.
@(private)
put_padded :: proc(out: ^[dynamic]byte, v, width: int) {
	buf: [24]byte
	u := max(v, 0)
	for i := width - 1; i >= 0; i -= 1 {
		buf[i] = byte('0' + u % 10)
		u /= 10
	}
	append(out, ..buf[:width])
}

// put_num writes v to three decimal places, trailing zeros dropped: the same
// text for the same number on every machine.
@(private)
put_num :: proc(out: ^[dynamic]byte, v: f32) {
	if math.is_nan(v) || math.is_inf(v) {
		append(out, '0')
		return
	}
	n := i64(math.round(f64(v) * 1000))
	if n < 0 {
		append(out, '-')
		n = -n
	}
	put_int(out, int(n / 1000))
	frac := n % 1000
	if frac == 0 {
		return
	}
	digits := [3]byte{byte('0' + frac / 100), byte('0' + frac / 10 % 10), byte('0' + frac % 10)}
	end := 3
	for digits[end - 1] == '0' {
		end -= 1
	}
	append(out, '.')
	append(out, ..digits[:end])
}

@(private)
put_hex16 :: proc(out: ^[dynamic]byte, v: u16) {
	HEX := "0123456789ABCDEF"
	append(out, HEX[v >> 12], HEX[v >> 8 & 15], HEX[v >> 4 & 15], HEX[v & 15])
}
