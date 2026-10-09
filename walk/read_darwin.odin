#+build darwin
package walk

import "core:c"
import "core:encoding/endian"
import "core:mem"
import "core:sys/posix"

foreign import libc "system:System"

/*
Read one directory with getattrlistbulk, which describes a batch of entries per call.

core:os reads the names with readdir and then calls fstatat on each entry
(core/os/dir_posix.odin), and its File_Info carries only the length, so the on-disk
figure had to be guessed from it. getattrlistbulk hands back each entry's name, type,
length and allocated size together, as many as fit in the buffer, so a directory costs
one call per buffer rather than one per entry. getattrlist(2) defines the allocated
size as the bytes on disk used by all of the file's forks, so a sparse disk image or a
compressed file is charged what it occupies, not its length.
*/
@(private)
read_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	path: Path
	cpath, path_ok := terminate(d.path, &path)
	if !path_ok {
		return 0, 0, false
	}
	// Not NOFOLLOW, for the reason the Linux reader gives: the queue holds symlinks
	// only when the caller asked for them to be followed.
	fd := posix.open(cpath, {.DIRECTORY, .CLOEXEC})
	if fd < 0 {
		return 0, 0, false
	}
	defer posix.close(fd)

	request := Attr_List {
		bitmapcount = ATTR_BIT_MAP_COUNT,
		fileattr    = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH,
	}
	request.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME
	request.commonattr |= ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID
	// The same size the Linux reader gives getdents, for the same reason: most
	// directories come back in one call.
	buf: [32 * mem.Kilobyte]u8
	for {
		count := getattrlistbulk(c.int(fd), &request, raw_data(buf[:]), len(buf), 0)
		if count < 0 {
			return nodes, bytes, false
		}
		if count == 0 {
			break
		}
		at := 0
		for _ in 0 ..< count {
			e, length, parsed := parse_entry(buf[at:])
			if !parsed {
				return nodes, bytes, false
			}
			at += length
			index, descend, charged, recorded := record(w, d.index, e)
			if !recorded {
				return nodes, bytes, false
			}
			if descend {
				child, join_err := join(d.path, e.name, w.allocator)
				if join_err != nil {
					w.err = .Out_Of_Memory
					return nodes, bytes, false
				}
				append(&w.found, Dir{index = index, path = child})
			}
			nodes += 1
			bytes += charged
		}
	}
	return nodes, bytes, true
}

/*
One entry from the front of a getattrlistbulk buffer, and how far to step to the next.

An entry is its length, the set of attributes actually returned, then each returned
attribute in the order getattrlistbulk(2) lays them out: the error, then the rest of
the common attributes by bit value, then the file attributes by bit value. Only what
was returned is present, and a directory returns no file attributes, so each is read
only if its bit is set. The name is a view into `buf`, which the next call overwrites.

Not ok if the entry claims more than the buffer holds; reading past the batch would
describe garbage as a file.
*/
@(private)
parse_entry :: proc(buf: []u8) -> (e: Entry, length: int, ok: bool) {
	whole := endian.get_u32(buf, .Little) or_return
	length = int(whole)
	if length < size_of(u32) + size_of(Attribute_Set) || length > len(buf) {
		return {}, 0, false
	}
	r := Entry_Reader {
		buf = buf[:length],
		at  = size_of(u32),
	}
	returned: Attribute_Set
	returned.commonattr = take_u32(&r) or_return
	returned.volattr = take_u32(&r) or_return
	returned.dirattr = take_u32(&r) or_return
	returned.fileattr = take_u32(&r) or_return
	returned.forkattr = take_u32(&r) or_return

	// An entry the kernel could not describe still names itself; it is recorded
	// with what was returned, as the Linux reader records one statx refused.
	if returned.commonattr & ATTR_CMN_ERROR != 0 {
		take_u32(&r) or_return
	}
	if returned.commonattr & ATTR_CMN_NAME == 0 {
		return {}, 0, false
	}
	e.name = take_name(&r) or_return
	if returned.commonattr & ATTR_CMN_DEVID != 0 {
		e.id.device = u64(take_u32(&r) or_return)
	}
	if returned.commonattr & ATTR_CMN_OBJTYPE != 0 {
		switch take_u32(&r) or_return {
		case VDIR:
			e.directory = true
		case VLNK:
			e.symlink = true
		}
	}
	if returned.commonattr & ATTR_CMN_FILEID != 0 {
		e.id.inode = take_u64(&r) or_return
	}
	// Without both halves of the id there is no telling one file's names apart from
	// another's, so the entry is charged as though it had one name.
	if returned.fileattr & ATTR_FILE_LINKCOUNT != 0 {
		links := take_u32(&r) or_return
		if returned.commonattr & (ATTR_CMN_DEVID | ATTR_CMN_FILEID) ==
		   ATTR_CMN_DEVID | ATTR_CMN_FILEID {
			e.links = links
		}
	}
	if returned.fileattr & ATTR_FILE_ALLOCSIZE != 0 {
		e.disk = u64(max(i64(take_u64(&r) or_return), 0))
	}
	if returned.fileattr & ATTR_FILE_DATALENGTH != 0 {
		e.size = u64(max(i64(take_u64(&r) or_return), 0))
	}
	return e, length, true
}

