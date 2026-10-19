#+build windows
package leita_files

import "core:strings"
import win32 "core:sys/windows"

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
SHQUERYRBINFO :: struct {
	cbSize:      win32.DWORD,
	i64Size:     i64,
	i64NumItems: i64,
}

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
recycle_bins are the Recycle Bins the shell can see on this machine, one per
volume that answers, with this user's folder as path. A volume the shell will
not query is left out. Volume and path are in allocator.
*/
recycle_bins :: proc(sid: string, allocator := context.allocator) -> []Recycle_Bin {
	if sid == "" {
		return nil
	}
	mask := GetLogicalDrives()
	out := make([dynamic]Recycle_Bin, allocator)
	for i in 0 ..< 26 {
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
		info := SHQUERYRBINFO {
			cbSize = size_of(SHQUERYRBINFO),
		}
		if !win32.SUCCEEDED(SHQueryRecycleBinW(cstring16(&root[0]), &info)) {
			continue
		}
		vol := strings.clone(string([]u8{u8(letter), ':', '\\'}), allocator)
		append(
			&out,
			Recycle_Bin {
				volume = vol,
				path = strings.concatenate({vol, reclaim.RECYCLE_DIR, `\`, sid}, allocator),
				bytes = u64(max(info.i64Size, 0)),
				items = u64(max(info.i64NumItems, 0)),
			},
		)
	}
	return out[:]
}

// recycle_bin_info is what the Recycle Bin on root holds, as the shell reports
// it. root must be a volume `C:\`; anything else returns not-ok and the shell
// is not called.
recycle_bin_info :: proc(root: string) -> (bytes, items: u64, ok: bool) {
	letter, has := drive_letter(root)
	if !has {
		return 0, 0, false
	}
	wide := [4]u16{letter, ':', '\\', 0}
	info := SHQUERYRBINFO {
		cbSize = size_of(SHQUERYRBINFO),
	}
	if !win32.SUCCEEDED(SHQueryRecycleBinW(cstring16(&wide[0]), &info)) {
		return 0, 0, false
	}
	return u64(max(info.i64Size, 0)), u64(max(info.i64NumItems, 0)), true
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
