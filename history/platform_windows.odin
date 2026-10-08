#+build windows
package sonar_history

import "core:os"
import "core:path/filepath"

// default_path is where the store lives: sonar's folder under the local
// application data folder, which stays on this machine rather than roaming. ""
// when Windows does not say where that is.
default_path :: proc(allocator := context.allocator) -> string {
	data := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if data == "" {
		return ""
	}
	path, _ := filepath.join({data, "sonar", "history.db"}, allocator)
	return path
}
