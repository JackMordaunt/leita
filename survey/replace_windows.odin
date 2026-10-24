#+build windows
package survey

import "core:os"
import win "core:sys/windows"

import "../faults"

/*
Rename `from` over `to`, whatever else has `to` open. MoveFileExW, which os.rename
calls, refuses to replace a file another handle holds, and the handle it renames
through stays open on the new name for a moment after: of two savers finishing
together, the second's rename failed on the first's handle (one save in 100 lost on
windows-latest, 2026-10-15). POSIX semantics replace the file as Linux and macOS do,
any handle still on it keeping the old one. A volume or a Windows without them, FAT
or before 10 1809, gets os.rename.
*/
@(private)
replace :: proc(from, to: string) -> bool {
	if faults.check(.Rename, from) != .None {
		return false
	}
	ok, tried := replace_posix(from, to)
	if !tried {
		return os.rename(from, to) == nil
	}
	return ok
}

// Not tried when `from` cannot be opened to rename, or the volume has no POSIX
// semantics; os.rename then takes it, with its own long-path handling.
@(private = "file")
replace_posix :: proc(from, to: string) -> (ok, tried: bool) {
	wide_from := win.utf8_to_wstring(from, context.temp_allocator)
	name := win.utf8_to_utf16(to, context.temp_allocator)
	if wide_from == nil || name == nil {
		return false, false
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
		return false, false
	}
	defer win.CloseHandle(f)

	// The name runs on past the struct's one character; zeroed, it ends in a nul.
	size := size_of(Rename_Info) + len(name) * size_of(u16)
	buf := make([]u64, (size + 7) / 8, context.temp_allocator)
	info := (^Rename_Info)(raw_data(buf))
	info.flags = FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS
	info.name_length = u32(len(name) * size_of(u16))
	copy(([^]u16)(&info.name)[:len(name)], name)
	if win.SetFileInformationByHandle(f, FileRenameInfoEx, info, u32(size)) {
		return true, true
	}
	err := win.GetLastError()
	unsupported := err == win.ERROR_INVALID_PARAMETER || err == win.ERROR_NOT_SUPPORTED
	return false, !unsupported
}

// FILE_RENAME_INFO as FileRenameInfoEx reads it, its union taken as the flags.
@(private = "file")
Rename_Info :: struct {
	flags:       u32,
	root:        win.HANDLE,
	name_length: u32,
	name:        [1]u16,
}

@(private = "file")
FileRenameInfoEx :: win.FILE_INFO_BY_HANDLE_CLASS(22)
@(private = "file")
FILE_RENAME_FLAG_REPLACE_IF_EXISTS :: 0x1
@(private = "file")
FILE_RENAME_FLAG_POSIX_SEMANTICS :: 0x2
