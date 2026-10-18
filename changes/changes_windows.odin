#+build windows
package changes

import "core:slice"
import "core:strings"
import win "core:sys/windows"

/*
Windows: the volume's USN change journal.

NTFS and ReFS append a record to the journal for every change to a file: which file,
which directory holds it, and why. The journal is the volume's, kept across reboots,
and the cursor is a position in it, so a later run reads only what was appended since.

No administrator rights are needed. FSCTL_READ_USN_JOURNAL wants a volume handle
opened for reading, which only an administrator gets, but a handle opened for
FILE_TRAVERSE alone can query the journal and read it through
FSCTL_READ_UNPRIVILEGED_USN_JOURNAL (Windows 10 1709 on). That read leaves out names
the caller may not see, and nothing here uses a record's name: only its parent
directory's file id, which is opened by id and asked its path. Microsoft documents
FSCTL_READ_UNPRIVILEGED_USN_JOURNAL but not the access it needs; FILE_TRAVERSE is
what libUSNJournal (github.com/FaultyPine/libUSNJournal) found works without
elevation. CI runs elevated, so the tests show these calls work, not yet that they
work unelevated.

Which records count is chosen by reason, so the journal is filtered where it is kept:
anything that changes what a directory holds or what a file occupies, and not the
closes, timestamps, security and the like that make up most of a busy volume's
journal.

A journal that is not there, was deleted and made again, or has wrapped past the
cursor, a volume that is not the one the cursor was taken on, and a place that is
another directory than it was, all mean the place is scanned whole. Nothing here creates or resizes a journal: that needs an
administrator and changes the machine.
*/

// A cursor for `place` as it is now, to take before scanning it whole. Not ok where
// the volume keeps no journal, or cannot be asked.
now :: proc(place: string) -> (c: Cursor, ok: bool) {
	v, opened := open_volume(as_directory(place))
	if !opened {
		return {}, false
	}
	defer win.CloseHandle(v.handle)
	data, queried := query(v.handle)
	if !queried {
		return {}, false
	}
	id, has_id := place_id(as_directory(place))
	if !has_id {
		return {}, false
	}
	at := now_ns()
	return {
			source = .Usn,
			volume = {u64(v.serial), 0},
			place = id,
			journal = data.journal,
			position = data.next,
			full = at,
		},
		true
}

