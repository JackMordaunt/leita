#+build windows
package reclaim

// host_confine does not follow a symlink on Windows. refused_as_root does not
// call root_may_delete here (gui/app/act.odin), and a Win32
// GetFinalPathNameByHandle path was not executed on a Windows machine. ".." is
// still collapsed by lexical_clean. A symlink ancestor on Windows is not caught
// by this package.
@(private)
host_confine :: proc(path: string) -> Confinement {
	return {lexical_clean(path, .Windows, context.temp_allocator), true}
}
