#+build !freebsd
package walk

import "core:testing"

@(private)
fixture_sync :: proc(t: ^testing.T, path: string, length: int) {}

@(private)
fixture_sync_fd :: proc(t: ^testing.T, fd: int, length: int) {}