/*
What changed in `place` since `c`: the directories under it whose entries or files
changed, each once, spelt from `place`. The new cursor is where the journal ended
when it was asked, so whatever is appended while the update runs is read next time.
*/
since :: proc(
	place: string,
	c: Cursor,
	allocator := context.allocator,
) -> (
	changed: Change_Set,
	next: Cursor,
	err: Error,
) {
	if c.source != .Usn {
		return rescan("no change journal cursor was kept for this place"), {}, .None
	}
	v, opened := open_volume(as_directory(place))
	if !opened {
		return rescan("the place's volume could not be opened to read its journal"), {}, .None
	}
	defer win.CloseHandle(v.handle)
	if u64(v.serial) != c.volume[0] {
		return rescan("another volume is mounted where the place was read"), {}, .None
	}
	// Another directory renamed onto the place is one rename, recorded against the
	// place's parent, outside it; what moved in with it has no record at all.
	id, has_id := place_id(as_directory(place))
	if !has_id {
		return rescan("the place could not be opened"), {}, .None
	}
	if id != c.place {
		return rescan("another directory is in the place than when it was read"), {}, .None
	}
	data, queried := query(v.handle)
	switch {
	case !queried:
		return rescan("the volume keeps no change journal"), {}, .None
	case data.journal != c.journal:
		return rescan("the volume's change journal was made anew"), {}, .None
	case c.position < data.first:
		return rescan("the change journal wrapped past the last scan"), {}, .None
	case c.position > data.next:
		return rescan("the change journal is behind the last scan"), {}, .None
	}
	next = c
	next.position = data.next

	parents := make(map[[16]u8]struct{}, context.temp_allocator)
	wrapped, read_ok := read_parents(v.handle, data, c.position, &parents)
	if wrapped {
		return rescan("the change journal wrapped past the last scan"), {}, .None
	}
	if !read_ok {
		return rescan("the change journal could not be read"), {}, .None
	}

	changed = Change_Set {
		shallow = make([dynamic]string, allocator),
		deep    = make([dynamic]string, allocator),
	}
	if len(parents) == 0 {
		return changed, next, .None
	}
	hint, canonical, hint_ok := open_place(as_directory(place))
	if !hint_ok {
		change_set_destroy(&changed)
		return rescan("the place could not be opened"), {}, .None
	}
	defer win.CloseHandle(hint)
	for id in parents {
		path, found := path_of(hint, id)
		if !found {
			// Gone since: its removal is a record against its own parent, which
			// is in the set if it is in the place.
			continue
		}
		rest, inside := under(canonical, path)
		if !inside {
			continue
		}
		spelt: string
		if rest == "" {
			spelt = strings.clone(place, allocator)
		} else {
			spelt = strings.concatenate({strings.trim_right(place, `\/`), `\`, rest}, allocator)
		}
		append(&changed.shallow, spelt)
	}
	return changed, next, .None
}

/*
`place` as a path that names a directory: a whole volume's place is its drive, C:,
which on its own names the current directory on that drive rather than its root
(Microsoft, "Naming Files, Paths, and Namespaces": a drive-relative path).
*/
@(private = "file")
as_directory :: proc(place: string) -> string {
	if len(place) == 2 && place[1] == ':' {
		return strings.concatenate({place, `\`}, context.temp_allocator)
	}
	return place
}

// What the journal said of itself: USN_JOURNAL_DATA_V0, as far as it matters here.
@(private = "file")
Journal :: struct {
	journal: u64,
	first:   i64,
	next:    i64,
}

@(private = "file")
Volume :: struct {
	handle: win.HANDLE,
	serial: u32,
}

/*
Open the volume holding `place` for FILE_TRAVERSE, the access an unprivileged
journal read needs, and learn its serial number. A volume is opened by its GUID
name rather than its letter, so a volume mounted on a folder is found as well.
*/
@(private = "file")
open_volume :: proc(place: string) -> (v: Volume, ok: bool) {
	mount: [win.MAX_PATH + 1]u16
	wplace := win.utf8_to_wstring(place, context.temp_allocator)
	if !GetVolumePathNameW(wplace, &mount[0], len(mount)) {
		return {}, false
	}
	if !GetVolumeInformationW(win.wstring(&mount[0]), nil, 0, &v.serial, nil, nil, nil, 0) {
		return {}, false
	}
	name: [64]u16
	if !GetVolumeNameForVolumeMountPointW(win.wstring(&mount[0]), &name[0], len(name)) {
		return {}, false
	}
	// \\?\Volume{guid}\ names the root directory; without the slash, the volume.
	n := 0
	for name[n] != 0 {
		n += 1
	}
	if n > 0 && name[n - 1] == '\\' {
		name[n - 1] = 0
	}
	v.handle = win.CreateFileW(
		win.wstring(&name[0]),
		win.FILE_TRAVERSE,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		0,
		nil,
	)
	return v, v.handle != win.INVALID_HANDLE_VALUE
}

@(private = "file")
query :: proc(volume: win.HANDLE) -> (j: Journal, ok: bool) {
	// Room for USN_JOURNAL_DATA_V2, the largest a volume answers with; the fields
	// read here begin every version alike.
	out: [10]u64
	got: win.DWORD
	if !win.DeviceIoControl(
		volume,
		FSCTL_QUERY_USN_JOURNAL,
		nil,
		0,
		&out,
		size_of(out),
		&got,
		nil,
	) {
		return {}, false
	}
	if got < 24 {
		return {}, false
	}
	return {journal = out[0], first = i64(out[1]), next = i64(out[2])}, true
}

/*
Read the journal from `start` to where it ended when queried, collecting the file id
of every directory holding a file a counted record names. `wrapped` when the records
from `start` are gone; not ok when a page holds a record usn_page cannot trust.
*/
@(private = "file")
read_parents :: proc(
	volume: win.HANDLE,
	j: Journal,
	start: i64,
	parents: ^map[[16]u8]struct{},
) -> (
	wrapped, ok: bool,
) {
	request := Read_Usn_Journal_Data_V1 {
		start       = start,
		reason_mask = COUNTED,
		journal     = j.journal,
		min_major   = 2,
		max_major   = 3,
	}
	buf: [64 * 1024 / size_of(u64)]u64
	page := slice.to_bytes(buf[:])
	for request.start < j.next {
		got: win.DWORD
		if !win.DeviceIoControl(
			volume,
			FSCTL_READ_UNPRIVILEGED_USN_JOURNAL,
			&request,
			size_of(request),
			&buf,
			size_of(buf),
			&got,
			nil,
		) {
			e := win.GetLastError()
			if e == ERROR_JOURNAL_ENTRY_DELETED {
				return true, false
			}
			if e == win.ERROR_HANDLE_EOF {
				return false, true
			}
			return false, false
		}
		if int(got) > len(page) {
			return false, false
		}
		after, parsed := usn_page(page[:got], parents)
		if !parsed {
			return false, false
		}
		if after <= request.start {
			break
		}
		request.start = after
	}
	return false, true
}

/*
A handle on `place` to open other files of its volume by id from, and the path the
system gives it, which is what a path opened by id will start with.
*/
@(private = "file")
open_place :: proc(place: string) -> (h: win.HANDLE, canonical: string, ok: bool) {
	h = open_directory(place)
	if h == win.INVALID_HANDLE_VALUE {
		return nil, "", false
	}
	canonical, ok = final_path(h)
	if !ok {
		win.CloseHandle(h)
		return nil, "", false
	}
	return h, canonical, true
}

// The 128-bit file id of the directory `place` names, which with the volume serial
// number identifies one file on the machine (FILE_ID_INFO, Microsoft Learn).
@(private = "file")
place_id :: proc(place: string) -> (id: [2]u64, ok: bool) {
	h := open_directory(place)
	if h == win.INVALID_HANDLE_VALUE {
		return {}, false
	}
	defer win.CloseHandle(h)
	info: win.FILE_ID_INFO
	if !win.GetFileInformationByHandleEx(h, .FileIdInfo, &info, size_of(info)) {
		return {}, false
	}
	return transmute([2]u64)info.FileId.Identifier, true
}

// A handle on the directory `place` for asking it about itself.
@(private = "file")
open_directory :: proc(place: string) -> win.HANDLE {
	return win.CreateFileW(
		win.utf8_to_wstring(place, context.temp_allocator),
		win.FILE_READ_ATTRIBUTES,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
}

// The path of the directory with file id `id` on the volume `hint` is on, in the
// temp allocator.
@(private = "file")
path_of :: proc(hint: win.HANDLE, id: [16]u8) -> (string, bool) {
	desc := File_Id_Descriptor {
		size = size_of(File_Id_Descriptor),
		kind = EXTENDED_FILE_ID_TYPE,
		id   = id,
	}
	h := OpenFileById(
		hint,
		&desc,
		win.FILE_READ_ATTRIBUTES,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.FILE_FLAG_BACKUP_SEMANTICS,
	)
	if h == win.INVALID_HANDLE_VALUE {
		return "", false
	}
	defer win.CloseHandle(h)
	return final_path(h)
}

// What the system calls the file `h` is open on, without the \\?\ it prefixes.
@(private = "file")
final_path :: proc(h: win.HANDLE) -> (string, bool) {
	buf: [32 * 1024]u16
	n := win.GetFinalPathNameByHandleW(h, win.wstring(&buf[0]), len(buf), 0)
	if n == 0 || int(n) >= len(buf) {
		return "", false
	}
	path, err := win.wstring_to_utf8(win.wstring(&buf[0]), int(n), context.temp_allocator)
	if err != nil {
		return "", false
	}
	if strings.has_prefix(path, `\\?\UNC\`) {
		return "", false
	}
	return strings.trim_prefix(path, `\\?\`), true
}

// FSCTL codes, as CTL_CODE(FILE_DEVICE_FILE_SYSTEM, function, method, FILE_ANY_ACCESS).
@(private = "file")
FSCTL_QUERY_USN_JOURNAL :: 0x000900f4 // function 61, METHOD_BUFFERED
@(private = "file")
FSCTL_READ_UNPRIVILEGED_USN_JOURNAL :: 0x000903ab // function 234, METHOD_NEITHER

@(private = "file")
ERROR_JOURNAL_ENTRY_DELETED :: 1181

// USN_REASON_* that change what a directory holds or what a file occupies: data
// overwritten, extended or truncated, in the unnamed stream or a named one; a file
// made, deleted, renamed from or to, linked or unlinked; compression, encryption, a
// reparse point or a stream changed.
@(private = "file")
COUNTED :: u32(
	0x00000001 |
	0x00000002 |
	0x00000004 |
	0x00000010 |
	0x00000020 |
	0x00000040 |
	0x00000100 |
	0x00000200 |
	0x00001000 |
	0x00002000 |
	0x00010000 |
	0x00020000 |
	0x00040000 |
	0x00100000 |
	0x00200000,
)

// READ_USN_JOURNAL_DATA_V1. No wait: return what is there.
@(private = "file")
Read_Usn_Journal_Data_V1 :: struct {
	start:         i64,
	reason_mask:   u32,
	only_on_close: u32,
	timeout:       u64,
	bytes_to_wait: u64,
	journal:       u64,
	min_major:     u16,
	max_major:     u16,
}

// FILE_ID_DESCRIPTOR, with the 128-bit id that covers ReFS and NTFS alike.
@(private = "file")
File_Id_Descriptor :: struct {
	size: u32,
	kind: u32,
	id:   [16]u8,
}
#assert(size_of(File_Id_Descriptor) == 24)

@(private = "file")
EXTENDED_FILE_ID_TYPE :: 2

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	// Not bound by core:sys/windows, so declared here.
	GetVolumePathNameW                :: proc(lpszFileName: win.LPCWSTR, lpszVolumePathName: win.LPWSTR, cchBufferLength: win.DWORD) -> win.BOOL ---
	GetVolumeNameForVolumeMountPointW :: proc(lpszVolumeMountPoint: win.LPCWSTR, lpszVolumeName: win.LPWSTR, cchBufferLength: win.DWORD) -> win.BOOL ---
	GetVolumeInformationW             :: proc(lpRootPathName: win.LPCWSTR, lpVolumeNameBuffer: win.LPWSTR, nVolumeNameSize: win.DWORD, lpVolumeSerialNumber: ^win.DWORD, lpMaximumComponentLength: ^win.DWORD, lpFileSystemFlags: ^win.DWORD, lpFileSystemNameBuffer: win.LPWSTR, nFileSystemNameSize: win.DWORD) -> win.BOOL ---
	OpenFileById                      :: proc(hVolumeHint: win.HANDLE, lpFileId: ^File_Id_Descriptor, dwDesiredAccess: win.DWORD, dwShareMode: win.DWORD, lpSecurityAttributes: ^win.SECURITY_ATTRIBUTES, dwFlagsAndAttributes: win.DWORD) -> win.HANDLE ---
}
