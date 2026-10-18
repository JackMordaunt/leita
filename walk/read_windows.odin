#+build windows
package walk

import "core:mem"
import "core:strings"
import win "core:sys/windows"
import "core:unicode/utf16"

foreign import ntdll "system:ntdll.lib"

/*
Read one directory with the calls the work actually needs.

The reader this replaces went through core:os, whose File_Info carries an entry's
length and no allocation or link count, so the on-disk figure was guessed by rounding
the length up to a block and every name of a hard-linked file was charged in full. This is the
reader leita falls back to whenever the MFT cannot be read: no administrator rights,
or a volume that is not NTFS.

One handle on the directory answers most of it. GetFileInformationByHandleEx with
FileIdExtdDirectoryInfo hands back a buffer of entries per call, each with its length,
its allocation, its attributes, its reparse tag and its 128-bit file id, so a
directory costs one call per buffer. The one thing no directory listing carries is
the link count, so on a volume that can hold hard links each file is asked about by
name, relative to the open directory, with NtQueryInformationByName: one call per
file, as statx is on Linux, and no handle opened and closed around it. A volume that
cannot hold hard links, FAT and exFAT, is never asked.

Its answer is preferred to the listing's for the size as well: NTFS updates the copy
of a file's sizes in its directory lazily, and only under the name the file was last
reached by, so another name of a hard-linked file can carry stale figures. The
allocation it reports is what the volume set aside for the file's unnamed stream; a
compressed or sparse file asks once more for what it actually occupies, which is
what GetCompressedFileSizeW reports, since only that leaves out the holes and the
compressed-away clusters.
*/
@(private)
read_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	s := &w.scratch
	base, extended_ok := extended(d.path, s)
	if !extended_ok {
		mark_unread(w, d.index, false)
		return 0, 0, false
	}
	wide, wide_ok := widen(base, &s.wide)
	if !wide_ok {
		w.err = .Out_Of_Memory
		return 0, 0, false
	}
	// Not FILE_FLAG_OPEN_REPARSE_POINT, for the reason the Linux reader gives: the
	// queue holds a junction or a symlink only when the caller asked for those to be
	// followed. BACKUP_SEMANTICS is what lets CreateFileW open a directory at all.
	dir := win.CreateFileW(
		wide,
		win.FILE_LIST_DIRECTORY | win.FILE_READ_ATTRIBUTES | win.SYNCHRONIZE,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if dir == win.INVALID_HANDLE_VALUE {
		mark_unread(w, d.index, win.GetLastError() == win.ERROR_ACCESS_DENIED)
		return 0, 0, false
	}
	defer win.CloseHandle(dir)

	vol, vol_ok := volume_of(dir, s)
	if !vol_ok {
		w.err = .Out_Of_Memory
		return 0, 0, false
	}

	// Eight-byte aligned, as the entries in it are, and the size the other readers
	// give their listing calls.
	buf: [32 * mem.Kilobyte / size_of(u64)]u64
	class := Restart_Class[s.volumes[vol].listing]
	for {
		if !win.GetFileInformationByHandleEx(dir, class, &buf, size_of(buf)) {
			err := win.GetLastError()
			if err == win.ERROR_NO_MORE_FILES {
				break
			}
			// A filesystem that does not answer the extended class refuses it on the
			// first call, before anything was listed, and the walk falls back to the
			// full class, which carries the sizes without the id.
			refused :=
				err == win.ERROR_INVALID_PARAMETER ||
				err == ERROR_INVALID_LEVEL ||
				err == win.ERROR_NOT_SUPPORTED
			if refused && nodes == 0 && s.volumes[vol].listing == .Extended {
				s.volumes[vol].listing = .Full
				class = Restart_Class[.Full]
				continue
			}
			mark_unread(w, d.index, err == win.ERROR_ACCESS_DENIED)
			return nodes, bytes, false
		}
		class = Next_Class[s.volumes[vol].listing]

		at := 0
		for {
			l := entry_at(buf[:], at, s.volumes[vol].listing)
			if !is_dot(l.name) {
				e, described := describe(dir, l, s.volumes[vol], s)
				if !described {
					w.err = .Out_Of_Memory
					return nodes, bytes, false
				}
				index, descend, charged, recorded := record(w, d.index, e)
				if !recorded {
					return nodes, bytes, false
				}
				if descend {
					child, join_err := join(base, e.name, w.allocator)
					if join_err != nil {
						w.err = .Out_Of_Memory
						return nodes, bytes, false
					}
					append(&w.found, Dir{index = index, path = child})
				}
				nodes += 1
				bytes += charged
			}
			if l.next == 0 {
				break
			}
			at += int(l.next)
		}
	}
	return nodes, bytes, true
}

