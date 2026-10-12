package leita_webhook

import "core:strings"

// trim_name is a machine's name as the system wrote it, less what pads it, in
// the temp allocator.
@(private)
trim_name :: proc(s: string) -> string {
	return strings.clone(strings.trim_space(strings.trim_right_null(s)), context.temp_allocator)
}
