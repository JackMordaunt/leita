#+build darwin
package scan

// space is the size of the filesystem holding path and what of it is free to
// this user: statfs(2)'s f_bavail, as df shows, not f_bfree, which counts
// the blocks kept for root.
space :: proc(path: string) -> (total, free: u64, ok: bool) {
	st := stat_fs(path) or_return
	unit := u64(st.bsize)
	return st.blocks * unit, st.bavail * unit, true
}
