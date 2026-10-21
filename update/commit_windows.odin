#+build windows
package update

import "core:fmt"
import "core:mem"
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

// Multiple of 4, so the descriptor buffer is DWORD-aligned.
@(private)
SECURITY_DESCRIPTOR_ALIGN :: 8
@(private)
SECURITY_DESCRIPTOR_MAX :: 1 << 20
@(private)
SECURITY_READ_ATTEMPTS :: 4

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
	buf, why := read_dacl(wide_exe, allocator)
	if why != "" {
		return false, why
	}
	wrote := SetFileSecurityW(
		wide_fresh,
		DACL_SECURITY_INFORMATION,
		win.PSECURITY_DESCRIPTOR(raw_data(buf)),
	)
	if !wrote {
		err := win.GetLastError()
		return false, fmt.tprintf("SetFileSecurityW error %d", err)
	}
	return true, ""
}

// read_dacl loads the DACL into aligned storage. It starts at 256 bytes and
// grows to the reported size, up to 1 MiB, for at most four tries. A nil
// descriptor is not passed. Any error other than a short buffer fails closed.
@(private)
read_dacl :: proc(wide: win.wstring, allocator := context.temp_allocator) -> (buf: []byte, note: string) {
	size := 256
	for attempt in 0 ..< SECURITY_READ_ATTEMPTS {
		block, aerr := mem.alloc_bytes(size, SECURITY_DESCRIPTOR_ALIGN, allocator)
		if aerr != .None || len(block) < size {
			return nil, fmt.tprintf("security buffer alloc error %v", aerr)
		}
		needed: win.DWORD
		read := win.GetFileSecurityW(
			wide,
			DACL_SECURITY_INFORMATION,
			win.PSECURITY_DESCRIPTOR(raw_data(block)),
			win.DWORD(size),
			&needed,
		)
		err := win.GetLastError()
		if read {
			return block, ""
		}
		grow :=
			err == win.ERROR_INSUFFICIENT_BUFFER &&
			int(needed) > size &&
			int(needed) <= SECURITY_DESCRIPTOR_MAX
		if grow && attempt + 1 < SECURITY_READ_ATTEMPTS {
			size = int(needed)
			continue
		}
		return nil, fmt.tprintf("GetFileSecurityW(read) error %d needed %d size %d", err, needed, size)
	}
	return nil, "GetFileSecurityW(read) stopped"
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
