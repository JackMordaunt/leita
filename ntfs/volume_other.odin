#+build !windows
package ntfs

import "core:io"
import "core:mem"
import "core:os"
import "core:strings"

/*
Read-only handle to a volume: a block device such as /dev/nvme0n1p3, or a file
holding an image of one.

The path and mode are kept so `volume_clone` can open another handle to the same
place. Reads are positional and carry their own offset, so handles never contend over
one; a handle each still keeps a worker's lifetime and errors its own.

Reads pass through the page cache. Bypassing it would need O_DIRECT here and
F_NOCACHE on Darwin, and sweeping the Windows equivalent found the two
indistinguishable at about 1.9 GB/s, so the mode is carried for a clone to match
rather than acted on.
*/
Volume :: struct {
	file:      ^os.File,
	name:      string, // device or image path, owned
	mode:      IO_Mode,
	allocator: mem.Allocator,
}

/*
Open a volume or an image by path.

Reading a block device is a matter of permissions on the device rather than of
privilege as it is on Windows: membership of the group owning it is what grants it,
and a group added to a live session only takes effect on the next login.
*/
volume_open :: proc(path: string, mode := IO_Mode.Unbuffered, allocator := context.allocator) -> (v: Volume, err: Error) {
	f, open_err := os.open(path, {.Read})
	if open_err != nil {
		if open_err == io.Error.Permission_Denied {
			return {}, .Access_Denied
		}
		return {}, .Open_Failed
	}
	name, clone_err := strings.clone(path, allocator)
	if clone_err != nil {
		os.close(f)
		return {}, .Out_Of_Memory
	}
	return Volume{file = f, name = name, mode = mode, allocator = allocator}, .None
}

// Another handle to the same volume, for a thread that reads independently.
volume_clone :: proc(v: ^Volume, allocator := context.allocator) -> (Volume, Error) {
	return volume_open(v.name, v.mode, allocator)
}

volume_close :: proc(v: ^Volume) {
	if v.file != nil {
		os.close(v.file)
	}
	if v.name != "" {
		delete(v.name, v.allocator)
	}
	v^ = {}
}

// Fill `buf` from `offset`. One positional read is capped by the kernel and stops
// short of a large buffer, so this repeats until the buffer is full or the volume
// ends under it.
volume_read_at :: proc(v: ^Volume, buf: []byte, offset: u64) -> Error {
	done := 0
	for done < len(buf) {
		n, read_err := os.read_at(v.file, buf[done:], i64(offset) + i64(done))
		if read_err != nil {
			if read_err == io.Error.EOF {
				return .Short_Read
			}
			return .Read_Failed
		}
		if n == 0 {
			return .Short_Read
		}
		done += n
	}
	return .None
}
