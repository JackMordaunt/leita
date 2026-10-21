#+build windows
package leita_files

import "core:encoding/endian"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"

import "../../home"
import "../../reclaim"

foreign import kernel32 "system:Kernel32.lib"
foreign import shell32 "system:Shell32.lib"

DRIVE_REMOVABLE :: 2
DRIVE_FIXED     :: 3
DRIVE_REMOTE    :: 4
DRIVE_RAMDISK   :: 6

SHERB_NOCONFIRMATION :: 0x00000001
SHERB_NOPROGRESSUI   :: 0x00000002
SHERB_NOSOUND        :: 0x00000004

// SHQUERYRBINFO is passed to SHQueryRecycleBinW after cbSize is assigned.
// shellapi.h includes pshpack1.h only for 32-bit builds. On x64 the struct is
// naturally aligned: 24 bytes, with the two counts at 8 and 16. A packed 20-byte
// cbSize is ERROR_INVALID_PARAMETER, and that volume is then left out.
SHQUERYRBINFO :: struct {
	cbSize:      win32.DWORD,
	i64Size:     i64,
	i64NumItems: i64,
}

#assert(size_of(SHQUERYRBINFO) == 24)
#assert(offset_of(SHQUERYRBINFO, i64Size) == 8)
#assert(offset_of(SHQUERYRBINFO, i64NumItems) == 16)

@(default_calling_convention = "system")
foreign kernel32 {
	GetLogicalDrives :: proc() -> win32.DWORD ---
	GetDriveTypeW    :: proc(lpRootPathName: win32.LPCWSTR) -> win32.UINT ---
}

@(default_calling_convention = "system")
foreign shell32 {
	SHQueryRecycleBinW :: proc(pszRootPath: win32.LPCWSTR, pSHQueryRBInfo: ^SHQUERYRBINFO) -> win32.HRESULT ---
	SHEmptyRecycleBinW :: proc(hwnd: win32.HWND, pszRootPath: win32.LPCWSTR, dwFlags: win32.DWORD) -> win32.HRESULT ---
}

