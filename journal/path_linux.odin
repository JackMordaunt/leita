#+build linux
package journal

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

/*
canonical is path as the recorder spells the directories it records: opened, then
read back through /proc/self/fd, so links are followed and the spelling is the
kernel's. In allocator; not ok when path cannot be opened.
*/
canonical :: proc(path: string, allocator := context.allocator) -> (out: string, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, {.PATH, .CLOEXEC})
	if err != .NONE {
		return "", false
	}
	defer linux.close(fd)
	return fd_path(fd, allocator)
}

// fd_path is the path the open file fd names, in allocator.
@(private)
fd_path :: proc(fd: linux.Fd, allocator := context.allocator) -> (out: string, ok: bool) {
	link := fmt.ctprintf("/proc/self/fd/%d", int(fd))
	buf: [PATH_MAX]u8
	n, err := linux.readlink(link, buf[:])
	if err != .NONE || n <= 0 || n >= len(buf) {
		return "", false
	}
	return strings.clone(string(buf[:n]), allocator), true
}

/*
mount_of is where the mount that holds path is mounted, in allocator: the mount
statx(2) names by its id, as /proc/self/mountinfo spells its point. A log covers a
place only when its paths are spelt from that point.
*/
mount_of :: proc(path: string, allocator := context.allocator) -> (point: string, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: linux.Statx
	if linux.statx(linux.AT_FDCWD, cpath, {}, {.MNT_ID}, &st) != .NONE || .MNT_ID not_in st.mask {
		return "", false
	}
	text, err := os.read_entire_file("/proc/self/mountinfo", context.temp_allocator)
	if err != nil {
		return "", false
	}
	mounts := mounts_parse(string(text), context.temp_allocator)
	m := mount_by_id(mounts, int(st.mnt_id)) or_return
	return strings.clone(m.point, allocator), true
}

// fsid_of is the id statfs(2) gives the filesystem path is on, which names its log.
fsid_of :: proc(path: string) -> (fsid: [2]i32, ok: bool) {
	st: linux.Stat_FS
	if linux.statfs(strings.clone_to_cstring(path, context.temp_allocator), &st) != .NONE {
		return {}, false
	}
	return st.fsid, true
}
