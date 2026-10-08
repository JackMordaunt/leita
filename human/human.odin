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
	sb := strings.builder_make(allocator)
	write_bytes(&sb, n)
	return strings.to_string(sb)
}

// write_bytes writes n bytes to sb as bytes says them, for a caller saying a
// great many sizes at once rather than making a string of each.
write_bytes :: proc(sb: ^strings.Builder, n: u64) {
	units := [?]string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}
	v := f64(n)
	i := 0
	for v >= 1024 && i < len(units) - 1 {
		v /= 1024
		i += 1
	}
	if i == 0 {
		fmt.sbprintf(sb, "%d B", n)
		return
	}
	fmt.sbprintf(sb, "%.1f %s", v, units[i])
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
