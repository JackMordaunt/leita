#+build freebsd
package scan

import "core:strings"
import "core:sys/posix"

// FreeBSD's POSIX statvfs carries 64-bit block counts. Available blocks exclude
// the reserve kept for root, as they do in df and the other platform readers.
space :: proc(path: string) -> (total, free: u64, ok: bool) {
	st: posix.statvfs_t
	if posix.statvfs(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {
		return 0, 0, false
	}
	unit := u64(st.f_frsize if st.f_frsize > 0 else st.f_bsize)
	return freebsd_capacity(u64(st.f_blocks), u64(st.f_bavail), unit)
}
