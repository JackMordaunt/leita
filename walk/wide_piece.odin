package walk

import "core:strings"

// UNICODE_PATH_MAX is the most UTF-16 units one UNICODE_STRING can hold.
// Length counts bytes in a u16 and must be even, so 65,534 bytes: 32,767
// units. The NUL on a Win32 path is not part of Length. CreateFileW cannot
// open a directory past this.
@(private)
UNICODE_PATH_MAX :: 32767

// rune_units is how many UTF-16 units `r` takes. A rune past U+FFFF is a
// surrogate pair. A rune a string yields is never a surrogate, and a surrogate
// would be one replacement unit, which is what utf16.encode_string writes.
@(private)
rune_units :: proc(r: rune) -> int {
	if r <= 0xFFFF {
		return 1
	}
	return 2
}

// utf16_len is the UTF-16 length of text, in units.
@(private)
utf16_len :: proc(text: string) -> int {
	n := 0
	for r in text {
		n += rune_units(r)
	}
	return n
}

/*
The first piece of `path` that fits in `limit` UTF-16 units, and what follows
it. The piece ends before a separator and the rest starts after every separator
there, so the rest is never absolute: opened from the piece's directory, it
lies beneath it. A path that fits is returned whole.

Not ok when the path is empty, or when no separator lies within `limit`: one
name that long cannot be opened by splitting it. `\` and `/` are separators.
*/
@(private)
next_wide_piece :: proc(path: string, limit: int) -> (piece, rest: string, ok: bool) {
	if path == "" || limit <= 0 {
		return "", "", false
	}
	last, fits := scan_wide_piece(path, limit)
	if fits {
		return path, "", true
	}
	return cut_wide_piece(path, last)
}

// scan_wide_piece is the byte index of the last separator inside `limit`
// UTF-16 units, and whether the whole path fits. last is -1 when there is none.
@(private)
scan_wide_piece :: proc(path: string, limit: int) -> (last: int, fits: bool) {
	units := 0
	last = -1
	fits = true
	for r, i in path {
		need := rune_units(r)
		if units + need > limit {
			fits = false
			return
		}
		units += need
		if r == '\\' || r == '/' {
			last = i
		}
	}
	return
}

// cut_wide_piece splits path at the separator run ending at last. Not ok when
// that leaves an empty piece or an empty rest.
@(private)
cut_wide_piece :: proc(path: string, last: int) -> (piece, rest: string, ok: bool) {
	if last <= 0 {
		return "", "", false
	}
	cut := last
	for cut > 0 && sep_byte(path[cut - 1]) {
		cut -= 1
	}
	if cut <= 0 {
		return "", "", false
	}
	rest = strings.trim_left(path[cut:], `\/`)
	if rest == "" {
		return "", "", false
	}
	return path[:cut], rest, true
}

@(private)
sep_byte :: proc(c: u8) -> bool {
	return c == '\\' || c == '/'
}
