#+build linux, freebsd, openbsd, netbsd
package schema

import "core:strings"
import "core:sys/posix"

volume_state :: proc(path: string) -> (full, readonly: bool) {
	st: posix.statvfs_t
	if posix.statvfs(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {return}
	return st.f_bavail == 0, .RDONLY in st.f_flag
}
