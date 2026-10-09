#+build linux, darwin
package walk

import "core:mem"
import "core:strings"

// A path as the kernel wants it. Long enough for anything the kernel will accept, so
// building one costs no allocation.
@(private)
Path :: [4096]u8

@(private)
terminate :: proc(path: string, buf: ^Path) -> (cstring, bool) {
	if len(path) >= len(buf) {
		return nil, false
	}
	copy(buf[:], path)
	buf[len(path)] = 0
	return cstring(&buf[0]), true
}

// The child's path, which getdents does not hand back and the queue needs.
@(private)
join :: proc(dir, name: string, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	if strings.has_suffix(dir, "/") {
		return strings.concatenate({dir, name}, allocator)
	}
	return strings.concatenate({dir, "/", name}, allocator)
}
