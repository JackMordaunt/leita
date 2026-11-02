package place

import "core:path/filepath"

// xdg_path follows the XDG data-home rule on Linux and FreeBSD. An absolute
// data directory works without HOME; an unset or relative one needs HOME.
@(private)
xdg_path :: proc(data, home: string, allocator := context.allocator) -> string {
	data := data
	if data == "" || !filepath.is_abs(data) {
		if home == "" {return ""}
		data, _ = filepath.join({home, ".local", "share"}, context.temp_allocator)
	}
	path, _ := filepath.join({data, "leita", "history.db"}, allocator)
	return path
}
