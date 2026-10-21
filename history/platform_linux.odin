#+build linux
package leita_history

import "place"

// default_path is where the store lives: leita's folder under XDG_DATA_HOME, or
// ~/.local/share when that is unset, as the XDG base directory spec has it. ""
// when there is no home to put it in.
default_path :: proc(allocator := context.allocator) -> string {
	return place.default_path(allocator)
}
