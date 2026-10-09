package pdf

// Fonts are embedded with only the glyphs a document draws. A TrueType font
// keeps its glyph ids and has every other glyph emptied, so composite glyphs
// need no rewriting; the PDF maps CIDs to those ids with a CIDToGIDMap. A CFF
// font is rebuilt as a CID-keyed CFF whose glyph i is the glyph of CID i, with
// its subroutines inlined into the charstrings that call them, so none of a CJK
// font's megabytes of subroutines come along.

// subset_truetype appends to out a TrueType font holding f's tables with only
// the glyphs in used, glyph 0 and the components those are built from.
@(private)
subset_truetype :: proc(f: ^Face, used: []u16, out: ^[dynamic]byte) {
	keep := make([]bool, f.glyph_count, context.temp_allocator)
	work := make([dynamic]u16, 0, len(used) + 1, context.temp_allocator)
	append(&work, 0)
	append(&work, ..used)
	for len(work) > 0 {
		g := pop(&work)
		if int(g) >= f.glyph_count || keep[g] {
			continue
		}
		keep[g] = true
		data := glyph_bytes(f, g)
		if len(data) < 10 || i16(be16(data, 0)) >= 0 {
			continue
		}
		// A composite: flags, glyph index, then arguments and a transform
		// whose sizes the flags give (OpenType 'glyf', composite glyphs).
		at := 10
		for at + 4 <= len(data) {
			flags := be16(data, at)
			append(&work, be16(data, at + 2))
			at += 4
			at += flags & 0x0001 != 0 ? 4 : 2
			switch {
			case flags & 0x0008 != 0:
				at += 2
			case flags & 0x0040 != 0:
				at += 4
			case flags & 0x0080 != 0:
				at += 8
			}
			if flags & 0x0020 == 0 {
				break
			}
		}
	}

	glyf := make([dynamic]byte, context.temp_allocator)
	loca := make([dynamic]byte, 0, 4 * (f.glyph_count + 1), context.temp_allocator)
	for g in 0 ..< f.glyph_count {
		put_u32(&loca, u32(len(glyf)))
		if keep[g] {
			append(&glyf, ..glyph_bytes(f, u16(g)))
			for len(glyf) % 4 != 0 {
				append(&glyf, 0)
			}
		}
	}
	put_u32(&loca, u32(len(glyf)))

	head := make([]byte, len(f.head), context.temp_allocator)
	copy(head, f.head)
	head[8], head[9], head[10], head[11] = 0, 0, 0, 0 // checkSumAdjustment, set below
	head[50], head[51] = 0, 1 // long loca offsets

	// A cmap mapping nothing. The PDF reaches glyphs by id, through the
	// CIDToGIDMap; the table is there because the OpenType spec lists cmap
	// among the tables every font must have ('Font Tables', required tables).
	cmap := [?]byte {
		0,
		0,
		0,
		1,
		0,
		3,
		0,
		1,
		0,
		0,
		0,
		12, // one (3, 1) subtable at 12
		0,
		4,
		0,
		24,
		0,
		0,
		0,
		2,
		0,
		2,
		0,
		0,
		0,
		0, // format 4, one segment
		0xff,
		0xff,
		0,
		0,
		0xff,
		0xff,
		0,
		1,
		0,
		0, // the closing segment
	}

	tables := make([dynamic]Sfnt_Table, context.temp_allocator)
	add :: proc(tables: ^[dynamic]Sfnt_Table, t: string, data: []byte) {
		if len(data) > 0 {
			append(tables, Sfnt_Table{tag(t), data})
		}
	}
	// In tag order, as the OpenType spec's 'Table Directory' section sorts
	// its records.
	add(&tables, "OS/2", f.os2)
	add(&tables, "cmap", cmap[:])
	add(&tables, "cvt ", f.cvt)
	add(&tables, "fpgm", f.fpgm)
	add(&tables, "glyf", glyf[:])
	add(&tables, "head", head)
	add(&tables, "hhea", f.hhea)
	add(&tables, "hmtx", f.hmtx)
	add(&tables, "loca", loca[:])
	add(&tables, "maxp", f.maxp)
	add(&tables, "prep", f.prep)
	write_sfnt(out, tables[:])
}

