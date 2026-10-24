#+build windows
package leita_files

import "core:os"
import "core:path/filepath"
import "core:strings"
import win32 "core:sys/windows"

import "../../kstat"

SEPARATOR  :: `\`
SEPARATORS :: `\/`

/*
rename_noreplace renames from to to, failing with Exists rather than replacing
whatever is at to, and never copying between volumes. Each folder is opened
without passing through a symbolic link or a junction (open_directory), the entry
is opened as itself relative to its folder, and the rename names its new folder by
handle, so a link in either path is Not_Directory and a folder swapped for one
cannot redirect it.
*/
rename_noreplace :: proc(from, to: string) -> Error {
	from_dir, from_name := filepath.split(from)
	to_dir, to_name := filepath.split(to)
	from_buf, to_buf: [256]u16
	from_wide, from_fits := wide_name(from_name, &from_buf)
	to_wide, to_fits := wide_name(to_name, &to_buf)
	if !plain_name(from_name) || !plain_name(to_name) || !from_fits || !to_fits {
		return .Bad_Name
	}

	from_handle, ferr := open_directory(from_dir)
	if ferr != .None {
		return ferr
	}
	defer win32.CloseHandle(from_handle)

	to_handle, terr := open_directory(to_dir)
	if terr != .None {
		return terr
	}
	defer win32.CloseHandle(to_handle)

	access :: win32.DELETE | win32.FILE_READ_ATTRIBUTES | win32.SYNCHRONIZE
	entry, status := open_at(from_handle, from_wide, access, 0)
	if status < 0 {
		return status_error(status)
	}
	defer win32.CloseHandle(entry)

	// FILE_RENAME_INFO: the flags, the folder's handle, the name's length in bytes,
	// then the name, read up to that length.
	buf: [(RENAME_NAME_OFFSET + 256 * size_of(u16) + 7) / 8]u64
	info := (^File_Rename_Info)(&buf)
	info.root = to_handle
	info.length = u32(len(to_wide) * size_of(u16))
	copy(([^]u16)(&([^]u8)(&buf)[RENAME_NAME_OFFSET])[:len(to_wide)], to_wide)
	size := u32(RENAME_NAME_OFFSET + (len(to_wide) + 1) * size_of(u16))

	// NtSetInformationFile, since SetFileInformationByHandle resolves a bare name
	// against the working directory's volume rather than the root handle (seen as
	// ERROR_NOT_SAME_DEVICE on a runner whose temp directory is on another drive).
	iosb: win32.IO_STATUS_BLOCK
	status = kstat.NtSetInformationFile(entry, &iosb, info, size, .FileRenameInformation)
	if status < 0 {
		return status_error(status)
	}
	return .None
}

// FILE_RENAME_INFO from <winbase.h>, up to the name: flags 0 does not replace.
@(private = "file")
File_Rename_Info :: struct {
	flags:  u32,
	root:   win32.HANDLE,
	length: u32,
}

@(private = "file")
RENAME_NAME_OFFSET :: 20
#assert(offset_of(File_Rename_Info, length) + size_of(u32) == RENAME_NAME_OFFSET)

// plain_name is whether name names an entry in a folder, not the folder itself.
@(private = "file")
plain_name :: proc(name: string) -> bool {
	return name != "" && name != "." && name != ".." && !strings.contains_any(name, SEPARATORS)
}

/*
trash moves path to the Recycle Bin through the shell, as Explorer does, and
reports success only once path is gone. A routine recycle raises no prompt:
leita has asked in its own dialog, and FOF_NOCONFIRMATION keeps the shell from
asking again. FOF_WANTNUKEWARNING partly overrides that (Microsoft's SHFILEOPSTRUCT
documentation, fFlags), so a delete that would destroy rather than recycle still
warns and can be cancelled. FOF_NO_UI is not used because it would also swallow
that warning. A refusal, a failure or a path still in place is Not_Recycled.

The folder holding path is first opened without passing through a symbolic link or
a junction (open_directory), so a path reaching the entry through one is refused as
Not_Directory. The shell takes a path, not a handle, so a folder swapped for a link
after that check and before the recycle is not caught.
*/
trash :: proc(path: string) -> Error {
	if !present(path) {
		return .Missing
	}
	dir, name := filepath.split(path)
	if !plain_name(name) {
		return .Not_Directory
	}

	parent, perr := open_directory(dir)
	if perr != .None {
		return perr
	}
	win32.CloseHandle(parent)

	wide := win32.utf8_to_utf16(path, context.temp_allocator)
	from := make([]u16, len(wide) + 2, context.temp_allocator) // the list ends in two NULs
	copy(from, wide)
	op := win32.SHFILEOPSTRUCTW {
		wFunc  = win32.FO_DELETE,
		pFrom  = cstring16(raw_data(from)),
		fFlags = win32.FOF_ALLOWUNDO |
		win32.FOF_NOCONFIRMATION |
		win32.FOF_WANTNUKEWARNING |
		win32.FOF_SILENT |
		win32.FOF_NOERRORUI |
		win32.FOF_NOCONFIRMMKDIR,
	}
	code := win32.SHFileOperationW(&op)
	return trash_outcome(i32(code), bool(op.fAnyOperationsAborted), !present(path))
}

// present says whether anything, a link itself included, is at path.
@(private = "file")
present :: proc(path: string) -> bool {
	_, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	return err == nil
}

/*
is_link says whether path is a symbolic link or a junction. delete_tree refuses
one given as the tree, and Reclaim refuses to offer one (newest_modification).
core:os's lstat cannot be asked: it reads a link through a handle opened on the
link and then drops its reparse tag (core/os/stat_windows.odin), so it calls a
link to a directory a directory. FindFirstFileW's find data carries the tag. A
volume mounted in a folder carries the same tag as a junction, and is a link
here too, as delete_tree already treats it.
*/
is_link :: proc(path: string) -> bool {
	data: win32.WIN32_FIND_DATAW
	h := win32.FindFirstFileW(win32.utf8_to_wstring(path, context.temp_allocator), &data)
	if h == win32.INVALID_HANDLE_VALUE {
		return false
	}
	win32.FindClose(h)
	if data.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT == 0 {
		return false
	}
	tag := data.dwReserved0
	return tag == win32.IO_REPARSE_TAG_SYMLINK || tag == win32.IO_REPARSE_TAG_MOUNT_POINT
}

// reveal opens Explorer with path selected.
@(private)
reveal :: proc(path: string) {
	run({"explorer.exe", strings.concatenate({"/select,", path}, context.temp_allocator)})
}

@(private)
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

// documents is the user's Documents folder as the shell knows it, wherever it
// was moved to; "" when the shell cannot say.
@(private)
documents :: proc(allocator := context.allocator) -> string {
	wide: win32.LPWSTR
	id := win32.FOLDERID_Documents
	if win32.SHGetKnownFolderPath(&id, 0, nil, &wide) != 0 {
		return ""
	}
	defer win32.CoTaskMemFree(wide)
	path, err := win32.wstring_to_utf8(win32.wstring(wide), -1, allocator)
	return path if err == nil else ""
}
