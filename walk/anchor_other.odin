#+build !linux
package walk

import "core:mem"

// Linux keeps a root descriptor here (read_linux.odin). Elsewhere a walk opens
// each directory by the path it queued.
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
