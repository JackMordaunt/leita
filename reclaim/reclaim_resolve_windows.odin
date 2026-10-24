#+build windows
package reclaim

import "../home"

// host_confine does not follow a symlink on Windows. refused_as_root does not
// call root_may_delete here, and a Win32
// GetFinalPathNameByHandle path was not executed on a Windows machine. ".." is
// still collapsed by lexical_clean. A symlink ancestor on Windows is not caught
// by this package.
@(private)
host_confine :: proc(path: string) -> Confinement {
	return {lexical_clean(path, .Windows, context.temp_allocator), true}
}

// refused_as_root is never true on Windows, where Reclaim does not act as root.
refused_as_root :: proc(
	path: string,
	who: home.User,
	euid: u32,
	allocator := context.temp_allocator,
) -> bool {
	return false
}