/*
recycle_bins are the Recycle Bins on this machine, one per volume that answers,
with this user's folder as path. A volume the shell will not query is left out
unless that folder already holds recycled files. Volume and path are in allocator.
*/
recycle_bins :: proc(sid: string, allocator := context.allocator) -> []Recycle_Bin {
	if sid == "" {
		return nil
	}
	// Output can use the caller's temp allocator. Reset only our separate
	// scratch arena; resetting the caller's arena would invalidate out.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&scratch)
	work := mem.dynamic_arena_allocator(&scratch)
	mask := GetLogicalDrives()
	out := make([dynamic]Recycle_Bin, allocator)
	for i in 0 ..< 26 {
		mem.dynamic_arena_free_all(&scratch)
		if mask & (1 << u32(i)) == 0 {
			continue
		}
		letter := 'A' + i
		root := [4]u16{u16(letter), ':', '\\', 0}
		kind := GetDriveTypeW(cstring16(&root[0]))
		if kind != DRIVE_FIXED &&
		   kind != DRIVE_REMOVABLE &&
		   kind != DRIVE_RAMDISK &&
		   kind != DRIVE_REMOTE {
			continue
		}
		vol := strings.clone(string([]u8{u8(letter), ':', '\\'}), allocator)
		path := strings.concatenate({vol, reclaim.RECYCLE_DIR, `\`, sid}, allocator)
		bytes, items, ok := query_recycle_bin(cstring16(&root[0]), path, work)
		if !ok {
			delete(path, allocator)
			delete(vol, allocator)
			continue
		}
		append(&out, Recycle_Bin{volume = vol, path = path, bytes = bytes, items = items})
	}
	return out[:]
}

// recycle_bin_info is what the Recycle Bin on root holds. root must be a volume
// `C:\` or that volume's Recycle Bin folder; anything else returns not-ok and
// the shell is not called.
recycle_bin_info :: proc(
	root: string,
	allocator := context.temp_allocator,
) -> (
	bytes, items: u64,
	ok: bool,
) {
	letter, has := drive_letter(root)
	if !has {
		return 0, 0, false
	}
	wide := [4]u16{letter, ':', '\\', 0}
	return query_recycle_bin(cstring16(&wide[0]), recycle_folder(root, allocator), allocator)
}

/*
query_recycle_bin is what the shell reports for the volume at root, which is
`C:\` and a NUL. Nothing else in this process initializes COM, and the shell's
recycle-bin enumerator is a COM object, so CoInitializeEx asks for the apartment
the shell expects. It is released only when this call was the one that
initialized the thread.

A positive shell size is kept. A size of zero is not, even when the shell
still names items: overlay skips a bin of zero bytes, so this user's folder
is measured. The size is the one stored in the $I record, which is what the
shell itself sums, or the $R file's size when the record says 0. Another
account's folder is not read. An administrator can list it, and emptying
still removes only this account's bin. A folder both call empty stays at the
shell's zero, and a volume the shell will not query whose folder is empty or
unreadable stays out.
*/
@(private)
query_recycle_bin :: proc(
	root: cstring16,
	folder: string,
	allocator := context.temp_allocator,
) -> (
	bytes, items: u64,
	ok: bool,
) {
	release := win32.CoInitializeEx() == win32.S_OK
	defer if release {
		win32.CoUninitialize()
	}
	info := SHQUERYRBINFO {
		cbSize = size_of(SHQUERYRBINFO),
	}
	hr := SHQueryRecycleBinW(root, &info)
	ok = win32.SUCCEEDED(hr)
	if ok {
		bytes = u64(max(info.i64Size, 0))
		items = u64(max(info.i64NumItems, 0))
	}
	// A count with a zero size is not a size. overlay drops bytes == 0, so this
	// user's folder is still read. A positive size is the shell's own sum.
	if ok && bytes > 0 {
		return
	}
	disk_bytes, disk_items, disk_ok := recycle_folder_usage(folder, allocator)
	if !disk_ok || (disk_bytes == 0 && disk_items == 0) {
		return
	}
	log.warnf(
		"Recycle Bin %s: shell returned %#x with %d bytes in %d items; the folder holds %d bytes in %d files",
		folder,
		u32(hr),
		bytes,
		items,
		disk_bytes,
		disk_items,
	)
	return disk_bytes, disk_items, true
}

// recycle_folder is root when root is already a user's Recycle Bin folder, and
// otherwise that folder on root's volume for this process's account. "" when
// root is not a volume. The result is in allocator.
@(private)
recycle_folder :: proc(root: string, allocator := context.allocator) -> string {
	p := strings.trim_right(strings.trim_space(root), `\/`)
	rest := ""
	if len(p) >= 2 && p[1] == ':' {
		rest = strings.trim_left(p[2:], `\/`)
	}
	if rest != "" && recycle_dir_at(rest) {
		return strings.clone(p, allocator)
	}
	letter, has := drive_letter(root)
	if !has {
		return ""
	}
	who := home.user(allocator)
	defer home.user_destroy(&who, allocator)
	if who.uid == "" {
		return ""
	}
	vol := string([]u8{u8(letter), ':', '\\'})
	return strings.concatenate({vol, reclaim.RECYCLE_DIR, `\`, who.uid}, allocator)
}

/*
recycle_folder_usage is the bytes and the count of recycled files in folder, one
item per $I record. The record's size is the original file's, at byte 8, as
Windows has written it since the $I format began. A record that says 0 takes the
$R file's size beside it, so a file the record failed to measure is still
counted. ok is false when folder cannot be listed.
*/
@(private)
recycle_folder_usage :: proc(
	folder: string,
	allocator := context.temp_allocator,
) -> (
	bytes, items: u64,
	ok: bool,
) {
	if folder == "" {
		return 0, 0, false
	}
	entries, err := os.read_all_directory_by_path(folder, allocator)
	if err != nil {
		return 0, 0, false
	}
	for e in entries {
		if !strings.has_prefix(e.name, "$I") || len(e.name) < 2 {
			continue
		}
		size, got := recorded_size(e.fullpath, allocator)
		if !got || size == 0 {
			sibling := strings.concatenate({folder, `\$R`, e.name[2:]}, allocator)
			if info, serr := os.stat(sibling, allocator); serr == nil && info.size > 0 {
				size = u64(info.size)
			}
		}
		bytes += size
		items += 1
	}
	return bytes, items, true
}

// recorded_size is the original file size a $I record stores at byte 8.
@(private)
recorded_size :: proc(path: string, allocator := context.temp_allocator) -> (size: u64, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil || len(data) < 16 {
		return 0, false
	}
	return endian.get_u64(data[8:16], .Little)
}

/*
empty_recycle_bin empties the Recycle Bin on root. root must name a volume
(`C:\`) or that volume's Recycle Bin folder; anything else, including "", is
Missing and the shell is not asked.
*/
empty_recycle_bin :: proc(root: string) -> Error {
	letter, has := drive_letter(root)
	if !has {
		return .Missing
	}
	wide := [4]u16{letter, ':', '\\', 0}
	hr := SHEmptyRecycleBinW(
		nil,
		cstring16(&wide[0]),
		SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND,
	)
	if !win32.SUCCEEDED(hr) {
		return .Denied if win32.HRESULT_CODE(hr) == int(win32.ERROR_ACCESS_DENIED) else .Other
	}
	return .None
}

// drive_letter is the A–Z of a volume path or that volume's Recycle Bin; false
// for anything else, so empty_recycle_bin never takes a folder that is not the
// bin.
@(private)
drive_letter :: proc(path: string) -> (letter: u16, ok: bool) {
	p := strings.trim_space(path)
	if len(p) < 2 || p[1] != ':' {
		return 0, false
	}
	switch p[0] {
	case 'A' ..= 'Z':
		letter = u16(p[0])
	case 'a' ..= 'z':
		letter = u16(p[0] - ('a' - 'A'))
	case:
		return 0, false
	}
	rest := strings.trim_left(strings.trim_right(p[2:], `\/`), `\/`)
	if rest == "" {
		return letter, true
	}
	dir := reclaim.RECYCLE_DIR if len(rest) >= len(reclaim.RECYCLE_DIR) else ""
	if dir == "" || !recycle_dir_at(rest) {
		return 0, false
	}
	return letter, true
}

@(private)
recycle_dir_at :: proc(rest: string) -> bool {
	if len(rest) < len(reclaim.RECYCLE_DIR) {
		return false
	}
	a, b := rest[:len(reclaim.RECYCLE_DIR)], reclaim.RECYCLE_DIR
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca == '/' {
			ca = '\\'
		}
		if ca != cb {
			return false
		}
	}
	if len(rest) == len(reclaim.RECYCLE_DIR) {
		return true
	}
	return rest[len(reclaim.RECYCLE_DIR)] == '\\' || rest[len(reclaim.RECYCLE_DIR)] == '/'
}
