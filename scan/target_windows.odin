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
}

/*
Resolve what was given into a target backends can dispatch on.

A bare drive letter is accepted for convenience, an existing path is asked about, and
anything else is taken to be an image file holding a volume. Failing here is better
than failing inside a backend, because this is the layer that knows why.

The reader comes back with the target. Choosing one needs to know whether the volume
opens, which is found out here, so leaving the caller to ask separately would only
mean opening it twice.

made_up, a day, resolves to the made-up disk of that day in place of input: the
caller passes what synthetic_day read at its startup, nothing to scan what is real.
*/
resolve :: proc(
	input: string,
	allocator := context.allocator,
	made_up: Maybe(int) = nil,
) -> (
	t: Target,
	c: Choice,
	err: Error,
) {
	if made, choice, ok := synthetic(input, made_up, allocator); ok {
		return made, choice, .None
	}
	t.allocator = allocator
	t.input = strings.clone(input, allocator)

	// The tree joins what it finds with `\`, and a path shown with both,
	// C:\Users\me/photos\a.jpg, splits wrongly into the location bar's steps: so
	// a slash typed or passed in is `\` from here on.
	path, _ := strings.replace_all(input, "/", `\`, context.temp_allocator)
	if is_drive_spec(path) {
		path = strings.concatenate({path[:1], `:\`}, context.temp_allocator)
	}
	// Expand 8.3 components so the target is stored under its long name.
	path = long_name(path)
	wpath := win.utf8_to_wstring(path, context.temp_allocator)

	attrs := win.GetFileAttributesW(wpath)
	if attrs == win.INVALID_FILE_ATTRIBUTES {
		target_destroy(&t)
		return {}, {}, .Target_Not_Found
	}

	// A file that is not a directory is taken to be an image of a volume. Nothing
	// here can say which filesystem is inside it, so a backend has to look.
	if attrs & win.FILE_ATTRIBUTE_DIRECTORY == 0 {
		t.image = true
		t.volume = strings.clone(path, allocator)
		return t, choose(t, can_open(t.volume)), .None
	}

	// The mount point tells us which volume the path sits on, which is the only way
	// to be right about a directory mounted from another volume.
	mount_buf: [win.MAX_PATH]u16
	if !GetVolumePathNameW(wpath, &mount_buf[0], len(mount_buf)) {
		target_destroy(&t)
		return {}, {}, .Target_Not_Found
	}
	// Converted in the temp allocator and cloned: given -1, wstring_to_utf8_alloc
	// (core/sys/windows/util.odin) allocates room for the NUL and slices it off the
	// string, so target_destroy would free C:\ as 3 bytes of a 4-byte block, which
	// the debug allocator caught on a Windows runner.
	mount, mount_err := win.wstring_to_utf8(win.wstring(&mount_buf[0]), -1, context.temp_allocator)
	if mount_err != nil {
		target_destroy(&t)
		return {}, {}, .Out_Of_Memory
	}
	t.mount = strings.clone(mount, allocator)

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
		if t.fs == .Ntfs {
			t.record = file_record(wpath)
		}
	}
	// The mount point answered everything above; nothing has touched the volume
	// itself. Whether that opens is what decides the reader.
	return t, choose(t, can_open(t.volume)), .None
}

// long_name is path with 8.3 components expanded, or path when GetLongPathNameW
// yields nothing.
@(private)
long_name :: proc(path: string) -> string {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	buf: [win.MAX_PATH]u16
	n := win.GetLongPathNameW(wpath, win.wstring(&buf[0]), len(buf))
	if n == 0 {
		return path
	}
	wide: win.wstring
	if int(n) < len(buf) {
		wide = win.wstring(&buf[0])
	} else {
		owned := make([]u16, int(n), context.temp_allocator)
		n = win.GetLongPathNameW(wpath, win.wstring(raw_data(owned)), n)
		if n == 0 {
			return path
		}
		wide = win.wstring(raw_data(owned))
	}
	long, err := win.wstring_to_utf8(wide, int(n), context.temp_allocator)
	return long if err == nil else path
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
root's file reference number, the MFT's own index for it, read straight off a normal
handle. Unlike the raw volume handle can_open tests, this needs no elevation: it is
the same permission that already let resolve list the directory.
*/
@(private)
file_record :: proc(wpath: win.LPCWSTR) -> Maybe(u32) {
	h := win.CreateFileW(
		wpath,
		win.FILE_READ_ATTRIBUTES,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		return nil
	}
	defer win.CloseHandle(h)
	info: win.BY_HANDLE_FILE_INFORMATION
	if !win.GetFileInformationByHandle(h, &info) {
		return nil
	}
	// The low 48 bits of the file reference number are the record; the high 16 are a
	// sequence number that detects reuse, which a caller that just wants the record
	// has no use for.
	ref := u64(info.nFileIndexHigh) << 32 | u64(info.nFileIndexLow)
	return u32(ref & 0x0000_ffff_ffff_ffff)
}

/*
Whether a volume opens for raw reading.

Elevation is the usual reason a raw handle is refused, but an elevated token still
says nothing about a volume that is missing, or locked by something else. Opening it
answers all of those at once and costs one handle.

FILE_SHARE_WRITE is required: the volume is mounted and in use, so asking to exclude
writers would fail for a reason that has nothing to do with permission.
*/
@(private)
can_open :: proc(path: string) -> bool {
	if path == "" {
		return false
	}
	h := win.CreateFileW(
		win.utf8_to_wstring(path, context.temp_allocator),
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		0,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		return false
	}
	win.CloseHandle(h)
	return true
}