// A cursor over one entry. Attributes are packed at four-byte alignment, so an
// off_t can sit anywhere a u32 can, and is read a byte at a time.
@(private = "file")
Entry_Reader :: struct {
	buf: []u8,
	at:  int,
}

@(private = "file")
take_u32 :: proc(r: ^Entry_Reader) -> (v: u32, ok: bool) {
	v = endian.get_u32(r.buf[min(r.at, len(r.buf)):], .Little) or_return
	r.at += size_of(u32)
	return v, true
}

@(private = "file")
take_u64 :: proc(r: ^Entry_Reader) -> (v: u64, ok: bool) {
	v = endian.get_u64(r.buf[min(r.at, len(r.buf)):], .Little) or_return
	r.at += size_of(u64)
	return v, true
}

// An attrreference_t: where the name lies, measured from the reference itself, and
// its length counting the terminating NUL.
@(private = "file")
take_name :: proc(r: ^Entry_Reader) -> (name: string, ok: bool) {
	from := r.at
	offset := i32(take_u32(r) or_return)
	length := int(take_u32(r) or_return)
	start := from + int(offset)
	if offset < 0 || length < 1 || start + length > len(r.buf) {
		return "", false
	}
	return string(r.buf[start:][:length - 1]), true
}

// Scratch is what a worker reuses between directories: nothing, since the buffer
// a batch lands in lives on the stack.
@(private)
Scratch :: struct {}

@(private)
scratch_make :: proc(allocator: mem.Allocator) -> Scratch {
	return {}
}

@(private)
scratch_destroy :: proc(s: ^Scratch) {}

// struct attrlist and attribute_set_t from <sys/attr.h>.
@(private)
Attr_List :: struct {
	bitmapcount: u16,
	reserved:    u16,
	commonattr:  u32,
	volattr:     u32,
	dirattr:     u32,
	fileattr:    u32,
	forkattr:    u32,
}
#assert(size_of(Attr_List) == 24)

@(private)
Attribute_Set :: struct {
	commonattr: u32,
	volattr:    u32,
	dirattr:    u32,
	fileattr:   u32,
	forkattr:   u32,
}

@(private)
ATTR_BIT_MAP_COUNT :: 5
@(private)
ATTR_CMN_NAME :: 0x00000001
@(private)
ATTR_CMN_DEVID :: 0x00000002
@(private)
ATTR_CMN_OBJTYPE :: 0x00000008
@(private)
ATTR_CMN_FILEID :: 0x02000000
@(private)
ATTR_CMN_ERROR :: 0x20000000
@(private)
ATTR_CMN_RETURNED_ATTRS :: 0x80000000
@(private)
ATTR_FILE_LINKCOUNT :: 0x00000001
@(private)
ATTR_FILE_ALLOCSIZE :: 0x00000004
@(private)
ATTR_FILE_DATALENGTH :: 0x00000200

// enum vtype from <sys/vnode.h>, the values ATTR_CMN_OBJTYPE takes.
@(private)
VDIR :: 2
@(private)
VLNK :: 5

@(private = "file", default_calling_convention = "c")
foreign libc {
	getattrlistbulk :: proc(fd: c.int, al: ^Attr_List, buf: rawptr, n: uint, opt: u64) -> c.int ---
}
