package human

import "core:strings"
import "core:unicode/utf8"

/*
shown is s as a person reads a name from a disk, on a terminal or in a report: a
byte that is not UTF-8 as U+FFFD, a C0 control or DEL as its control picture
(U+2400 to U+2421, so ESC is ␛ and a newline ␊), and a C1 control or a bidi
override or isolate (U+202A to U+202E, U+2066 to U+2069) as U+FFFD, which have no
picture. A name that holds an escape sequence, a line break or a right-to-left
override then neither runs in the terminal, nor breaks a row, nor hides what it
says. Text that needs none of this comes back as it is, with no copy made.
*/
shown :: proc(s: string, allocator := context.temp_allocator) -> string {
	clean := true
	for i := 0; i < len(s); {
		r, size := utf8.decode_rune_in_string(s[i:])
		if hostile(r, size) {
			clean = false
			break
		}
		i += size
	}
	if clean {
		return s
	}
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); {
		r, size := utf8.decode_rune_in_string(s[i:])
		switch {
		case r < 0x20:
			strings.write_rune(&sb, 0x2400 + r)
		case r == 0x7f:
			strings.write_rune(&sb, 0x2421)
		case hostile(r, size):
			strings.write_rune(&sb, utf8.RUNE_ERROR)
		case:
			strings.write_string(&sb, s[i:i + size])
		}
		i += size
	}
	return strings.to_string(sb)
}

// hostile says whether shown must rewrite the rune r, size bytes of its text.
@(private)
hostile :: proc(r: rune, size: int) -> bool {
	switch {
	case r == utf8.RUNE_ERROR && size == 1:
		return true
	case r < 0x20, r == 0x7f, r >= 0x80 && r <= 0x9f:
		return true
	case r >= 0x202a && r <= 0x202e, r >= 0x2066 && r <= 0x2069:
		return true
	}
	return false
}
