#+build windows
package place

import "core:os"
import "core:path/filepath"

// default_path is the history store: leita's folder under the local
// application data folder, which stays on this machine rather than roaming.
// "" when Windows does not say where that is. history.default_path is this
// procedure.
default_path :: proc(allocator := context.allocator) -> string {
	data := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if data == "" {
		return ""
	}
	path, _ := filepath.join({data, "leita", "history.db"}, allocator)
	return path
}