// glyph_bytes is glyph g's 'glyf' entry, empty for a glyph with no outline.
@(private)
glyph_bytes :: proc(f: ^Face, g: u16) -> []byte {
	start, end: int
	if f.loca_long {
		start, end = int(be32(f.loca, 4 * int(g))), int(be32(f.loca, 4 * int(g) + 4))
	} else {
		start, end = 2 * int(be16(f.loca, 2 * int(g))), 2 * int(be16(f.loca, 2 * int(g) + 2))
	}
	if start >= end || end > len(f.glyf) {
		return nil
	}
	return f.glyf[start:end]
}

@(private)
Sfnt_Table :: struct {
	tag:  u32,
	data: []byte,
}

// write_sfnt appends a font file of tables, given in tag order, and sets the
// head table's checkSumAdjustment over the whole file.
@(private)
write_sfnt :: proc(out: ^[dynamic]byte, tables: []Sfnt_Table) {
	start := len(out)
	n := len(tables)
	pow, sel := 1, 0
	for pow * 2 <= n {
		pow *= 2
		sel += 1
	}
	put_u32(out, 0x00010000)
	put_u16(out, u16(n))
	put_u16(out, u16(16 * pow))
	put_u16(out, u16(sel))
	put_u16(out, u16(16 * (n - pow)))
	off := 12 + 16 * n
	head_at := -1
	for t in tables {
		if t.tag == tag("head") {
			head_at = start + off
		}
		put_u32(out, t.tag)
		put_u32(out, sfnt_checksum(t.data))
		put_u32(out, u32(off))
		put_u32(out, u32(len(t.data)))
		off += (len(t.data) + 3) &~ 3
	}
	for t in tables {
		append(out, ..t.data)
		for (len(out) - start) % 4 != 0 {
			append(out, 0)
		}
	}
	if head_at >= 0 {
		adj := 0xB1B0AFBA - sfnt_checksum(out[start:])
		out[head_at + 8], out[head_at + 9] = byte(adj >> 24), byte(adj >> 16)
		out[head_at + 10], out[head_at + 11] = byte(adj >> 8), byte(adj)
	}
}

@(private)
sfnt_checksum :: proc(data: []byte) -> u32 {
	sum: u32
	for i := 0; i < len(data); i += 4 {
		w: u32
		for k in 0 ..< 4 {
			w <<= 8
			if i + k < len(data) {
				w |= u32(data[i + k])
			}
		}
		sum += w
	}
	return sum
}

@(private)
put_u16 :: proc(out: ^[dynamic]byte, v: u16) {
	append(out, byte(v >> 8), byte(v))
}

