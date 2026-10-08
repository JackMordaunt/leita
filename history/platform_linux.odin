#+build linux
package sonar_history

import "core:os"
import "core:path/filepath"

// default_path is where the store lives: sonar's folder under XDG_DATA_HOME, or
// ~/.local/share when that is unset, as the XDG base directory spec has it. ""
// when there is no home to put it in.
default_path :: proc(allocator := context.allocator) -> string {
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data == "" || !filepath.is_abs(data) {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" {
			return ""
		}
		data, _ = filepath.join({home, ".local", "share"}, context.temp_allocator)
	}
	path, _ := filepath.join({data, "sonar", "history.db"}, allocator)
	return path
}
