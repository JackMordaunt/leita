#+build windows
package ntfs

import "core:mem"
import "core:strings"
import win "core:sys/windows"

/*
Read-only handle to a raw volume (`\\.\C:`) or to an image file containing one.

The resolved name and mode are kept so `volume_clone` can open another handle to the
same place. Windows serialises I/O on a synchronous handle, so threads reading
concurrently need a handle each or they queue behind one another.
*/
Volume :: struct {
	handle:    win.HANDLE,
	name:      string, // device path, owned
	mode:      IO_Mode,
	allocator: mem.Allocator,
}

@(private)
ERROR_ACCESS_DENIED :: 5

/*
Open a volume by drive letter (`C`, `C:`, `C:\`) or an NTFS image by file path.

Volume handles bypass the file system, which is why they need administrator rights
and why every read must be a whole number of sectors at a sector-aligned offset.
FILE_SHARE_WRITE is required: the volume is mounted and in use, and opening it without
sharing writes would fail.
*/
volume_open :: proc(
	path: string,
	mode := IO_Mode.Unbuffered,
	allocator := context.allocator,
) -> (
	v: Volume,
	err: Error,
) {
	name := path
	if is_drive_spec(path) {
		name = strings.concatenate({`\\.\`, path[:1], ":"}, context.temp_allocator)
	}
	// FILE_FLAG_SEQUENTIAL_SCAN is a hint to the cache manager, so it means nothing
	// once the cache is out of the path.
	flags := win.FILE_FLAG_SEQUENTIAL_SCAN if mode == .Buffered else win.FILE_FLAG_NO_BUFFERING
	wname := win.utf8_to_wstring(name, context.temp_allocator)
	h := win.CreateFileW(
		wname,
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		flags,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		if win.GetLastError() == ERROR_ACCESS_DENIED {
			return {}, .Access_Denied
		}
		return {}, .Open_Failed
	}
	owned, clone_err := strings.clone(name, allocator)
	if clone_err != nil {
		win.CloseHandle(h)
		return {}, .Out_Of_Memory
	}
	return Volume{handle = h, name = owned, mode = mode, allocator = allocator}, .None
}

// Another handle to the same volume, for a thread that needs to read independently.
volume_clone :: proc(v: ^Volume, allocator := context.allocator) -> (Volume, Error) {
	return volume_open(v.name, v.mode, allocator)
}

volume_close :: proc(v: ^Volume) {
	if v.handle != nil && v.handle != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(v.handle)
	}
	if v.name != "" {
		delete(v.name, v.allocator)
	}
	v^ = {}
}

// Fill `buf` from `offset`. Both must be sector-aligned for a raw volume.
volume_read_at :: proc(v: ^Volume, buf: []byte, offset: u64) -> Error {
	done := 0
	for done < len(buf) {
		ov: win.OVERLAPPED
		ov.OffsetFull = offset + u64(done)
		chunk := min(len(buf) - done, 1 << 30)
		n: win.DWORD
		if !win.ReadFile(v.handle, raw_data(buf[done:]), win.DWORD(chunk), &n, &ov) {
			return .Read_Failed
		}
		if n == 0 {
			return .Short_Read
		}
		done += int(n)
	}
	return .None
}

@(private)
is_drive_spec :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 3 {
		return false
	}
	c := s[0]
	is_letter := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
	if !is_letter {
		return false
	}
	if len(s) >= 2 && s[1] != ':' {
		return false
	}
	if len(s) == 3 && s[2] != '\\' && s[2] != '/' {
		return false
	}
	return true
}
