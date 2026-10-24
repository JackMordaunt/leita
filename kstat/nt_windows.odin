#+build windows
package kstat

import win "core:sys/windows"

// What the walk and the window's file actions both need of Windows' own file API
// that core:sys/windows does not name.

// The reparse-tag bit that marks a tag whose reparse point names another file: a
// symbolic link, a junction, a volume mounted in a folder ("Reparse Point Tags",
// Microsoft's file system documentation).
IO_REPARSE_TAG_NAME_SURROGATE :: 0x20000000

// NtCreateFile's CreateOptions, from <winternl.h>.
FILE_DIRECTORY_FILE :: 0x00000001
FILE_SYNCHRONOUS_IO_NONALERT :: 0x00000020
FILE_OPEN_REPARSE_POINT :: 0x00200000

// FILE_FULL_DIR_INFO from <winbase.h>. Its name starts at byte 68, before the
// padding that rounds the struct up to its alignment.
File_Full_Dir_Info :: struct {
	next_entry_offset: u32,
	file_index:        u32,
	creation_time:     i64,
	last_access_time:  i64,
	last_write_time:   i64,
	change_time:       i64,
	end_of_file:       i64,
	allocation_size:   i64,
	file_attributes:   u32,
	file_name_length:  u32,
	ea_size:           u32,
}

FULL_DIR_NAME_OFFSET :: 68
#assert(offset_of(File_Full_Dir_Info, ea_size) + size_of(u32) == FULL_DIR_NAME_OFFSET)

// is_dot is whether a listed name is . or .., which name a directory itself.
is_dot :: proc(name: []u16) -> bool {
	switch len(name) {
	case 1:
		return name[0] == '.'
	case 2:
		return name[0] == '.' && name[1] == '.'
	}
	return false
}

foreign import ntdll "system:ntdll.lib"

// Not in core:sys/windows. Unlike SetFileInformationByHandle, it honours the root
// directory a FILE_RENAME_INFORMATION names.
@(default_calling_convention = "system")
foreign ntdll {
	NtSetInformationFile :: proc(FileHandle: win.HANDLE, IoStatusBlock: ^win.IO_STATUS_BLOCK, FileInformation: rawptr, Length: u32, FileInformationClass: win.FILE_INFORMATION_CLASS) -> win.NTSTATUS ---
}
