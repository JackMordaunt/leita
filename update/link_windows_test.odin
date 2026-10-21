#+build windows
package update

import "core:fmt"
import "core:testing"
import win "core:sys/windows"

// link_to points link at target with CreateSymbolicLinkW.
@(private)
link_to :: proc(t: ^testing.T, target, link: string, allocator := context.temp_allocator) -> bool {
	wide_link := win.utf8_to_wstring(link, allocator)
	wide_target := win.utf8_to_wstring(target, allocator)
	if wide_link == nil || wide_target == nil {
		testing.expect(t, false, "utf8_to_wstring failed for the symlink")
		return false
	}
	ok := win.CreateSymbolicLinkW(
		wide_link,
		wide_target,
		win.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE,
	)
	if ok {
		return true
	}
	err := win.GetLastError()
	testing.expect(t, false, fmt.tprintf("CreateSymbolicLinkW error %d", err))
	return false
}
