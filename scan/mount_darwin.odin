#+build darwin
package scan

import "core:c"
import "core:strings"

foreign import libc "system:System"

@(private = "file")
MAXPATHLEN :: 1024

// Stat_FS is struct statfs from <sys/mount.h> as __DARWIN_STRUCT_STATFS64 lays it
// out, which is what the statfs symbol takes on arm64 and statfs$INODE64 on x86_64.
// statvfs is not used: its block counts are c.uint on Darwin (fsblkcnt_t in
// core/sys/posix/sys_statvfs.odin), too few blocks for a large volume.
Stat_FS :: struct {
	bsize:       u32,
	iosize:      i32,
	blocks:      u64,
	bfree:       u64,
	bavail:      u64,
	files:       u64,
	ffree:       u64,
	fsid:        [2]i32,
	owner:       u32,
	type:        u32,
	flags:       u32,
	fssubtype:   u32,
	fstypename:  [16]u8,
	mntonname:   [MAXPATHLEN]u8,
	mntfromname: [MAXPATHLEN]u8,
	flags_ext:   u32,
	reserved:    [7]u32,
}
#assert(size_of(Stat_FS) == 2168)

when ODIN_ARCH == .amd64 {
	@(private = "file")
	STATFS :: "statfs$INODE64"
} else {
	@(private = "file")
	STATFS :: "statfs"
}

@(private = "file", default_calling_convention = "c")
foreign libc {
	@(link_name = STATFS)
	statfs :: proc(path: cstring, buf: ^Stat_FS) -> c.int ---
}

// stat_fs describes the filesystem holding path, or says it could not.
stat_fs :: proc(path: string) -> (st: Stat_FS, ok: bool) {
	ok = statfs(strings.clone_to_cstring(path, context.temp_allocator), &st) == 0
	return
}

/*
The mount covering `path`, asked of the filesystem holding it rather than read from a
table: statfs names the mount point, the device behind it, and the filesystem.

A path on the Data volume can lie outside its mount point. The system volume reaches
/Users, /Applications and the rest through firmlinks into /System/Volumes/Data, so
such a path is given the root as its mount, which keeps it the path that was asked
for. The device and the filesystem are still the Data volume's.
*/
@(private)
mounted_at_statfs :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	device, mount: string,
	fs: Filesystem,
	found: bool,
) {
	st, ok := stat_fs(path)
	if !ok {
		return "", "", .Unknown, false
	}
	point := string(cstring(&st.mntonname[0]))
	if !covers(point, path) {
		point = "/"
	}
	device = strings.clone(string(cstring(&st.mntfromname[0])), allocator)
	mount = strings.clone(point, allocator)
	fs = filesystem_from_name(string(cstring(&st.fstypename[0])))
	return device, mount, fs, true
}
