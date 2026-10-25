#+build windows
package leita_files

import "base:runtime"

import "core:path/filepath"
import "core:strings"
import win32 "core:sys/windows"
import "core:unicode/utf16"

import "../../kstat"

/*
remove_tree deletes the directory at path and everything in it, through handles:
the folder holding it is opened one component at a time without passing through a
link (open_directory), and every directory below is opened relative to the one
holding it, with FILE_OPEN_REPARSE_POINT, so a name swapped for a symbolic link or
a junction while the delete runs is the link itself, never what it names. A link
or junction inside the tree, a volume mounted in a folder among them (its reparse
tag is a junction's, "Reparse Point Tags" in Microsoft's file system
documentation), is deleted as itself. A directory that was listed as one and is a
link by the time it is opened is counted as left.

It counts what it leaves as delete_tree does, and gives back the length of each
regular file it deleted: the listing carries no allocated size it could trust for
a file with another name. A read-only entry has the attribute cleared through its
own handle before it is deleted; a directory that stays has it back.
*/
@(private)
remove_tree :: proc(
	path: string,
	allocator := context.temp_allocator,
) -> (
	failed: int,
	freed: u64,
	err: Error,
) {
	dir, name := filepath.split(path)
	buf: [256]u16
	wide, fits := wide_name(name, &buf)
	if name == "" || name == "." || name == ".." || !fits {
		return 0, 0, .Not_Directory
	}

	parent, perr := open_directory(dir, allocator)
	if perr != .None {
		return 0, 0, perr
	}
	defer win32.CloseHandle(parent)

	h, status := open_at(parent, wide, DIRECTORY_ACCESS, kstat.FILE_DIRECTORY_FILE)
	if status < 0 {
		return 0, 0, status_error(status)
	}
	if tag, ok := tag_of(h); !ok || is_surrogate(tag) {
		// A link put in its place since delete_tree asked.
		win32.CloseHandle(h)
		return 0, 0, .Not_Directory
	}
	failed, freed = remove_dir(h, allocator)
	return failed, freed, .None
}

/*
remove_dir deletes everything in the directory open as dir, then the directory
itself, and closes dir. Every entry is opened relative to dir with
FILE_OPEN_REPARSE_POINT.
*/
@(private = "file")
remove_dir :: proc(dir: win32.HANDLE, allocator: runtime.Allocator) -> (failed: int, freed: u64) {
	defer win32.CloseHandle(dir)

	attributes, cleared := clear_read_only(dir)
	defer if cleared && failed > 0 {
		set_attributes(dir, attributes)
	}

	entries, listed := list_handle(dir, allocator)
	defer {
		for e in entries {
			delete(e.name, allocator)
		}
		delete(entries, allocator)
	}

	if !listed {
		return 1, 0
	}
	for e in entries {
		directory := e.attributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0
		linked := e.attributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 && is_surrogate(e.tag)
		if directory && !linked {
			if before_enter != nil {
				text: [1024]u8
				before_enter(string(text[:utf16.decode_to_utf8(text[:], e.name)]))
			}
			sub, status := open_at(dir, e.name, DIRECTORY_ACCESS, kstat.FILE_DIRECTORY_FILE)
			switch {
			case status == STATUS_OBJECT_NAME_NOT_FOUND:
				continue
			case status < 0:
				failed += 1
				continue
			}
			if tag, ok := tag_of(sub); !ok || is_surrogate(tag) {
				// Dir_Entry as a directory and a link now: the tree changed under the
				// delete, and the link's target is not this tree's.
				win32.CloseHandle(sub)
				failed += 1
				continue
			}
			f, gave := remove_dir(sub, allocator)
			failed, freed = failed + f, freed + gave
			continue
		}
		err := delete_entry(dir, e.name)
		switch {
		case err == .None:
			if !directory && !linked {
				freed += u64(max(e.length, 0))
			}
		case err != .Missing:
			failed += 1
		}
	}
	if failed > 0 {
		// Kept because it holds what is counted already.
		return
	}
	if !mark_deleted(dir) {
		failed = 1
	}
	return
}

// delete_entry deletes the entry name in dir as itself: a file, or a link or
// junction without what it names.
@(private = "file")
delete_entry :: proc(dir: win32.HANDLE, name: []u16) -> Error {
	h, status := open_at(dir, name, ENTRY_ACCESS, 0)
	if status < 0 {
		return status_error(status)
	}
	defer win32.CloseHandle(h)

	attributes, cleared := clear_read_only(h)
	if !mark_deleted(h) {
		if cleared {
			set_attributes(h, attributes)
		}
		return .Other
	}
	return .None
}

