#+build windows
package scan

import win32 "core:sys/windows"

// space is the size of the volume holding path and what of it is free to this
// user: GetDiskFreeSpaceExW's lpFreeBytesAvailableToCaller, which its
// documentation says counts quotas, so can be less than what the disk has free.
space :: proc(path: string) -> (total, free: u64, ok: bool) {
	avail, size: win32.ULARGE_INTEGER
	if !win32.GetDiskFreeSpaceExW(
		win32.utf8_to_wstring(path, context.temp_allocator),
		&avail,
		&size,
		nil,
	) {
		return 0, 0, false
	}
	return u64(size), u64(avail), true
}
