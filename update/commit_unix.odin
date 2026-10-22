#+build linux, darwin, freebsd, openbsd, netbsd
package update

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

import "../kstat"

// preserve_permissions copies the mode bits. A failure leaves the live
// executable untouched: the caller has not replaced it yet.
preserve_permissions :: proc(exe, fresh: string, allocator := context.temp_allocator) -> (ok: bool, note: string) {
	info, err := kstat.stat(exe, allocator)
	if err != nil {
		os.file_info_delete(info, allocator)
		return false, fmt.tprintf("stat error %v", err)
	}
	mode := info.mode & os.Permissions_All
	os.file_info_delete(info, allocator)
	if cerr := os.change_mode(fresh, mode); cerr != nil {
		return false, fmt.tprintf("chmod error %v", cerr)
	}
	return true, ""
}

// replace_atomically is rename(2) over the existing path. The directory
// entry changes in one step; a crash does not leave the name absent.
// unsupported is never set on these systems.
replace_atomically :: proc(from, to: string) -> (ok, unsupported: bool, note: string) {
	if err := os.rename(from, to); err != nil {
		return false, false, fmt.tprintf("%v", err)
	}
	fsync_dir(parent_of(to))
	return true, false, ""
}

// sync_file pushes the backup's bytes out before its name is published.
sync_file :: proc(f: ^os.File) -> bool {
	if f == nil {
		return false
	}
	return posix.fsync(posix.FD(os.fd(f))) == .OK
}

// fsync_dir publishes the rename. A failure here does not undo a replace
// that already succeeded: the entry is already the new file.
@(private)
fsync_dir :: proc(dir: string, allocator := context.temp_allocator) {
	if len(dir) == 0 {
		return
	}
	fd := posix.open(strings.clone_to_cstring(dir, allocator), {.CLOEXEC}, {})
	if fd < 0 {
		return
	}
	_ = posix.fsync(fd)
	posix.close(fd)
}
