#+build windows
package leita_history

import "place"

// default_path is where the store lives: leita's folder under the local
// application data folder, which stays on this machine rather than roaming. ""
// when Windows does not say where that is.
default_path :: proc(allocator := context.allocator) -> string {
	return place.default_path(allocator)
}
