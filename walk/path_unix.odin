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

/*
The first piece of `path` the kernel takes in one call, where `limit` bytes,
terminator included, is the most it takes (PATH_MAX), and what follows it. The
piece ends before a slash and the rest starts after every slash there, so the rest
is never absolute: opened from the piece's descriptor, it lies beneath it. Not ok
when no slash lies within `limit`: one name that long is past NAME_MAX, 255 in
linux/limits.h and macOS's sys/syslimits.h.
*/
@(private)
next_piece :: proc(path: string, limit: int) -> (piece, rest: string, ok: bool) {
	if len(path) < limit {
		return path, "", true
	}
	cut := strings.last_index_byte(path[:limit], '/')
	for cut > 0 && path[cut - 1] == '/' {
		cut -= 1
	}
	if cut <= 0 {
		return "", "", false
	}
	return path[:cut], strings.trim_left(path[cut:], "/"), true
}

// The child's path, which getdents does not hand back and the queue needs.
@(private)
join :: proc(dir, name: string, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	if strings.has_suffix(dir, "/") {
		return strings.concatenate({dir, name}, allocator)
	}
	return strings.concatenate({dir, "/", name}, allocator)
}

// `path` relative to `root`, as `join` built it. Not ok unless `path` is `root`
// or a slash separates `root` from the rest.
@(private)
rel_under :: proc(root, path: string) -> (rel: string, ok: bool) {
	if path == root {
		return "", true
	}
	base := root
	if len(base) > 1 && base[len(base) - 1] == '/' {
		base = base[:len(base) - 1]
	}
	if base == "/" {
		if len(path) > 1 && path[0] == '/' {
			return path[1:], true
		}
		return "", false
	}
	if len(path) <= len(base) || path[:len(base)] != base || path[len(base)] != '/' {
		return "", false
	}
	rest := path[len(base) + 1:]
	if rest == "" {
		return "", false
	}
	return rest, true
}
