#+build windows
package leita_files

import "core:strings"
import win32 "core:sys/windows"

// symlink_directory makes path a link to the directory target, which core:os's
// symlink refuses on Windows as unsupported (core/os/file_windows.odin). It needs
// Developer Mode or an elevated process, as a CI runner is.
symlink_directory :: proc(target, path: string) -> bool {
	flags :=
		win32.SYMBOLIC_LINK_FLAG_DIRECTORY | win32.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
	link := win32.utf8_to_wstring(path, context.temp_allocator)
	to := win32.utf8_to_wstring(target, context.temp_allocator)
	return bool(win32.CreateSymbolicLinkW(link, to, flags))
}

// set_read_only sets or clears path's read-only attribute through
// SetFileAttributesW. core:os's change_mode opens the path for writing first
// (_chmod in core/os/file_windows.odin).
set_read_only :: proc(path: string, on: bool) -> bool {
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	attributes := win32.GetFileAttributesW(wide)
	if attributes == win32.INVALID_FILE_ATTRIBUTES {
		return false
	}
	if on {
		attributes |= win32.FILE_ATTRIBUTE_READONLY
	} else {
		attributes &~= win32.FILE_ATTRIBUTE_READONLY
	}
	return bool(win32.SetFileAttributesW(wide, attributes))
}

// is_read_only is whether path has the read-only attribute.
is_read_only :: proc(path: string) -> bool {
	attributes := win32.GetFileAttributesW(win32.utf8_to_wstring(path, context.temp_allocator))
	return attributes != win32.INVALID_FILE_ATTRIBUTES && attributes & win32.FILE_ATTRIBUTE_READONLY != 0
}

// junction_directory makes path, which must not exist, a junction to the directory
// target, an absolute path: it writes a mount-point reparse point with
// FSCTL_SET_REPARSE_POINT.
junction_directory :: proc(target, path: string) -> bool {
	link := win32.utf8_to_wstring(path, context.temp_allocator)
	if !win32.CreateDirectoryW(link, nil) {
		return false
	}
	d := win32.CreateFileW(
		link,
		win32.GENERIC_WRITE,
		0,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if d == win32.INVALID_HANDLE_VALUE {
		return false
	}
	defer win32.CloseHandle(d)

	substitute := win32.utf8_to_utf16(
		strings.concatenate({`\??\`, target}, context.temp_allocator),
		context.temp_allocator,
	)
	units := len(substitute)
	buf: [1024]u32
	raw := ([^]u8)(&buf)
	rdb := (^win32.REPARSE_DATA_BUFFER)(raw)
	rdb.ReparseTag = win32.IO_REPARSE_TAG_MOUNT_POINT
	mp := (^win32.MOUNT_POINT_REPARSE_BUFFER)(&raw[size_of(win32.REPARSE_DATA_BUFFER)])
	mp.SubstituteNameLength = u16(units * size_of(u16))
	mp.PrintNameOffset = u16((units + 1) * size_of(u16))
	names := ([^]u16)(&mp.PathBuffer)
	copy(names[:units], substitute)
	names[units] = 0
	names[units + 1] = 0
	data := u16(offset_of(win32.MOUNT_POINT_REPARSE_BUFFER, PathBuffer)) + u16((units + 2) * size_of(u16))
	rdb.ReparseDataLength = data
	total := win32.DWORD(size_of(win32.REPARSE_DATA_BUFFER)) + win32.DWORD(data)
	returned: win32.DWORD
	return bool(win32.DeviceIoControl(d, win32.FSCTL_SET_REPARSE_POINT, &buf, total, nil, 0, &returned, nil))
}
