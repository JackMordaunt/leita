#+build darwin
package schema

import "../scan"

// Use the existing native statfs binding, including its 64-bit block counts.
volume_state :: proc(path: string) -> (full, readonly: bool) {
	st, ok := scan.stat_fs(path)
	if !ok {return}
	return st.bavail == 0, st.flags & 1 != 0 // MNT_RDONLY, <sys/mount.h>
}