/*
One listed entry as either listing class describes it. The name is a view into the
buffer the listing landed in, which the next call overwrites.

The full-directory class carries no file id, and in place of the reparse tag it
carries the size of the extended attributes. FindFirstFile hands that field back as
WIN32_FIND_DATAW.dwReserved0, which is documented as the reparse tag whenever the
entry is a reparse point.
*/
@(private = "file")
Dir_Entry :: struct {
	next:       u32,
	attributes: u32,
	tag:        u32,
	allocated:  i64,
	length:     i64, // EndOfFile: the bytes of data, as against the space set aside for them
	id:         [2]u64, // low half, high half
	has_id:     bool,
	name:       []u16,
}

@(private = "file")
entry_at :: proc(buf: []u64, at: int, listing: Listing) -> (l: Dir_Entry) {
	raw := ([^]u8)(raw_data(buf))[at:]
	switch listing {
	case .Extended:
		info := (^File_Id_Extd_Dir_Info)(raw)
		l = {
			next       = info.next_entry_offset,
			attributes = info.file_attributes,
			tag        = info.reparse_point_tag,
			allocated  = info.allocation_size,
			length     = info.end_of_file,
			id         = info.file_id,
			has_id     = true,
			name       = ([^]u16)(
				raw[size_of(File_Id_Extd_Dir_Info):],
			)[:info.file_name_length / 2],
		}
	case .Full:
		info := (^File_Full_Dir_Info)(raw)
		l = {
			next       = info.next_entry_offset,
			attributes = info.file_attributes,
			tag        = info.ea_size,
			allocated  = info.allocation_size,
			length     = info.end_of_file,
			name       = ([^]u16)(raw[FULL_DIR_NAME_OFFSET:])[:info.file_name_length / 2],
		}
	}
	if l.attributes & win.FILE_ATTRIBUTE_REPARSE_POINT == 0 {
		l.tag = 0
	}
	return l
}

@(private = "file")
is_dot :: proc(name: []u16) -> bool {
	switch len(name) {
	case 1:
		return name[0] == '.'
	case 2:
		return name[0] == '.' && name[1] == '.'
	}
	return false
}

/*
Turn a listed entry into what the tree records.

A reparse point whose tag is a name surrogate stands for something elsewhere, as a
symlink does: a symlink, a junction, or another volume mounted on a directory. The
first two are links, walked only when the caller asked for links to be followed. A
mounted volume is recorded as the directory it appears to be but never walked, as
the macOS reader treats a mount point, so a scan stays on the volume it started on.
Any other reparse point, a cloud placeholder or a deduplicated file, is the file or
directory it says it is, which is also how the MFT reader finds it.

A file stored inside its MFT record occupies no clusters of its own. The MFT reader
charges it the length of its data, so a directory of small files does not read as
empty, and this must charge the same number for the two engines to agree. NTFS
allocates a non-resident stream in whole clusters, so an allocation that is not a
whole number of them is a resident one. The system reports that allocation rounded
up to 8 bytes (104 for 100 bytes of data, seen on windows-latest in the survey fill
test), so the file is charged its EndOfFile instead, which is the 100.

Not ok only when the name would not fit in memory.
*/
@(private = "file")
describe :: proc(dir: win.HANDLE, l: Dir_Entry, vol: Volume, s: ^Scratch) -> (e: Entry, ok: bool) {
	e.name = narrow(l.name, &s.name) or_return
	directory := l.attributes & win.FILE_ATTRIBUTE_DIRECTORY != 0
	if l.tag & IO_REPARSE_TAG_NAME_SURROGATE != 0 {
		if directory && l.tag == win.IO_REPARSE_TAG_MOUNT_POINT && is_volume_mount(dir, l.name) {
			e.directory = true
			e.mount = true
		} else {
			e.symlink = true
		}
		return e, true
	}
	if directory {
		e.directory = true
		return e, true
	}

	allocated, length := l.allocated, l.length
	links_known := false
	known_links: u32
	if vol.hard_links {
		if info, asked := standard_info(dir, l.name); asked {
			allocated = i64(info.AllocationSize)
			length = i64(info.EndOfFile)
			// Without the file's id there is no telling its names apart from another
			// file's, so it is charged as though it had one name.
			if info.NumberOfLinks > 1 && l.has_id {
				e.links = info.NumberOfLinks
				known_links = e.links
				links_known = true
				e.id = {
					device = vol.serial,
					inode  = l.id[0],
					upper  = l.id[1],
				}
			} else if info.NumberOfLinks <= 1 {
				known_links = u32(info.NumberOfLinks)
				links_known = true
			}
		}
	}
	logical := u64(max(length, 0))
	reported := u64(max(allocated, 0))
	occupied: u64
	occupied_known := false
	compressed := l.attributes & (win.FILE_ATTRIBUTE_COMPRESSED | win.FILE_ATTRIBUTE_SPARSE_FILE) != 0
	if compressed {
		if got, asked := compressed_size(dir, l.name); asked {
			occupied = u64(max(got, 0))
			occupied_known = true
		}
	}
	e.disk, e.account = windows_account({
		logical = logical,
		reported_allocation = reported,
		occupied = occupied,
		occupied_known = occupied_known,
		compressed_or_sparse = compressed,
		cluster = vol.cluster,
		ntfs = vol.ntfs,
		links = known_links,
		links_known = links_known,
	})
	return e, true
}

