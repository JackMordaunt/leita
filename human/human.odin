/*
Package human writes numbers for a person to read: sizes in decimal units and
counts with their thousands marked, and names from a disk made safe to print. The command line and the window say sizes the
same way because both say them through here.

Sizes are decimal, as SI defines the prefixes and as disks are sold: 1 kB is
1,000 bytes and 1 GB is 1,000,000,000, on every platform, so a report reads the
same on every machine. Input takes the binary units too, GiB and its kin, since
a person may have a figure in those.
*/
package human

import "core:fmt"
import "core:strconv"
import "core:strings"

// bytes is n bytes in decimal units, to one decimal place past a kB.
bytes :: proc(n: u64, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	write_bytes(&sb, n)
	return strings.to_string(sb)
}

/*
write_bytes writes n bytes to sb as bytes says them, for a caller saying a
great many sizes at once rather than making a string of each. Under 1,000
bytes it writes the whole number. Past that it steps up a unit as soon as the
one decimal place would round to 1000.0, so 999,949 bytes is 999.9 kB and
999,950 is 1.0 MB.
*/
write_bytes :: proc(sb: ^strings.Builder, n: u64) {
	units := [?]string{"B", "kB", "MB", "GB", "TB", "PB"}
	if n < 1000 {
		fmt.sbprintf(sb, "%d B", n)
		return
	}
	v := f64(n) / 1000
	i := 1
	for v >= 999.95 && i < len(units) - 1 {
		v /= 1000
		i += 1
	}
	fmt.sbprintf(sb, "%.1f %s", v, units[i])
}

/*
parse_bytes reads a size a flag such as --min-free was given: a number,
optionally fractional, then an optional unit, with or without a space between.
Units are case-insensitive. None, or B, means bytes. K, KB, M, MB, G, GB, T, TB,
P and PB are the decimal units bytes writes, 1,000 apart: 20GB is 20,000,000,000.
KiB, MiB, GiB, TiB and PiB are the binary ones, 1,024 apart: 20GiB is
21,474,836,480. ok is false for anything else, including a negative number, an
empty string, or a size that does not fit in a signed 64-bit count. A size is
kept as one, and a larger one would be stored negative.
*/
parse_bytes :: proc(s: string) -> (n: u64, ok: bool) {
	trimmed := strings.trim_space(s)
	if trimmed == "" {
		return 0, false
	}
	i := 0
	for i < len(trimmed) && (trimmed[i] == '.' || (trimmed[i] >= '0' && trimmed[i] <= '9')) {
		i += 1
	}
	if i == 0 {
		return 0, false
	}
	value, value_ok := strconv.parse_f64(trimmed[:i])
	if !value_ok || value < 0 {
		return 0, false
	}
	unit := strings.trim_space(trimmed[i:])
	factor := unit_factor(strings.to_upper(unit, context.temp_allocator)) or_return
	// NaN fails the first comparison. Past the largest i64, settings would store
	// the size negative and the next scan would treat free space as under it.
	scaled := value * factor
	if !(scaled >= 0) || scaled > f64(max(i64)) {
		return 0, false
	}
	n = u64(scaled)
	if n > u64(max(i64)) {
		return 0, false
	}
	return n, true
}

// unit_factor is the bytes in one of unit, already upper-cased, or false for a
// unit it does not know.
unit_factor :: proc(unit: string) -> (factor: f64, ok: bool) {
	switch unit {
	case "", "B":
		return 1, true
	case "K", "KB":
		return 1e3, true
	case "M", "MB":
		return 1e6, true
	case "G", "GB":
		return 1e9, true
	case "T", "TB":
		return 1e12, true
	case "P", "PB":
		return 1e15, true
	case "KIB":
		return 1024, true
	case "MIB":
		return 1024 * 1024, true
	case "GIB":
		return 1024 * 1024 * 1024, true
	case "TIB":
		return 1024 * 1024 * 1024 * 1024, true
	case "PIB":
		return 1024 * 1024 * 1024 * 1024 * 1024, true
	case:
		return 0, false
	}
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
