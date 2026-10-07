/*
Package human writes numbers for a person to read: sizes in binary units and counts
with their thousands marked. The command line and the window say sizes the same way
because both say them through here.
*/
package human

import "core:fmt"
import "core:strings"

// bytes is n bytes in binary units, to one decimal place past a KiB.
bytes :: proc(n: u64, allocator := context.temp_allocator) -> string {
	units := [?]string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}
	v := f64(n)
	i := 0
	for v >= 1024 && i < len(units) - 1 {
		v /= 1024
		i += 1
	}
	if i == 0 {
		return fmt.aprintf("%d B", n, allocator = allocator)
	}
	return fmt.aprintf("%.1f %s", v, units[i], allocator = allocator)
}

// count is n with its thousands separated by commas.
count :: proc(n: u64, allocator := context.temp_allocator) -> string {
	digits := fmt.tprintf("%d", n)
	sb := strings.builder_make(allocator)
	for r, i in digits {
		if i > 0 && (len(digits) - i) % 3 == 0 {
			strings.write_byte(&sb, ',')
		}
		strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}
