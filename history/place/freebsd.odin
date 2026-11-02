#+build freebsd
package place

import "core:os"

// default_path is the history store: leita's folder under XDG_DATA_HOME, or
// ~/.local/share when that is unset or relative, as the XDG base directory
// spec has it. "" when there is no home to put it in. history.default_path
// is this procedure.
default_path :: proc(allocator := context.allocator) -> string {
	return xdg_path(
		os.get_env("XDG_DATA_HOME", context.temp_allocator),
		os.get_env("HOME", context.temp_allocator),
		allocator,
	)
}
