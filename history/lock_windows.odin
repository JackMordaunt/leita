#+build windows
package sonar_history

import win32 "core:sys/windows"

// Lock is a lock taken on a file, held until unlock or the process ends.
Lock :: struct {
	handle: win32.HANDLE,
}

// lock takes an exclusive lock on the file at path, making it if it is missing,
// without waiting: the file is opened sharing nothing, so any other open of it
// fails until this handle closes, which Windows does when the process ends, as
// CreateFileW (dwShareMode 0) and ExitProcess have it.
lock :: proc(path: string) -> (l: Lock, result: Lock_Result) {
	h := win32.CreateFileW(
		win32.utf8_to_wstring(path, context.temp_allocator),
		win32.GENERIC_READ | win32.GENERIC_WRITE,
		0,
		nil,
		win32.OPEN_ALWAYS,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win32.INVALID_HANDLE_VALUE {
		if win32.GetLastError() == win32.ERROR_SHARING_VIOLATION {
			return {}, .Held
		}
		return {}, .Failed
	}
	return {h}, .Taken
}

// unlock lets the lock go.
unlock :: proc(l: ^Lock) {
	if l.handle != nil {
		win32.CloseHandle(l.handle)
	}
	l^ = {}
}
