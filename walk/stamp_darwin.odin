#+build darwin
package walk

import "core:c"
import "core:sys/posix"

foreign import libc "system:System"

// FSEvents is macOS's change journal, so a probe here says every directory changed,
// and the update reads them all, as a walk would.
@(private)
changed_since :: proc(path: string, since: i64) -> bool {
	return true
}

// Whether an update asks a copied file its size again, with disk_of.
@(private)
RESTATS :: true

/*
What the file at `path` holds on disk now, asked as read_dir asks it: the allocated
size of all its forks, the link itself for a symlink. Gone only when getattrlist
says there is no such file (ENOENT, ENOTDIR), and then dropped, as a read would not
find it either; any other failure is Unknown, and the size copied stands.
*/
@(private)
disk_of :: proc(path: string) -> (disk: u64, verdict: Verdict) {
	buf: Path
	cpath, terminated := terminate(path, &buf)
	if !terminated {
		return 0, .Unknown
	}
	request := Attr_List {
		bitmapcount = ATTR_BIT_MAP_COUNT,
		fileattr    = ATTR_FILE_ALLOCSIZE,
	}
	// A u32 length, then the off_t, packed at four-byte alignment (getattrlist(2)).
	reply: struct #packed {
		length:    u32,
		allocated: i64,
	}
	if getattrlist(cpath, &request, &reply, size_of(reply), FSOPT_NOFOLLOW) != 0 {
		#partial switch posix.errno() {
		case .ENOENT, .ENOTDIR:
			return 0, .Gone
		}
		return 0, .Unknown
	}
	if reply.length < size_of(reply) {
		return 0, .Unknown
	}
	return u64(max(reply.allocated, 0)), .Sized
}

@(private = "file")
FSOPT_NOFOLLOW :: 0x00000001

@(private = "file", default_calling_convention = "c")
foreign libc {
	getattrlist :: proc(path: cstring, al: ^Attr_List, buf: rawptr, n: uint, opt: c.uint) -> c.int ---
}

/*
Whether `path` still names the file `id`: false only when lstat finds nothing there
(ENOENT, ENOTDIR) or another file, so a name that cannot be asked is believed. The
device is compared as parse_entry takes ATTR_CMN_DEVID, a dev_t read as a u32 in
read_darwin.odin.
*/
@(private)
still_names :: proc(path: string, id: File_Id) -> bool {
	buf: Path
	cpath, terminated := terminate(path, &buf)
	if !terminated {
		return true
	}
	st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK {
		#partial switch posix.errno() {
		case .ENOENT, .ENOTDIR:
			return false
		}
		return true
	}
	return u64(u32(st.st_dev)) == id.device && u64(st.st_ino) == id.inode
}
