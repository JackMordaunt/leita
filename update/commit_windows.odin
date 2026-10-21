#+build windows
package update

import "core:fmt"
import "core:os"
import win "core:sys/windows"

foreign import advapi32 "system:Advapi32.lib"

@(default_calling_convention = "system")
foreign advapi32 {
	SetFileSecurityW :: proc(
		lpFileName: win.LPCWSTR,
		SecurityInformation: win.SECURITY_INFORMATION,
		pSecurityDescriptor: win.PSECURITY_DESCRIPTOR,
	) -> win.BOOL ---
}

@(private)
DACL_SECURITY_INFORMATION :: win.SECURITY_INFORMATION(0x4)

// Attributes SetFileAttributes accepts. The rest are owned by the filesystem.
@(private)
SETTABLE_ATTRIBUTES :: win.DWORD(
	0x00000001 | 0x00000002 | 0x00000004 | 0x00000020 | 0x00000080 | 0x00000100 | 0x00002000,
)

// os.change_mode on Windows passes the wrong structure size to
// SetFileInformationByHandle. Copy the attributes and the DACL with the
// sizes those calls expect. Owner is left: copying it often needs a privilege
// this process does not have. A failure aborts before the replace.
// note names the API and GetLastError, captured before any formatting.
preserve_permissions :: proc(exe, fresh: string, allocator := context.temp_allocator) -> (ok: bool, note: string) {
	wide_exe := win.utf8_to_wstring(exe, allocator)
	wide_fresh := win.utf8_to_wstring(fresh, allocator)
	if wide_exe == nil || wide_fresh == nil {
		return false, "utf8_to_wstring failed"
	}
	attr := win.GetFileAttributesW(wide_exe)
	if attr == win.INVALID_FILE_ATTRIBUTES {
		err := win.GetLastError()
		return false, fmt.tprintf("GetFileAttributesW error %d", err)
	}
	attr = attr & SETTABLE_ATTRIBUTES
	if attr == 0 {
		attr = win.FILE_ATTRIBUTE_NORMAL
	}
	set_attr := win.SetFileAttributesW(wide_fresh, attr)
	if !set_attr {
		err := win.GetLastError()
		return false, fmt.tprintf("SetFileAttributesW error %d", err)
	}
	needed: win.DWORD
	sized := win.GetFileSecurityW(wide_exe, DACL_SECURITY_INFORMATION, nil, 0, &needed)
	err := win.GetLastError()
	if needed == 0 || needed > 1_048_576 || (!sized && err != win.ERROR_INSUFFICIENT_BUFFER) {
		return false, fmt.tprintf("GetFileSecurityW error %d needed %d", err, needed)
	}
	buf := make([]byte, needed, allocator)
	read := win.GetFileSecurityW(
		wide_exe,
		DACL_SECURITY_INFORMATION,
		win.PSECURITY_DESCRIPTOR(raw_data(buf)),
		needed,
		&needed,
	)
	if !read {
		err = win.GetLastError()
		return false, fmt.tprintf("GetFileSecurityW error %d needed %d", err, needed)
	}
	wrote := SetFileSecurityW(
		wide_fresh,
		DACL_SECURITY_INFORMATION,
		win.PSECURITY_DESCRIPTOR(raw_data(buf)),
	)
	if !wrote {
		err = win.GetLastError()
		return false, fmt.tprintf("SetFileSecurityW error %d", err)
	}
	return true, ""
}

@(private)
FileRenameInfoEx :: win.FILE_INFO_BY_HANDLE_CLASS(22)
@(private)
FILE_RENAME_FLAG_REPLACE_IF_EXISTS :: 0x1
@(private)
FILE_RENAME_FLAG_POSIX_SEMANTICS :: 0x2

// FILE_RENAME_INFO as FileRenameInfoEx reads it. The union is the flags.
@(private)
Rename_Info :: struct {
	flags:       u32,
	root:        win.HANDLE,
	name_length: u32,
	name:        [1]u16,
}

// replace_atomically renames fresh over exe with POSIX semantics, so a handle
// still open on exe keeps the old bytes and the name is never absent.
// MoveFileExW, which os.rename calls, is not used: it is not atomic and it
// fails while the file is running. A volume without POSIX semantics is
// Unsupported and the file is left as it was.
replace_atomically :: proc(from, to: string, allocator := context.temp_allocator) -> (ok, unsupported: bool, note: string) {
	wide_from := win.utf8_to_wstring(from, allocator)
	name := win.utf8_to_utf16(to, allocator)
	if wide_from == nil || name == nil {
		return false, false, "0"
	}
	f := win.CreateFileW(
		wide_from,
		win.DELETE | win.SYNCHRONIZE,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		0,
		nil,
	)
	if f == win.INVALID_HANDLE_VALUE {
		return false, false, fmt.tprintf("%d", win.GetLastError())
	}
	defer win.CloseHandle(f)

	size := size_of(Rename_Info) + len(name) * size_of(u16)
	buf := make([]u64, (size + 7) / 8, allocator)
	info := (^Rename_Info)(raw_data(buf))
	info.flags = FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS
	info.name_length = u32(len(name) * size_of(u16))
	copy(([^]u16)(&info.name)[:len(name)], name)
	if win.SetFileInformationByHandle(f, FileRenameInfoEx, info, u32(size)) {
		return true, false, ""
	}
	err := win.GetLastError()
	unsupported =
		err == win.ERROR_INVALID_PARAMETER ||
		err == win.ERROR_NOT_SUPPORTED ||
		err == win.ERROR_INVALID_FUNCTION ||
		err == win.ERROR_CALL_NOT_IMPLEMENTED
	if unsupported {
		return false, true, fmt.tprintf(
			"this Windows cannot replace a running program in place (%d); %s was not replaced. Download it from %s",
			err,
			to,
			RELEASE_PAGE,
		)
	}
	return false, false, fmt.tprintf("%d", err)
}

// sync_file pushes the backup's bytes out before its name is published.
sync_file :: proc(f: ^os.File) -> bool {
	if f == nil {
		return false
	}
	return bool(win.FlushFileBuffers(win.HANDLE(os.fd(f))))
}
