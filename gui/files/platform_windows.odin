#+build windows
package sonar_files

import "core:strings"
import win32 "core:sys/windows"

SEPARATOR  :: `\`
SEPARATORS :: `\/`

// rename_noreplace renames from to to, failing with Exists rather than replacing
// whatever is at to: MoveFileExW without MOVEFILE_REPLACE_EXISTING never replaces,
// and without MOVEFILE_COPY_ALLOWED never copies between volumes.
rename_noreplace :: proc(from, to: string) -> Error {
	f := win32.utf8_to_wstring(from, context.temp_allocator)
	t := win32.utf8_to_wstring(to, context.temp_allocator)
	if !win32.MoveFileExW(f, t, 0) {
		return win32_error(win32.GetLastError())
	}
	return .None
}

// trash moves path to the Recycle Bin through the shell, as Explorer does.
trash :: proc(path: string) -> Error {
	wide := win32.utf8_to_utf16(path, context.temp_allocator)
	from := make([]u16, len(wide) + 2, context.temp_allocator) // the list ends in two NULs
	copy(from, wide)
	op := win32.SHFILEOPSTRUCTW {
		wFunc  = win32.FO_DELETE,
		pFrom  = cstring16(raw_data(from)),
		fFlags = win32.FOF_ALLOWUNDO | win32.FOF_NO_UI,
	}
	if win32.SHFileOperationW(&op) != 0 || op.fAnyOperationsAborted {
		return .Other
	}
	return .None
}

// reveal opens Explorer with path selected.
@(private)
reveal :: proc(path: string) {
	run({"explorer.exe", strings.concatenate({"/select,", path}, context.temp_allocator)})
}

@(private = "file")
win32_error :: proc(code: win32.DWORD) -> Error {
	switch code {
	case win32.ERROR_ALREADY_EXISTS, win32.ERROR_FILE_EXISTS:
		return .Exists
	case win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND:
		return .Missing
	case win32.ERROR_ACCESS_DENIED:
		return .Denied
	case 17:
		// ERROR_NOT_SAME_DEVICE, which core:sys/windows does not name
		return .Cross_Device
	}
	return .Other
}
