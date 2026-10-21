#+build darwin
package place

import "core:os"
import "core:path/filepath"

// default_path is the history store: leita's folder under
// ~/Library/Application Support. "" when there is no home to put it in.
// history.default_path is this procedure.
default_path :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	path, _ := filepath.join(
		{home, "Library", "Application Support", "leita", "history.db"},
		allocator,
	)
	return path
}
