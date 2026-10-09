#+build darwin
package estoile_history

import "core:os"
import "core:path/filepath"

// default_path is where the store lives: estoile's folder under
// ~/Library/Application Support, where macOS keeps what an application makes for
// itself. "" when there is no home to put it in.
default_path :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	path, _ := filepath.join(
		{home, "Library", "Application Support", "estoile", "history.db"},
		allocator,
	)
	return path
}
