package walk

import "core:strconv"
import "core:strings"

/*
The CPUs a cgroup v2 `cpu.max` allows, rounded up so a share of one still gets one.

The file holds a quota and the period it is measured over, both in microseconds, or
"max" for no quota: "150000 100000" is one and a half CPUs. Not ok when there is no
quota or the text is not one.
*/
@(private)
cpu_max_limit :: proc(text: string) -> (cpus: int, ok: bool) {
	fields := strings.fields(text, context.temp_allocator)
	if len(fields) != 2 || fields[0] == "max" {
		return 0, false
	}
	quota := strconv.parse_int(fields[0], 10) or_return
	period := strconv.parse_int(fields[1], 10) or_return
	if quota <= 0 || period <= 0 {
		return 0, false
	}
	return (quota + period - 1) / period, true
}
