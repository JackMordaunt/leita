#+build !linux
package kstat

import "core:os"

// These systems answer os.stat; each is the os call by another name, so a caller
// is the same on every system.

stat :: proc(path: string, allocator := context.allocator) -> (info: os.File_Info, err: os.Error) {
	return os.stat(path, allocator)
}

lstat :: proc(path: string, allocator := context.allocator) -> (info: os.File_Info, err: os.Error) {
	return os.lstat(path, allocator)
}

is_file :: proc(path: string) -> bool {
	return os.is_file(path)
}

is_dir :: proc(path: string) -> bool {
	return os.is_dir(path)
}

read_directory :: proc(path: string, allocator := context.allocator) -> (list: []os.File_Info, err: os.Error) {
	return os.read_all_directory_by_path(path, allocator)
}

resolve_command :: proc(argv: []string, allocator := context.temp_allocator) -> []string {
	return argv
}
