#+build windows
package leita_app

import "core:fmt"
import "core:log"
import "core:strings"
import win "core:sys/windows"

/*
link_directory makes path a junction to the directory target. core:os's symlink
is unsupported on Windows, and a junction needs no privilege. lstat calls it a
directory; Reclaim must not offer it. false, with the reason logged, where the
volume refuses the reparse point. Not symlink_directory: that helper calls
CreateSymbolicLinkW, and this test is of a junction.
*/
//review:ignore matches-neighbours This helper creates a Windows junction; symlink_directory creates a symbolic link.
link_directory :: proc(target, path: string) -> bool {
	if !win.CreateDirectoryW(long_path(path), nil) {
		log.warnf("could not make %s: %d", path, win.GetLastError())
		return false
	}
	d := win.CreateFileW(
		long_path(path),
		win.GENERIC_WRITE,
		0,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if d == win.INVALID_HANDLE_VALUE {
		log.warnf("could not open %s: %d", path, win.GetLastError())
		return false
	}
	defer win.CloseHandle(d)

	slashed, _ := strings.replace_all(target, "/", `\`, context.temp_allocator)
	substitute := win.utf8_to_wstring(fmt.tprintf(`\??\%s`, slashed), context.temp_allocator)
	units := len(string16(substitute))
	// The substitute name and the print name, each terminated; the print name is
	// left empty. The same layout walk/read_windows_test.odin writes.
	names := u16((units + 1 + 1) * size_of(u16))
	buf: [1024]u32
	raw := ([^]u8)(&buf)
	rdb := (^win.REPARSE_DATA_BUFFER)(raw)
	rdb.ReparseTag = win.IO_REPARSE_TAG_MOUNT_POINT
	mp := (^win.MOUNT_POINT_REPARSE_BUFFER)(&raw[size_of(win.REPARSE_DATA_BUFFER)])
	mp.SubstituteNameOffset = 0
	mp.SubstituteNameLength = u16(units * size_of(u16))
	mp.PrintNameOffset = u16((units + 1) * size_of(u16))
	mp.PrintNameLength = 0
	path_buffer := ([^]u16)(&mp.PathBuffer)
	copy(path_buffer[:units], ([^]u16)(substitute)[:units])
	path_buffer[units] = 0
	path_buffer[units + 1] = 0
	data := u16(offset_of(win.MOUNT_POINT_REPARSE_BUFFER, PathBuffer)) + names
	rdb.ReparseDataLength = data
	total := win.DWORD(size_of(win.REPARSE_DATA_BUFFER)) + win.DWORD(data)
	returned: win.DWORD
	if !win.DeviceIoControl(d, win.FSCTL_SET_REPARSE_POINT, &buf, total, nil, 0, &returned, nil) {
		log.warnf("could not make %s a junction to %s: %d", path, target, win.GetLastError())
		return false
	}
	return true
}

// long_path is path with the prefix that lifts the 260-character limit.
@(private = "file")
long_path :: proc(path: string) -> win.wstring {
	slashed, _ := strings.replace_all(path, "/", `\`, context.temp_allocator)
	return win.utf8_to_wstring(fmt.tprintf(`\\?\%s`, slashed), context.temp_allocator)
}
