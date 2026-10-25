#+build !windows
package leita_files

import "core:os"

// symlink_directory makes path a link to the directory target. Windows has its
// own in link_windows_test.odin.
symlink_directory :: proc(target, path: string) -> bool {
	return os.symlink(target, path) == nil
}

// junction_directory is Windows' alone; elsewhere there is none to make.
junction_directory :: proc(target, path: string) -> bool {
	_, _ = target, path
	return false
}

// set_read_only takes away or gives back the owner's write permission on path.
set_read_only :: proc(path: string, on: bool) -> bool {
	mode := os.Permissions{.Read_User, .Execute_User}
	if !on {
		mode += {.Write_User}
	}
	return os.change_mode(path, mode) == nil
}

// is_read_only is whether path's owner lacks write permission on it.
is_read_only :: proc(path: string) -> bool {
	info, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	return err == nil && .Write_User not_in info.mode
}

// lock_file is Windows' alone, and locks nothing elsewhere: a POSIX rename or
// unlink does not wait for a file's other opens.
lock_file :: proc(path: string) -> rawptr {
	_ = path
	return nil
}

unlock_file :: proc(lock: rawptr) {}
