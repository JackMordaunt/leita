#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
package schema

import "core:os"

// Non-POSIX file locks are tied to their owning handles, so metadata reads
// do not release the process-scoped locks addressed by file_size_posix.
@(private)
file_size :: proc(path: string) -> (size: i64, missing, known: bool) {
	info, err := os.stat(path, context.temp_allocator)
	return i64(info.size), err == os.General_Error.Not_Exist, err == nil
}

@(private)
path_missing :: proc(path: string) -> bool {
	_, err := os.lstat(path, context.temp_allocator)
	return err == os.General_Error.Not_Exist
}
