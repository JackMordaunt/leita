#+build darwin
package leita_history

import "place"

// default_path is where the store lives: leita's folder under
// ~/Library/Application Support, where macOS keeps what an application makes for
// itself. "" when there is no home to put it in.
default_path :: proc(allocator := context.allocator) -> string {
	return place.default_path(allocator)
}
