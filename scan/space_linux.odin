#+build linux
package scan

import "core:strings"
import "core:sys/linux"

// space is the size of the filesystem holding path and what of it is free to
// this user: statfs(2)'s f_bavail, as df shows, not f_bfree, which counts
// the blocks kept for root.
space :: proc(path: string) -> (total, free: u64, ok: bool) {
	st: linux.Stat_FS
	if linux.statfs(strings.clone_to_cstring(path, context.temp_allocator), &st) != .NONE {
		return 0, 0, false
	}
	unit := u64(st.frsize if st.frsize > 0 else st.bsize)
	return u64(st.blocks) * unit, u64(st.bavail) * unit, true
}