// What NtQueryInformationByName says of a file named relative to an open directory:
// its link count and allocation, asked without opening it. Falls back to opening the
// file where the call is refused.
@(private = "file")
standard_info :: proc(dir: win.HANDLE, name: []u16) -> (info: win.FILE_STANDARD_INFO, ok: bool) {
	us := counted(name)
	oa := relative(dir, &us)
	iosb: win.IO_STATUS_BLOCK
	status := NtQueryInformationByName(&oa, &iosb, &info, size_of(info), .FileStandardInformation)
	if status >= 0 {
		return info, true
	}
	f := open_relative(dir, name, FILE_NON_DIRECTORY_FILE) or_return
	defer win.CloseHandle(f)
	status = win.NtQueryInformationFile(f, &iosb, &info, size_of(info), .FileStandardInformation)
	return info, status >= 0
}

// What a compressed or sparse file occupies, which is what GetCompressedFileSizeW
// reports: the clusters actually allocated, holes and compressed-away space left out.
@(private = "file")
compressed_size :: proc(dir: win.HANDLE, name: []u16) -> (occupied: i64, ok: bool) {
	f := open_relative(dir, name, FILE_NON_DIRECTORY_FILE) or_return
	defer win.CloseHandle(f)
	info: File_Compression_Information
	iosb: win.IO_STATUS_BLOCK
	status := win.NtQueryInformationFile(
		f,
		&iosb,
		&info,
		size_of(info),
		.FileCompressionInformation,
	)
	return info.compressed_file_size, status >= 0
}

