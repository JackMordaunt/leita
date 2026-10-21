#+build linux, darwin, freebsd, openbsd, netbsd
package update

import "core:os"
import "core:testing"

@(private)
link_to :: proc(t: ^testing.T, target, link: string, allocator := context.temp_allocator) -> bool {
	_ = allocator
	err := os.symlink(target, link)
	testing.expect_value(t, err, nil)
	return err == nil
}
