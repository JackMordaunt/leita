#+build linux, darwin, freebsd, openbsd, netbsd
package schema

import "core:strings"
import "core:sys/posix"

// core:os.stat opens and closes a file descriptor on POSIX. Use the native
// metadata syscall instead: close must not drop an existing SQLite lock.
@(private)
file_size :: proc(path: string) -> (size: i64, missing, known: bool) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {
		return 0, posix.errno() == .ENOENT, false
	}
	return i64(st.st_size), false, true
}

@(private)
path_missing :: proc(path: string) -> bool {
	st: posix.stat_t
	return posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK && posix.errno() == .ENOENT
}