@(private)
put_u32 :: proc(out: ^[dynamic]byte, v: u32) {
	append(out, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
}

// Cff_Index is a CFF INDEX (Adobe TN 5176, section 5): count items, each found
// through an offset off_size bytes wide counted from base.
@(private)
Cff_Index :: struct {
	b:        []byte,
	count:    int,
	off_size: int,
	offsets:  int,
	base:     int,
	end:      int, // the first byte past the INDEX
}

@(private)
cff_index :: proc(b: []byte, at: int) -> (idx: Cff_Index, ok: bool) {
	idx.b = b
	idx.count = int(be16(b, at))
	if idx.count == 0 {
		idx.end = at + 2
		return idx, at >= 0 && at + 2 <= len(b)
	}
	if at < 0 || at + 3 > len(b) {
		return {}, false
	}
	idx.off_size = int(b[at + 2])
	if idx.off_size < 1 || idx.off_size > 4 {
		return {}, false
	}
	idx.offsets = at + 3
	idx.base = idx.offsets + (idx.count + 1) * idx.off_size - 1
	if idx.base >= len(b) {
		return {}, false
	}
	idx.end = idx.base + cff_offset(idx, idx.count)
	return idx, idx.end <= len(b)
}

@(private)
cff_offset :: proc(idx: Cff_Index, i: int) -> int {
	at := idx.offsets + i * idx.off_size
	if at + idx.off_size > len(idx.b) {
		return 0
	}
	v := 0
	for k in 0 ..< idx.off_size {
		v = v << 8 | int(idx.b[at + k])
	}
	return v
}

// cff_item is item i, nil when there is none.
@(private)
cff_item :: proc(idx: Cff_Index, i: int) -> []byte {
	if i < 0 || i >= idx.count {
		return nil
	}
	s, e := idx.base + cff_offset(idx, i), idx.base + cff_offset(idx, i + 1)
	if s <= idx.base || s > e || e > len(idx.b) {
		return nil
	}
	return idx.b[s:e]
}

@(private)
DICT_ENTRIES :: 48

// Dict_Entry is one operator of a CFF DICT with its first integer operands
// and its bytes, operands and operator together, for copying it whole. A real
// operand reads as 0: no operand read here is ever a real.
@(private)
Dict_Entry :: struct {
	op:    int, // an escaped operator 12 x as 1200 + x
	args:  [4]int,
	nargs: int,
	raw:   []byte,
}

@(private)
Dict :: struct {
	entries: [DICT_ENTRIES]Dict_Entry,
	count:   int,
}

@(private)
cff_dict :: proc(b: []byte) -> (d: Dict, ok: bool) {
	args: [4]int
	n, start, i := 0, 0, 0
	for i < len(b) {
		c := b[i]
		v := 0
		switch {
		case c <= 21:
			op := int(c)
			i += 1
			if c == 12 {
				if i >= len(b) {
					return d, false
				}
				op = 1200 + int(b[i])
				i += 1
			}
			if d.count == DICT_ENTRIES {
				return d, false
			}
			d.entries[d.count] = {op, args, min(n, len(args)), b[start:i]}
			d.count += 1
			n, start = 0, i
			continue
		case c == 28:
			v = int(i16(be16(b, i + 1)))
			i += 3
		case c == 29:
			v = int(i32(be32(b, i + 1)))
			i += 5
		case c == 30:
			i += 1
			for i < len(b) {
				x := b[i]
				i += 1
				if x & 0x0f == 0x0f || x >> 4 == 0x0f {
					break
				}
			}
		case c >= 32 && c <= 246:
			v = int(c) - 139
			i += 1
		case c >= 247 && c <= 254:
			if i + 1 >= len(b) {
				return d, false
			}
			w := int(c >= 251 ? c - 251 : c - 247) * 256 + int(b[i + 1]) + 108
			v = c >= 251 ? -w : w
			i += 2
		case:
			return d, false
		}
		if n < len(args) {
			args[n] = v
		}
		n += 1
	}
	return d, i == len(b)
}

@(private)
dict_find :: proc(d: ^Dict, op: int) -> ^Dict_Entry {
	for &e in d.entries[:d.count] {
		if e.op == op {
			return &e
		}
	}
	return nil
}

@(private)
Cff_Fd :: struct {
	font:    Dict, // the Font DICT, empty for a font that is not CID-keyed
	private: []byte,
	subrs:   Cff_Index,
}

// Cff_Font is the parts of a CFF table subset_cff reads.
@(private)
Cff_Font :: struct {
	top:                 Dict,
	charstrings, gsubrs: Cff_Index,
	fds:                 [dynamic]Cff_Fd, // from context.temp_allocator
	fdselect:            int, // the FDSelect's offset, -1 for a font that is not CID-keyed
}

@(private)
read_cff :: proc(b: []byte) -> (c: Cff_Font, ok: bool) {
	if len(b) < 4 || b[0] != 1 {
		return {}, false
	}
	names := cff_index(b, int(b[2])) or_return
	tops := cff_index(b, names.end) or_return
	strs := cff_index(b, tops.end) or_return
	c.gsubrs = cff_index(b, strs.end) or_return
	c.top = cff_dict(cff_item(tops, 0)) or_return
	cs_entry := dict_find(&c.top, 17)
	if cs_entry == nil {
		return {}, false
	}
	c.charstrings = cff_index(b, cs_entry.args[0]) or_return

	c.fds = make([dynamic]Cff_Fd, context.temp_allocator)
	c.fdselect = -1
	if dict_find(&c.top, 1230) != nil {
		fa, fs := dict_find(&c.top, 1236), dict_find(&c.top, 1237)
		if fa == nil || fs == nil {
			return {}, false
		}
		c.fdselect = fs.args[0]
		fdarray := cff_index(b, fa.args[0]) or_return
		for i in 0 ..< fdarray.count {
			fd: Cff_Fd
			fd.font = cff_dict(cff_item(fdarray, i)) or_return
			read_cff_private(b, dict_find(&fd.font, 18), &fd) or_return
			append(&c.fds, fd)
		}
	} else {
		fd: Cff_Fd
		read_cff_private(b, dict_find(&c.top, 18), &fd) or_return
		append(&c.fds, fd)
	}
	return c, len(c.fds) > 0 && len(c.fds) <= 255
}

// subset_cff appends to out a CID-keyed CFF font whose glyph i is f's glyph
// gids[i]; gids[0] should be 0, .notdef. false when f's CFF table is not one
// this can read.
@(private)
subset_cff :: proc(f: ^Face, gids: []u16, out: ^[dynamic]byte) -> bool {
	b := f.cff
	c := read_cff(b) or_return
	fds := c.fds

	// The charstrings, subroutines inlined, and the Font DICT of each.
	cs := make([dynamic]byte, context.temp_allocator)
	cs_offs := make([dynamic]int, 0, len(gids) + 1, context.temp_allocator)
	glyph_fds := make([]byte, len(gids), context.temp_allocator)
	append(&cs_offs, 0)
	for g, i in gids {
		fd := c.fdselect < 0 ? 0 : cff_fd_of(b, c.fdselect, int(g))
		if fd >= len(fds) {
			fd = 0
		}
		glyph_fds[i] = byte(fd)
		w := Charstring_Walk {
			out    = &cs,
			gsubrs = c.gsubrs,
			lsubrs = fds[fd].subrs,
		}
		if !charstring_walk(&w, cff_item(c.charstrings, int(g)), 0) {
			resize(&cs, cs_offs[len(cs_offs) - 1])
			append(&cs, 14) // an empty glyph rather than a broken one
		}
		append(&cs_offs, len(cs))
	}

	// Lay the parts out; each offset is written as a 5-byte integer, so no
	// part's size depends on where the others land.
	strings_items := [?][]byte {
		transmute([]byte)string("Adobe"),
		transmute([]byte)string("Identity"),
	}
	name_items := [?][]byte{transmute([]byte)f.ps_name}
	privates := make([dynamic][]byte, context.temp_allocator)
	for &fd in fds {
		append(&privates, cff_private_copy(fd.private))
	}
	n := len(gids)
	charset := make([dynamic]byte, context.temp_allocator)
	if n >= 2 {
		append(&charset, 2, 0, 1)
		put_u16(&charset, u16(n - 2))
	} else {
		append(&charset, 0)
	}

	scratch := make([dynamic]byte, context.temp_allocator)

	put_index(&scratch, name_items[:])
	name_size := len(scratch)
	clear(&scratch)
	put_cff_top(&scratch, &c.top, n, 0, 0, 0, 0)
	top_size := index_size(1, len(scratch))
	clear(&scratch)
	put_index(&scratch, strings_items[:])
	strings_size := len(scratch)
	clear(&scratch)

	charset_at := 4 + name_size + top_size + strings_size + 2
	fdselect_at := charset_at + len(charset)
	charstrings_at := fdselect_at + 1 + n
	fdarray_at := charstrings_at + index_size(n, len(cs))
	put_cff_font_dicts(&scratch, fds[:], privates[:], 0)
	private_at := fdarray_at + len(scratch)

	append(out, 1, 0, 4, 4)
	put_index(out, name_items[:])
	clear(&scratch)
	put_cff_top(&scratch, &c.top, n, charset_at, fdselect_at, charstrings_at, fdarray_at)
	top_items := [?][]byte{scratch[:]}
	put_index(out, top_items[:])
	put_index(out, strings_items[:])
	append(out, 0, 0) // no global subroutines
	append(out, ..charset[:])
	append(out, 0)
	append(out, ..glyph_fds)
	put_index_packed(out, cs[:], cs_offs[:])
	put_cff_font_dicts(out, fds[:], privates[:], private_at)
	for p in privates {
		append(out, ..p)
	}
	return true
}

// put_cff_top writes the Top DICT of subset_cff's font: CID-keyed, n glyphs,
// its parts at the offsets given, and src's FontBBox and FontMatrix.
@(private)
put_cff_top :: proc(
	out: ^[dynamic]byte,
	src: ^Dict,
	n, charset, fdselect, charstrings, fdarray: int,
) {
	put_dict_int(out, 391)
	put_dict_int(out, 392)
	put_dict_int(out, 0)
	append(out, 12, 30) // ROS: Adobe-Identity-0
	put_dict_int(out, n)
	append(out, 12, 34) // CIDCount
	for e in src.entries[:src.count] {
		if e.op == 5 || e.op == 1207 { 	// FontBBox, FontMatrix
			append(out, ..e.raw)
		}
	}
	put_dict_int(out, charset)
	append(out, 15)
	put_dict_int(out, fdselect)
	append(out, 12, 37)
	put_dict_int(out, fdarray)
	append(out, 12, 36)
	put_dict_int(out, charstrings)
	append(out, 17)
}

// put_cff_font_dicts writes an INDEX of the Font DICTs of fds, each naming its
// Private DICT, the privates laid end to end from at.
@(private)
put_cff_font_dicts :: proc(out: ^[dynamic]byte, fds: []Cff_Fd, privates: [][]byte, at: int) {
	items := make([dynamic][]byte, context.temp_allocator)
	buf := make([dynamic]byte, context.temp_allocator)
	ends := make([dynamic]int, context.temp_allocator)
	at := at
	for &fd, i in fds {
		for e in fd.font.entries[:fd.font.count] {
			if e.op != 18 && e.op != 1238 { 	// Private, FontName
				append(&buf, ..e.raw)
			}
		}
		put_dict_int(&buf, len(privates[i]))
		put_dict_int(&buf, at)
		append(&buf, 18)
		append(&ends, len(buf))
		at += len(privates[i])
	}
	prev := 0
	for e in ends {
		append(&items, buf[prev:e])
		prev = e
	}
	put_index(out, items[:])
}

// read_cff_private finds the Private DICT entry names, and its local
// subroutines.
@(private)
read_cff_private :: proc(b: []byte, entry: ^Dict_Entry, fd: ^Cff_Fd) -> bool {
	if entry == nil || entry.nargs < 2 {
		return false
	}
	size, at := entry.args[0], entry.args[1]
	if size < 0 || at < 0 || at + size > len(b) {
		return false
	}
	fd.private = b[at:][:size]
	d := cff_dict(fd.private) or_return
	if subrs := dict_find(&d, 19); subrs != nil {
		fd.subrs = cff_index(b, at + subrs.args[0]) or_return
	}
	return true
}

// cff_private_copy is a Private DICT without its Subrs, which charstring_walk
// inlined; from context.temp_allocator.
@(private)
cff_private_copy :: proc(private: []byte) -> []byte {
	d, _ := cff_dict(private)
	out := make([dynamic]byte, context.temp_allocator)
	for e in d.entries[:d.count] {
		if e.op != 19 {
			append(&out, ..e.raw)
		}
	}
	return out[:]
}

// cff_fd_of reads glyph g's Font DICT from an FDSelect, format 0 or 3.
@(private)
cff_fd_of :: proc(b: []byte, at: int, g: int) -> int {
	if at < 0 || at >= len(b) {
		return 0
	}
	switch b[at] {
	case 0:
		if at + 1 + g < len(b) {
			return int(b[at + 1 + g])
		}
	case 3:
		ranges := int(be16(b, at + 1))
		for i in 0 ..< ranges {
			r := at + 3 + 3 * i
			if g >= int(be16(b, r)) && g < int(be16(b, r + 3)) && r + 2 < len(b) {
				return int(b[r + 2])
			}
		}
	}
	return 0
}

@(private)
put_dict_int :: proc(out: ^[dynamic]byte, v: int) {
	append(out, 29)
	put_u32(out, u32(i32(v)))
}

@(private)
index_off_size :: proc(last: int) -> int {
	switch {
	case last < 1 << 8:
		return 1
	case last < 1 << 16:
		return 2
	case last < 1 << 24:
		return 3
	}
	return 4
}

// index_size is the bytes of an INDEX of count items, size bytes together.
@(private)
index_size :: proc(count, size: int) -> int {
	if count == 0 {
		return 2
	}
	return 3 + (count + 1) * index_off_size(size + 1) + size
}

@(private)
put_index :: proc(out: ^[dynamic]byte, items: [][]byte) {
	data := make([dynamic]byte, context.temp_allocator)
	offs := make([dynamic]int, 0, len(items) + 1, context.temp_allocator)
	append(&offs, 0)
	for it in items {
		append(&data, ..it)
		append(&offs, len(data))
	}
	put_index_packed(out, data[:], offs[:])
}

// put_index_packed writes an INDEX of the items in data, item i running from
// offs[i] to offs[i + 1].
@(private)
put_index_packed :: proc(out: ^[dynamic]byte, data: []byte, offs: []int) {
	count := len(offs) - 1
	put_u16(out, u16(count))
	if count == 0 {
		return
	}
	size := index_off_size(len(data) + 1)
	append(out, byte(size))
	for o in offs {
		v := o + 1
		for k := size - 1; k >= 0; k -= 1 {
			append(out, byte(v >> uint(8 * k)))
		}
	}
	append(out, ..data)
}

// Charstring_Walk copies a Type 2 charstring (Adobe TN 5177) with every
// subroutine call replaced by the subroutine's body. It follows the operand
// stack only as far as it must: the subroutine number a call pops, and the
// stem count that sizes a hintmask.
@(private)
Charstring_Walk :: struct {
	out:            ^[dynamic]byte,
	gsubrs, lsubrs: Cff_Index,
	stack:          [64]Operand,
	sp:             int,
	stems:          int,
	done:           bool,
}

// Operand is a number on the stack and where its bytes start in out.
@(private)
Operand :: struct {
	v, at: int,
}

@(private)
subr_bias :: proc(count: int) -> int {
	switch {
	case count < 1240:
		return 107
	case count < 33900:
		return 1131
	}
	return 32768
}

@(private)
charstring_walk :: proc(w: ^Charstring_Walk, cs: []byte, depth: int) -> bool {
	if depth > 10 || cs == nil {
		return false
	}
	i := 0
	for i < len(cs) && !w.done {
		c := cs[i]
		size, v := 1, 0
		switch {
		case c == 28:
			size, v = 3, int(i16(be16(cs, i + 1)))
		case c >= 32 && c <= 246:
			v = int(c) - 139
		case c >= 247 && c <= 254:
			if i + 1 >= len(cs) {
				return false
			}
			x := int(c >= 251 ? c - 251 : c - 247) * 256 + int(cs[i + 1]) + 108
			size, v = 2, c >= 251 ? -x : x
		case c == 255:
			size, v = 5, int(i32(be32(cs, i + 1))) >> 16
		case c == 10 || c == 29:
			// callsubr, callgsubr
			if w.sp == 0 {
				return false
			}
			w.sp -= 1
			top := w.stack[w.sp]
			resize(w.out, top.at)
			subrs := c == 10 ? w.lsubrs : w.gsubrs
			if !charstring_walk(w, cff_item(subrs, top.v + subr_bias(subrs.count)), depth + 1) {
				return false
			}
			i += 1
			continue
		case c == 11:
			// return
			return true
		case c == 14:
			// endchar
			append(w.out, 14)
			w.done = true
			return true
		case c == 1 || c == 3 || c == 18 || c == 23:
			// the stem hints
			w.stems += w.sp / 2
			w.sp = 0
			append(w.out, c)
			i += 1
			continue
		case c == 19 || c == 20:
			// hintmask, cntrmask: stems may come first
			w.stems += w.sp / 2
			w.sp = 0
			end := i + 1 + (w.stems + 7) / 8
			if end > len(cs) {
				return false
			}
			append(w.out, ..cs[i:end])
			i = end
			continue
		case c == 12:
			if i + 1 >= len(cs) {
				return false
			}
			append(w.out, ..cs[i:i + 2])
			w.sp = 0
			i += 2
			continue
		case:
			append(w.out, c)
			w.sp = 0
			i += 1
			continue
		}
		if i + size > len(cs) || w.sp == len(w.stack) {
			return false
		}
		w.stack[w.sp] = {v, len(w.out)}
		w.sp += 1
		append(w.out, ..cs[i:i + size])
		i += size
	}
	return true
}
