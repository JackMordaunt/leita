#+build windows
package walk

import "core:mem"

// Linux and macOS keep a root descriptor here (read_linux.odin, read_darwin.odin).
// Windows opens each directory by the path it queued and checks that it is the one
// listed (read_windows.odin).
@(private)
Anchor :: struct {}

@(private)
anchor_prepare :: proc(
	path: string,
	follow: bool,
	allocator: mem.Allocator,
) -> (
	Anchor,
	mem.Allocator_Error,
) {
	_ = path
	_ = follow
	_ = allocator
	return {}, nil
}

@(private)
anchor_release :: proc(a: ^Anchor) {
	_ = a
}
