#+build windows
package scan

import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	// Not bound by core:sys/windows, so declared here.
	GetVolumePathNameW    :: proc(lpszFileName: win.LPCWSTR, lpszVolumePathName: win.LPWSTR, cchBufferLength: win.DWORD) -> win.BOOL ---
	GetVolumeInformationW :: proc(lpRootPathName: win.LPCWSTR, lpVolumeNameBuffer: win.LPWSTR, nVolumeNameSize: win.DWORD, lpVolumeSerialNumber: ^win.DWORD, lpMaximumComponentLength: ^win.DWORD, lpFileSystemFlags: ^win.DWORD, lpFileSystemNameBuffer: win.LPWSTR, nFileSystemNameSize: win.DWORD) -> win.BOOL ---
	GetCurrentProcess     :: proc() -> win.HANDLE ---
}

/*
Resolve what was given into a target backends can dispatch on.

A bare drive letter is accepted for convenience, an existing path is asked about, and
anything else is taken to be an image file holding a volume. Failing here is better
than failing inside a backend, because this is the layer that knows why.
*/
resolve :: proc(input: string, allocator := context.allocator) -> (t: Target, err: Error) {
	t.allocator = allocator
	t.input = strings.clone(input, allocator)

	path := input
	if is_drive_spec(input) {
		path = strings.concatenate({input[:1], `:\`}, context.temp_allocator)
	}
	wpath := win.utf8_to_wstring(path, context.temp_allocator)

	attrs := win.GetFileAttributesW(wpath)
	if attrs == win.INVALID_FILE_ATTRIBUTES {
		target_destroy(&t)
		return {}, .Target_Not_Found
	}

	// A file that is not a directory is taken to be an image of a volume. Nothing
	// here can say which filesystem is inside it, so a backend has to look.
	if attrs & win.FILE_ATTRIBUTE_DIRECTORY == 0 {
		t.image = true
		t.volume = strings.clone(path, allocator)
		return t, .None
	}

	// The mount point tells us which volume the path sits on, which is the only way
	// to be right about a directory mounted from another volume.
	mount_buf: [win.MAX_PATH]u16
	if !GetVolumePathNameW(wpath, &mount_buf[0], len(mount_buf)) {
		target_destroy(&t)
		return {}, .Target_Not_Found
	}
	mount, mount_err := win.wstring_to_utf8(win.wstring(&mount_buf[0]), -1, allocator)
	if mount_err != nil {
		target_destroy(&t)
		return {}, .Out_Of_Memory
	}
	t.mount = mount

	fs_buf: [win.MAX_PATH]u16
	if GetVolumeInformationW(
		win.wstring(&mount_buf[0]),
		nil,
		0,
		nil,
		nil,
		nil,
		&fs_buf[0],
		len(fs_buf),
	) {
		name, name_err := win.wstring_to_utf8(win.wstring(&fs_buf[0]), -1, context.temp_allocator)
		if name_err == nil {
			t.fs = filesystem_from_name(name)
		}
	}

	// A mount point of the form `C:\` opens as `\\.\C:`; anything else is a volume
	// mounted into a directory, which needs its own device path and is left alone.
	if len(t.mount) >= 2 && t.mount[1] == ':' {
		t.volume = strings.concatenate({`\\.\`, t.mount[:1], ":"}, allocator)
	}
	if strings.has_prefix(t.mount, `\\`) {
		t.fs = .Network
	}

	// Whatever of the path lies below the mount point is the subtree to report on.
	if len(path) > len(t.mount) {
		t.root = strings.clone(path[len(t.mount) - 1:], allocator)
	}
	return t, .None
}

@(private)
filesystem_from_name :: proc(name: string) -> Filesystem {
	switch name {
	case "NTFS":
		return .Ntfs
	case "ReFS":
		return .Refs
	case "exFAT":
		return .Exfat
	case "FAT32", "FAT":
		return .Fat32
	}
	return .Unknown
}

// `C`, `C:` and `C:\` all mean the same volume.
@(private)
is_drive_spec :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 3 {
		return false
	}
	c := s[0]
	if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
		return false
	}
	if len(s) >= 2 && s[1] != ':' {
		return false
	}
	if len(s) == 3 && s[2] != '\\' && s[2] != '/' {
		return false
	}
	return true
}

/*
Whether this process can open a raw volume handle.

Asked before choosing a reader so the choice can be explained: the MFT reader is much
faster but needs this, and without it the caller may want to relaunch rather than
settle for walking directories.
*/
elevated :: proc() -> bool {
	token: win.HANDLE
	if !win.OpenProcessToken(GetCurrentProcess(), win.TOKEN_QUERY, &token) {
		return false
	}
	defer win.CloseHandle(token)

	// TOKEN_ELEVATION is a single DWORD: non-zero when the token is elevated.
	value: win.DWORD
	size: win.DWORD
	if !win.GetTokenInformation(token, .TokenElevation, &value, size_of(value), &size) {
		return false
	}
	return value != 0
}