/*
open_directory opens the directory at path one component at a time, each relative
to the one before, from the root of the volume it names. A component that is a
symbolic link or a junction, a volume mounted in a folder included, is
Not_Directory: none is passed through. Other reparse points, such as a cloud
file's placeholder, are opened as they would be without the check, once the
handle is shown to be the same directory. ".." is refused. The caller closes the
handle.

Given hold, every folder above the one returned is kept open in it, the volume's
root included, and each is opened without FILE_SHARE_DELETE, as the one returned
is: while the handles are open, none of those folders can be renamed or deleted, so
none can be swapped for a link, and the path names what was checked. The caller
closes those too.
*/
@(private)
open_directory :: proc(
	path: string,
	allocator := context.temp_allocator,
	hold: ^[dynamic]win32.HANDLE = nil,
) -> (
	h: win32.HANDLE,
	err: Error,
) {
	full := absolute(path, allocator)
	defer if raw_data(full) != raw_data(path) {
		delete(full, allocator)
	}

	root, rest, split := split_volume(full, allocator)
	defer delete(root, allocator)
	if !split {
		return nil, .Other
	}
	wide_root := win32.utf8_to_wstring(root, allocator)
	defer free(rawptr(wide_root), allocator)

	share: u32 = SHARE_ALL if hold == nil else win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE
	h = win32.CreateFileW(
		wide_root,
		LOOKUP_ACCESS,
		share,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if h == win32.INVALID_HANDLE_VALUE {
		return nil, win32_error(win32.GetLastError())
	}
	for part in strings.split_multi_iterate(&rest, {`\`, "/"}) {
		if part == "" || part == "." {
			continue
		}
		if part == ".." {
			win32.CloseHandle(h)
			return nil, .Not_Directory
		}
		buf: [256]u16
		name, fits := wide_name(part, &buf)
		if !fits {
			win32.CloseHandle(h)
			return nil, .Bad_Name
		}
		next, status := open_at(h, name, LOOKUP_ACCESS, kstat.FILE_DIRECTORY_FILE, share = share)
		if status < 0 {
			win32.CloseHandle(h)
			return nil, status_error(status)
		}
		tag, ok := tag_of(next)
		switch {
		case !ok || is_surrogate(tag):
			win32.CloseHandle(next)
			win32.CloseHandle(h)
			return nil, .Not_Directory
		case tag != 0:
			// Reopened through the reparse point's own handler, and kept only if it
			// is still the directory just opened as itself.
			seen := file_id(next)
			win32.CloseHandle(next)
			reopened, rstatus := open_at(h, name, LOOKUP_ACCESS, kstat.FILE_DIRECTORY_FILE, follow = true, share = share)
			if rstatus < 0 {
				win32.CloseHandle(h)
				return nil, status_error(rstatus)
			}
			if again := file_id(reopened); seen == {} || again != seen {
				win32.CloseHandle(reopened)
				win32.CloseHandle(h)
				return nil, .Not_Directory
			}
			next = reopened
		}
		if hold != nil {
			append(hold, h)
		} else {
			win32.CloseHandle(h)
		}
		h = next
	}
	return h, .None
}

// absolute is path made absolute against the working directory, owned; path itself
// when it cannot be.
@(private = "file")
absolute :: proc(path: string, allocator: runtime.Allocator) -> string {
	wide := win32.utf8_to_wstring(path, allocator)
	defer free(rawptr(wide), allocator)

	n := win32.GetFullPathNameW(wide, 0, nil, nil)
	if n == 0 {
		return path
	}
	buf := make([]u16, n, allocator)
	defer delete(buf, allocator)

	n = win32.GetFullPathNameW(wide, n, cstring16(raw_data(buf)), nil)
	if n == 0 || int(n) >= len(buf) {
		return path
	}
	out, err := win32.utf16_to_utf8(buf[:n], allocator)
	return out if err == nil else path
}

// wide_name is name as UTF-16 in buf. Not ok when it does not fit: no name this
// package opens is longer than 255 units.
@(private)
wide_name :: proc(name: string, buf: ^[256]u16) -> (wide: []u16, ok: bool) {
	n := utf16.encode_string(buf[:], name)
	return buf[:n], n < len(buf)
}

/*
split_volume is an absolute path's volume root, as a path CreateFileW opens, and
the rest of it below that root: C:\a\b is \\?\C:\ and a\b; \\server\share\a is
\\?\UNC\server\share\ and a. The \\?\ forms are taken as they are. root is owned.
*/
@(private = "file")
split_volume :: proc(path: string, allocator: runtime.Allocator) -> (root, rest: string, ok: bool) {
	// A path from the shell or the tree is joined with \, and core:os joins with
	// either, so / is a separator as \ is; rest is cut from path itself.
	p := path
	unc := false
	switch {
	case has_prefix_either(p, `\\?\UNC\`):
		p, unc = p[len(`\\?\UNC\`):], true
	case has_prefix_either(p, `\\?\`), has_prefix_either(p, `\\.\`):
		p = p[len(`\\?\`):]
	case has_prefix_either(p, `\\`):
		p, unc = p[2:], true
	}
	if !unc && len(p) >= 2 && p[1] == ':' {
		if len(p) > 2 && !is_separator(p[2]) {
			return "", "", false
		}
		rest = p[3:] if len(p) > 3 else ""
		return strings.concatenate({`\\?\`, p[:2], `\`}, allocator), rest, true
	}
	// A share's root is its server and share; a volume's own name is one component.
	parts := 2 if unc else 1
	at := 0
	for i in 0 ..< parts {
		next := strings.index_any(p[at:], SEPARATORS)
		if next < 0 {
			if i < parts - 1 || at == len(p) {
				return "", "", false
			}
			at = len(p)
			break
		}
		at += next + 1
	}

	head := strings.trim_right(p[:at], SEPARATORS)
	if head == "" {
		return "", "", false
	}
	prefix := `\\?\UNC\` if unc else `\\?\`
	rest = p[at:] if at < len(p) else ""
	return strings.concatenate({prefix, head, `\`}, allocator), rest, true
}

@(private = "file")
is_separator :: proc(c: u8) -> bool {
	return c == '\\' || c == '/'
}

// has_prefix_either is strings.has_prefix with / standing for \ in path.
@(private = "file")
has_prefix_either :: proc(path, prefix: string) -> bool {
	if len(path) < len(prefix) {
		return false
	}
	for c, i in transmute([]u8)prefix {
		if path[i] != c && !(c == '\\' && path[i] == '/') {
			return false
		}
	}
	return true
}

@(private = "file")
LOOKUP_ACCESS :: win32.FILE_TRAVERSE | win32.FILE_READ_ATTRIBUTES | win32.SYNCHRONIZE
@(private = "file")
DIRECTORY_ACCESS ::
	win32.DELETE |
	win32.FILE_LIST_DIRECTORY |
	win32.FILE_READ_ATTRIBUTES |
	win32.FILE_WRITE_ATTRIBUTES |
	win32.SYNCHRONIZE
@(private = "file")
ENTRY_ACCESS :: win32.DELETE | win32.FILE_READ_ATTRIBUTES | win32.FILE_WRITE_ATTRIBUTES | win32.SYNCHRONIZE

// SHARE_ALL lets others read, write, rename and delete what is open.
@(private = "file")
SHARE_ALL :: win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE

/*
open_at opens the entry name of dir by that name alone, so nothing above dir is
looked up again. Unless follow is set, a reparse point is opened as itself.
*/
@(private)
open_at :: proc(
	dir: win32.HANDLE,
	name: []u16,
	access: u32,
	options: u32,
	follow := false,
	share: u32 = SHARE_ALL,
) -> (
	h: win32.HANDLE,
	status: win32.NTSTATUS,
) {
	n := u16(len(name) * size_of(u16))
	us := win32.UNICODE_STRING {
		Length        = n,
		MaximumLength = n,
		Buffer        = raw_data(name),
	}
	oa := win32.OBJECT_ATTRIBUTES {
		Length        = size_of(win32.OBJECT_ATTRIBUTES),
		RootDirectory = dir,
		ObjectName    = &us,
	}
	iosb: win32.IO_STATUS_BLOCK
	flags := options | kstat.FILE_SYNCHRONOUS_IO_NONALERT
	if !follow {
		flags |= kstat.FILE_OPEN_REPARSE_POINT
	}
	status = win32.NtCreateFile(
		&h,
		access,
		&oa,
		&iosb,
		nil,
		0,
		share,
		win32.FILE_OPEN,
		flags,
		nil,
		0,
	)
	return
}

// tag_of is the reparse tag of what h is open on, 0 when it is no reparse point.
@(private = "file")
tag_of :: proc(h: win32.HANDLE) -> (tag: u32, ok: bool) {
	info: win32.FILE_ATTRIBUTE_TAG_INFO
	if !win32.GetFileInformationByHandleEx(h, .FileAttributeTagInfo, &info, size_of(info)) {
		return 0, false
	}
	if info.FileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT == 0 {
		return 0, true
	}
	return info.ReparseTag, true
}

// is_surrogate is whether a reparse tag names another file: a symbolic link, a
// junction or a volume mounted in a folder (the tag's name-surrogate bit).
@(private = "file")
is_surrogate :: proc(tag: u32) -> bool {
	return tag & kstat.IO_REPARSE_TAG_NAME_SURROGATE != 0
}

// file_id is the volume and id of what h is open on; zero when it cannot be had.
@(private = "file")
file_id :: proc(h: win32.HANDLE) -> win32.FILE_ID_INFO {
	info: win32.FILE_ID_INFO
	if !win32.GetFileInformationByHandleEx(h, .FileIdInfo, &info, size_of(info)) {
		return {}
	}
	return info
}

// clear_read_only clears the read-only attribute of what h is open on, saying the
// attributes it had and whether it changed them.
@(private = "file")
clear_read_only :: proc(h: win32.HANDLE) -> (attributes: u32, cleared: bool) {
	info: win32.FILE_BASIC_INFO
	if !win32.GetFileInformationByHandleEx(h, .FileBasicInfo, &info, size_of(info)) {
		return 0, false
	}
	attributes = info.FileAttributes
	if attributes & win32.FILE_ATTRIBUTE_READONLY == 0 {
		return attributes, false
	}
	return attributes, set_attributes(h, attributes &~ win32.FILE_ATTRIBUTE_READONLY)
}

// set_attributes gives what h is open on the attributes given, leaving its times.
@(private = "file")
set_attributes :: proc(h: win32.HANDLE, attributes: u32) -> bool {
	info := win32.FILE_BASIC_INFO {
		// FILE_ATTRIBUTE_NORMAL stands for none; 0 would mean "leave them" (FILE_BASIC_INFO,
		// Microsoft Learn).
		FileAttributes = attributes if attributes != 0 else win32.FILE_ATTRIBUTE_NORMAL,
	}
	return bool(win32.SetFileInformationByHandle(h, .FileBasicInfo, &info, size_of(info)))
}

// mark_deleted has what h is open on deleted once the last handle on it closes.
@(private = "file")
mark_deleted :: proc(h: win32.HANDLE) -> bool {
	info := File_Disposition_Info {
		delete_file = true,
	}
	return bool(win32.SetFileInformationByHandle(h, .FileDispositionInfo, &info, size_of(info)))
}

@(private = "file")
Dir_Entry :: struct {
	name:       []u16,
	attributes: u32,
	tag:        u32,
	length:     i64,
}

// list_handle is every entry of the directory open as dir but . and .., read whole
// before any is deleted. The names are copied out of the listing's buffer.
@(private = "file")
list_handle :: proc(dir: win32.HANDLE, allocator: runtime.Allocator) -> (entries: []Dir_Entry, ok: bool) {
	out := make([dynamic]Dir_Entry, allocator)
	buf: [32 * 1024 / size_of(u64)]u64
	class := win32.FILE_INFO_BY_HANDLE_CLASS.FileFullDirectoryRestartInfo
	for {
		if !win32.GetFileInformationByHandleEx(dir, class, &buf, size_of(buf)) {
			if win32.GetLastError() == win32.ERROR_NO_MORE_FILES {
				break
			}

			for e in out {
				delete(e.name, allocator)
			}
			delete(out)
			return nil, false
		}
		class = .FileFullDirectoryInfo
		at := 0
		for {
			raw := ([^]u8)(&buf)[at:]
			info := (^kstat.File_Full_Dir_Info)(raw)
			name := ([^]u16)(raw[kstat.FULL_DIR_NAME_OFFSET:])[:info.file_name_length / 2]
			if !kstat.is_dot(name) {
				own := make([]u16, len(name), allocator)
				copy(own, name)
				tag := info.ea_size if info.file_attributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 else 0
				append(
					&out,
					Dir_Entry {
						name = own,
						attributes = info.file_attributes,
						tag = tag,
						length = info.end_of_file,
					},
				)
			}
			if info.next_entry_offset == 0 {
				break
			}
			at += int(info.next_entry_offset)
		}
	}
	return out[:], true
}

/*
status_error is what an NTSTATUS comes to, through the system error it maps to.
ERROR_DIRECTORY is a name that is not a directory where one was asked for.
*/
@(private)
status_error :: proc(status: win32.NTSTATUS) -> Error {
	code := win32.RtlNtStatusToDosError(status)
	if code == ERROR_DIRECTORY {
		return .Not_Directory
	}
	return win32_error(win32.DWORD(code))
}

@(private = "file")
ERROR_DIRECTORY :: 267
@(private = "file")
STATUS_OBJECT_NAME_NOT_FOUND :: win32.NTSTATUS(-1073741772) // 0xC0000034

// FILE_DISPOSITION_INFO from <winbase.h>.
@(private = "file")
File_Disposition_Info :: struct {
	delete_file: win32.BOOLEAN,
}
