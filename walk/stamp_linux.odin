#+build linux
package walk

import "core:sys/linux"

/*
Whether the directory at `path` changed at or after `since`, nanoseconds since the
epoch: whether its entries may differ from when it was last read. Adding, removing or
renaming an entry moves a directory's modification time; its change time moves with
anything done to it and, unlike the modification time, utimensat cannot set it back
(inode(7)), so the later of the two is what counts.
A directory that cannot be asked counts as changed, so it is read rather than trusted.
*/
@(private)
changed_since :: proc(path: string, since: i64) -> bool {
	buf: Path
	cpath, ok := terminate(path, &buf)
	if !ok {
		return true
	}
	st: linux.Statx
	if statx_compat(linux.AT_FDCWD, cpath, {}, {.MTIME, .CTIME}, &st) != .NONE {
		return true
	}
	// A kernel that gave no times cannot say it did not change.
	absent := linux.Statx_Mask{.MTIME, .CTIME} - st.mask
	if absent != {} {
		return true
	}
	stamp :: proc(ts: linux.Statx_Timestamp) -> i64 {
		return ts.sec * 1_000_000_000 + i64(ts.nsec)
	}
	return max(stamp(st.mtime), stamp(st.ctime)) >= since
}

// Whether an update asks a copied file its size again, with disk_of.
@(private)
RESTATS :: true

/*
What the file at `path` occupies now, as a walk would charge it. Gone only when
statx says there is no such file (ENOENT, ENOTDIR); any other failure is Unknown,
and the size copied stands.
*/
@(private)
disk_of :: proc(path: string) -> (disk: u64, verdict: Verdict) {
	buf: Path
	cpath, terminated := terminate(path, &buf)
	if !terminated {
		return 0, .Unknown
	}
	st: linux.Statx
	#partial switch statx_compat(linux.AT_FDCWD, cpath, {.SYMLINK_NOFOLLOW}, {.BLOCKS}, &st) {
	case .NONE:
		return st.blocks * 512, .Sized
	case .ENOENT, .ENOTDIR:
		return 0, .Gone
	}
	return 0, .Unknown
}

/*
Whether `path` still names the file `id`: false only when statx finds nothing there
(ENOENT, ENOTDIR) or another file, so a name that cannot be asked is believed.
*/
@(private)
still_names :: proc(path: string, id: File_Id) -> bool {
	buf: Path
	cpath, terminated := terminate(path, &buf)
	if !terminated {
		return true
	}
	st: linux.Statx
	#partial switch statx_compat(linux.AT_FDCWD, cpath, {.SYMLINK_NOFOLLOW}, {.INO}, &st) {
	case .NONE:
		return statx_device(st) == id.device && u64(st.ino) == id.inode
	case .ENOENT, .ENOTDIR:
		return false
	}
	return true
}
