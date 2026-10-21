#+build linux, darwin, freebsd, openbsd, netbsd
package update

import "core:os"

// canonical_existing is the path the kernel names this file, links included.
// It is only called for a path lstat already found, so a missing file is not
// asked of get_absolute_path (that open fails).
canonical_existing :: proc(path: string, allocator := context.temp_allocator) -> (string, bool) {
	p, err := os.get_absolute_path(path, allocator)
	if err != nil {
		return "", false
	}
	return p, true
}
