package argv

import "core:strings"
import "core:unicode/utf8"

// command_arg is one argument's text. units are its UTF-16 code units.
// U+2026, the checking line's ellipsis, is three UTF-8 bytes.
command_arg :: proc(units: []u16, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(units) {
		u := units[i]
		i += 1
		r := rune(u)
		if u >= 0xD800 && u <= 0xDBFF && i < len(units) {
			lo := units[i]
			if lo >= 0xDC00 && lo <= 0xDFFF {
				i += 1
				r = 0x10000 + ((rune(u) - 0xD800) << 10) + (rune(lo) - 0xDC00)
			}
		}
		buf, n := utf8.encode_rune(r)
		strings.write_bytes(&b, buf[:n])
	}
	return strings.to_string(b)
}