/*
Whether a mount-point reparse point is another volume mounted here rather than a
junction. Both carry the same tag; a mounted volume's target is the volume itself,
\??\Volume{guid}\, where a junction's is a path. Rare enough that opening it to ask
costs nothing worth counting.
*/
@(private = "file")
is_volume_mount :: proc(dir: win.HANDLE, name: []u16) -> bool {
	f, opened := open_relative(dir, name, FILE_DIRECTORY_FILE)
	if !opened {
		return false
	}
	defer win.CloseHandle(f)
	buf: [win.MAXIMUM_REPARSE_DATA_BUFFER_SIZE / size_of(u32)]u32
	returned: win.DWORD
	if !win.DeviceIoControl(
		f,
		win.FSCTL_GET_REPARSE_POINT,
		nil,
		0,
		&buf,
		size_of(buf),
		&returned,
		nil,
	) {
		return false
	}
	raw := ([^]u8)(&buf)[:returned]
	header :: int(size_of(win.REPARSE_DATA_BUFFER))
	mount  :: int(offset_of(win.MOUNT_POINT_REPARSE_BUFFER, PathBuffer))
	if len(raw) < header + mount {
		return false
	}
	rdb := (^win.REPARSE_DATA_BUFFER)(&raw[0])
	if rdb.ReparseTag != win.IO_REPARSE_TAG_MOUNT_POINT {
		return false
	}
	mp := (^win.MOUNT_POINT_REPARSE_BUFFER)(&raw[header])
	start := header + mount + int(mp.SubstituteNameOffset)
	length := int(mp.SubstituteNameLength)
	if start + length > len(raw) {
		return false
	}
	target := ([^]u16)(&raw[start])[:length / 2]
	prefix := VOLUME_PREFIX
	if len(target) < len(prefix) {
		return false
	}
	for i in 0 ..< len(prefix) {
		if target[i] != u16(prefix[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
VOLUME_PREFIX :: `\??\Volume{`

// Open an entry of `dir` by its name to read its attributes: the entry itself, never
// what a reparse point names.
@(private = "file")
open_relative :: proc(dir: win.HANDLE, name: []u16, options: u32) -> (f: win.HANDLE, ok: bool) {
	us := counted(name)
	oa := relative(dir, &us)
	iosb: win.IO_STATUS_BLOCK
	status := win.NtCreateFile(
		&f,
		win.FILE_READ_ATTRIBUTES | win.SYNCHRONIZE,
		&oa,
		&iosb,
		nil,
		0,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		FILE_OPEN,
		options | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
		nil,
		0,
	)
	return f, status >= 0
}

@(private = "file")
counted :: proc(name: []u16) -> win.UNICODE_STRING {
	n := u16(len(name) * size_of(u16))
	return {Length = n, MaximumLength = n, Buffer = raw_data(name)}
}

// A name relative to an open directory. Matched exactly, since it is the name the
// directory listed, which matters in a directory that tells case apart.
@(private = "file")
relative :: proc(dir: win.HANDLE, name: ^win.UNICODE_STRING) -> win.OBJECT_ATTRIBUTES {
	return {Length = size_of(win.OBJECT_ATTRIBUTES), RootDirectory = dir, ObjectName = name}
}

/*
What a reader needs to know of the volume a directory is on, kept per worker by
serial number, so it is asked once per volume rather than once per directory.

`listing` starts at the extended class and falls back to the full one the first time
the volume refuses it. `cluster` is its allocation unit. `hard_links` is whether a
file on it can have more than one name; FAT and exFAT cannot, and their files are
never asked about one at a time.
*/
@(private = "file")
Volume :: struct {
	serial:     u64,
	cluster:    u64,
	hard_links: bool,
	ntfs:       bool,
	listing:    Listing,
}

@(private = "file")
Listing :: enum {
	Extended,
	Full,
}

@(private = "file")
Restart_Class := [Listing]win.FILE_INFO_BY_HANDLE_CLASS {
	.Extended = .FileIdExtdDirectoryRestartInfo,
	.Full     = .FileFullDirectoryRestartInfo,
}

@(private = "file")
Next_Class := [Listing]win.FILE_INFO_BY_HANDLE_CLASS {
	.Extended = .FileIdExtdDirectoryInfo,
	.Full     = .FileFullDirectoryInfo,
}

/*
Which of the worker's known volumes `dir` is on, learning a new one if need be. The
serial is asked every time, since a followed junction can lead anywhere; the rest
only the first time the serial is seen. A volume that will not say is taken as one
that can hold hard links and charged what it reports allocated, which is the safe
reading of both. Not ok only when there is no room to remember it.
*/
@(private = "file")
volume_of :: proc(dir: win.HANDLE, s: ^Scratch) -> (index: int, ok: bool) {
	iosb: win.IO_STATUS_BLOCK
	serial: u64
	// The volume's label follows the fixed part, and the buffer leaves room for the
	// longest one a volume may have.
	volume: [128]u64
	status := NtQueryVolumeInformationFile(
		dir,
		&iosb,
		&volume,
		size_of(volume),
		.FileFsVolumeInformation,
	)
	if status >= 0 {
		serial = u64((^File_Fs_Volume_Information)(&volume).volume_serial_number)
	}
	for v, i in s.volumes {
		if v.serial == serial {
			return i, true
		}
	}

	v := Volume {
		serial     = serial,
		hard_links = true,
	}
	attribute: [64]u64
	status = NtQueryVolumeInformationFile(
		dir,
		&iosb,
		&attribute,
		size_of(attribute),
		.FileFsAttributeInformation,
	)
	if status >= 0 {
		info := (^File_Fs_Attribute_Information)(&attribute)
		v.hard_links = info.file_system_attributes & FILE_SUPPORTS_HARD_LINKS != 0
		named := ([^]u16)(([^]u8)(&attribute)[size_of(File_Fs_Attribute_Information):])
		name := named[:min(info.file_system_name_length / 2, 8)]
		v.ntfs =
			len(name) == 4 && name[0] == 'N' && name[1] == 'T' && name[2] == 'F' && name[3] == 'S'
	}
	size: File_Fs_Size_Information
	status = NtQueryVolumeInformationFile(dir, &iosb, &size, size_of(size), .FileFsSizeInformation)
	if status >= 0 {
		v.cluster = u64(size.sectors_per_allocation_unit) * u64(size.bytes_per_sector)
	}
	if _, err := append(&s.volumes, v); err != nil {
		return 0, false
	}
	return len(s.volumes) - 1, true
}

/*
The path a directory is opened by, with the \\?\ prefix that lifts the 260-character
limit and turns off every rewriting of the path on the way to the kernel. Only the
root a walk starts from arrives without it: it is made absolute here, and every
directory found below it is joined onto the prefixed form, so is already in it.

Not ok when the path cannot be made absolute or there is no room to, either of which
the caller treats as a directory it could not open.
*/
@(private = "file")
extended :: proc(path: string, s: ^Scratch) -> (full_path: string, ok: bool) {
	if strings.has_prefix(path, `\\?\`) || strings.has_prefix(path, `\\.\`) {
		return path, true
	}
	wide := widen(path, &s.wide) or_return
	n := win.GetFullPathNameW(wide, 0, nil, nil)
	if n == 0 {
		return "", false
	}
	if resize(&s.full, int(n)) != nil {
		return "", false
	}
	n = win.GetFullPathNameW(wide, n, win.wstring(raw_data(s.full)), nil)
	if n == 0 || int(n) >= len(s.full) {
		return "", false
	}
	full := s.full[:n]
	// A drive's root keeps its separator, C:\; anything longer drops a trailing one.
	if len(full) > 3 && full[len(full) - 1] == '\\' {
		full = full[:len(full) - 1]
	}
	prefix := `\\?\`
	if len(full) >= 2 && full[0] == '\\' && full[1] == '\\' {
		prefix = `\\?\UNC\`
		full = full[2:]
	}
	clear(&s.root)
	if _, err := append(&s.root, prefix); err != nil {
		return "", false
	}
	at := len(s.root)
	if resize(&s.root, at + len(full) * 3) != nil {
		return "", false
	}
	n8 := utf16.decode_to_utf8(s.root[at:], full)
	return string(s.root[:at + n8]), true
}

// `text` as a terminated UTF-16 string, in `buf`.
@(private = "file")
widen :: proc(text: string, buf: ^[dynamic]u16) -> (win.wstring, bool) {
	// Never more UTF-16 units than UTF-8 bytes, and one for the terminator.
	if resize(buf, len(text) + 1) != nil {
		return nil, false
	}
	n := utf16.encode_string(buf[:len(text)], text)
	buf[n] = 0
	return win.wstring(raw_data(buf[:])), true
}

// `name` as UTF-8, in `buf`, which the next name overwrites. An unpaired surrogate,
// which NTFS allows in a name, becomes the replacement character.
@(private = "file")
narrow :: proc(name: []u16, buf: ^[dynamic]u8) -> (string, bool) {
	if resize(buf, len(name) * 3) != nil {
		return "", false
	}
	n := utf16.decode_to_utf8(buf[:], name)
	return string(buf[:n]), true
}

// The child's path, which a directory listing does not hand back and the queue needs.
@(private)
join :: proc(dir, name: string, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	if strings.has_suffix(dir, `\`) {
		return strings.concatenate({dir, name}, allocator)
	}
	return strings.concatenate({dir, `\`, name}, allocator)
}

/*
Scratch is what one worker reuses from one directory to the next: the volumes it has
met, and the buffers a path or a name is converted in.
*/
@(private)
Scratch :: struct {
	volumes: [dynamic]Volume,
	wide:    [dynamic]u16,
	full:    [dynamic]u16,
	root:    [dynamic]u8,
	name:    [dynamic]u8,
}

@(private)
scratch_make :: proc(allocator: mem.Allocator) -> Scratch {
	return {
		volumes = make([dynamic]Volume, allocator),
		wide = make([dynamic]u16, allocator),
		full = make([dynamic]u16, allocator),
		root = make([dynamic]u8, allocator),
		name = make([dynamic]u8, allocator),
	}
}

@(private)
scratch_destroy :: proc(s: ^Scratch) {
	delete(s.volumes)
	delete(s.wide)
	delete(s.full)
	delete(s.root)
	delete(s.name)
}

// FILE_ID_EXTD_DIR_INFO from <winbase.h>, up to the name that follows it.
@(private = "file")
File_Id_Extd_Dir_Info :: struct {
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
	reparse_point_tag: u32,
	file_id:           [2]u64,
}
#assert(size_of(File_Id_Extd_Dir_Info) == 88)

// FILE_FULL_DIR_INFO from <winbase.h>. Its name starts at byte 68, before the
// padding that rounds the struct up to its alignment.
@(private = "file")
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

@(private = "file")
FULL_DIR_NAME_OFFSET :: 68
#assert(offset_of(File_Full_Dir_Info, ea_size) + size_of(u32) == FULL_DIR_NAME_OFFSET)

// FILE_COMPRESSION_INFORMATION from <ntifs.h>.
@(private = "file")
File_Compression_Information :: struct {
	compressed_file_size:   i64,
	compression_format:     u16,
	compression_unit_shift: u8,
	chunk_shift:            u8,
	cluster_shift:          u8,
	reserved:               [3]u8,
}

// FILE_FS_VOLUME_INFORMATION, FILE_FS_ATTRIBUTE_INFORMATION and
// FILE_FS_SIZE_INFORMATION from <ntifs.h>, each up to the name that follows it.
@(private = "file")
File_Fs_Volume_Information :: struct {
	volume_creation_time: i64,
	volume_serial_number: u32,
	volume_label_length:  u32,
	supports_objects:     u8,
}

@(private = "file")
File_Fs_Attribute_Information :: struct {
	file_system_attributes:        u32,
	maximum_component_name_length: i32,
	file_system_name_length:       u32,
}

@(private = "file")
File_Fs_Size_Information :: struct {
	total_allocation_units:      i64,
	available_allocation_units:  i64,
	sectors_per_allocation_unit: u32,
	bytes_per_sector:            u32,
}

@(private = "file")
Fs_Information_Class :: enum i32 {
	FileFsVolumeInformation    = 1,
	FileFsSizeInformation      = 3,
	FileFsAttributeInformation = 5,
}

@(private = "file")
ERROR_INVALID_LEVEL :: 124
@(private = "file")
IO_REPARSE_TAG_NAME_SURROGATE :: 0x20000000
@(private = "file")
FILE_SUPPORTS_HARD_LINKS :: 0x00400000
@(private = "file")
FILE_OPEN :: 1
@(private = "file")
FILE_DIRECTORY_FILE :: 0x00000001
@(private = "file")
FILE_SYNCHRONOUS_IO_NONALERT :: 0x00000020
@(private = "file")
FILE_NON_DIRECTORY_FILE :: 0x00000040
@(private = "file")
FILE_OPEN_REPARSE_POINT :: 0x00200000

// Not in core:sys/windows. NtQueryInformationByName is documented as available from
// Windows 10 1703.
@(private = "file", default_calling_convention = "system")
foreign ntdll {
	NtQueryInformationByName     :: proc(ObjectAttributes: ^win.OBJECT_ATTRIBUTES, IoStatusBlock: ^win.IO_STATUS_BLOCK, FileInformation: rawptr, Length: u32, FileInformationClass: win.FILE_INFORMATION_CLASS) -> win.NTSTATUS ---
	NtQueryVolumeInformationFile :: proc(FileHandle: win.HANDLE, IoStatusBlock: ^win.IO_STATUS_BLOCK, FsInformation: rawptr, Length: u32, FsInformationClass: Fs_Information_Class) -> win.NTSTATUS ---
}
