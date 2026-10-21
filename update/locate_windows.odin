#+build windows
package update

import "core:strings"
import win "core:sys/windows"

// reparse_point reports a symlink or other reparse point.
reparse_point :: proc(path: string, allocator := context.temp_allocator) -> bool {
	wide := win.utf8_to_wstring(path, allocator)
	if wide == nil {
		return false
	}
	attr := win.GetFileAttributesW(wide)
	if attr == win.INVALID_FILE_ATTRIBUTES {
		return false
	}
	return attr & win.FILE_ATTRIBUTE_REPARSE_POINT != 0
}

// canonical_existing is the path Windows names after following links. The
// open does not pass FILE_FLAG_OPEN_REPARSE_POINT, so a symlink is not
// returned as its own name. \\?\ and \\?\UNC\ are stripped: classification
// matches the path a person sees.
canonical_existing :: proc(path: string, allocator := context.temp_allocator) -> (string, bool) {
	wide := win.utf8_to_wstring(path, allocator)
	if wide == nil {
		return "", false
	}
	h := win.CreateFileW(
		wide,
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		h = win.CreateFileW(
			wide,
			win.GENERIC_READ,
			win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
			nil,
			win.OPEN_EXISTING,
			win.FILE_FLAG_BACKUP_SEMANTICS,
			nil,
		)
	}
	if h == win.INVALID_HANDLE_VALUE {
		return "", false
	}
	defer win.CloseHandle(h)

	buf := make([]u16, 1024, allocator)
	n := win.GetFinalPathNameByHandleW(h, cstring16(raw_data(buf)), u32(len(buf)), win.VOLUME_NAME_DOS)
	if n == 0 {
		return "", false
	}
	if n >= u32(len(buf)) {
		if n > 32_768 {
			return "", false
		}
		buf = make([]u16, n, allocator)
		n = win.GetFinalPathNameByHandleW(h, cstring16(raw_data(buf)), u32(len(buf)), win.VOLUME_NAME_DOS)
		if n == 0 || n >= u32(len(buf)) {
			return "", false
		}
	}
	s, uerr := win.utf16_to_utf8(buf[:n], allocator)
	if uerr != nil || len(s) == 0 {
		return "", false
	}
	if strings.has_prefix(s, `\\?\UNC\`) {
		s = strings.concatenate({`\\`, s[len(`\\?\UNC\`):]}, allocator)
	} else if strings.has_prefix(s, `\\?\`) {
		s = s[len(`\\?\`):]
	}
	return s, true
}
