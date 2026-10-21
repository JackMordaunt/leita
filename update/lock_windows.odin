#+build windows
package update

import "core:strings"
import win "core:sys/windows"

// Install_Lock is the lock taken, held until unlock or the process ends.
Install_Lock :: struct {
	handle: win.HANDLE,
}

// lock_install takes the lock on exe + LOCK_SUFFIX without waiting. The file
// is opened sharing nothing, so any other open fails until this handle
// closes, which Windows does when the process ends. The file stays.
lock_install :: proc(exe: string, allocator := context.temp_allocator) -> (l: Install_Lock, result: Lock_Result) {
	path := strings.concatenate({exe, LOCK_SUFFIX}, allocator)
	h := win.CreateFileW(
		win.utf8_to_wstring(path, allocator),
		win.GENERIC_READ | win.GENERIC_WRITE,
		0,
		nil,
		win.OPEN_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		if win.GetLastError() == win.ERROR_SHARING_VIOLATION {
			return {}, .Held
		}
		return {}, .Failed
	}
	return {h}, .Taken
}

// unlock_install lets the lock go. The file is left in place.
unlock_install :: proc(l: ^Install_Lock) {
	if l.handle != nil {
		win.CloseHandle(l.handle)
	}
	l^ = {}
}

// block_on_lock waits until one byte of path can be locked exclusively.
// Share modes stay open so the test can hold the same byte. The file must
// already exist.
block_on_lock :: proc(path: string, allocator := context.temp_allocator) -> bool {
	h := win.CreateFileW(
		win.utf8_to_wstring(path, allocator),
		win.GENERIC_READ | win.GENERIC_WRITE,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		return false
	}
	defer win.CloseHandle(h)
	ov: win.OVERLAPPED
	// EXCLUSIVE, and not FAIL_IMMEDIATELY: wait until the holder lets go.
	return bool(
		win.LockFileEx(h, 0x2, 0, 1, 0, &ov),
	)
}
