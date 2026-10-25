#+build darwin
package walk

import "core:c"
import "core:encoding/endian"
import "core:mem"
import "core:strings"
import "core:sys/posix"

import "../scan"

foreign import libc "system:System"

/*
Read one directory with getattrlistbulk, which describes a batch of entries per call.

core:os reads the names with readdir and then calls fstatat on each entry
(core/os/dir_posix.odin), and its File_Info carries only the length, so the on-disk
figure had to be guessed from it. getattrlistbulk hands back each entry's name, type
and allocated size together, as many as fit in the buffer, so a directory costs
one call per buffer rather than one per entry. getattrlist(2) defines the allocated
size as the bytes on disk used by all of the file's forks, so a sparse disk image or a
compressed file is charged what it occupies, not its length.
*/
@(private)
read_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	path: Path
	fd, open_errno := open_listed(d, w, &path)
	if open_errno != .NONE {
		mark_unread(w, d.index, denied_errno(open_errno))
		return 0, 0, false
	}
	defer {posix.close(fd)}

	// Following links, the directories on the way down are kept, as on Linux
	// (follow_link in mounts_linux.odin) and Windows, and a directory already
	// among them is a loop of links: the link that led here stays the link it
	// is, unread.
	below: ^Ancestor
	if w.follow {
		st: posix.stat_t
		if posix.fstat(fd, &st) == .OK {
			id := File_Id{device = u64(st.st_dev), inode = u64(st.st_ino)}
			if on_path(d.ancestors, id) {
				return 0, 0, true
			}
			below = push(w, id, d.ancestors, ancestry(w)) or_return
		}
	}

	request := Attr_List {
		bitmapcount = ATTR_BIT_MAP_COUNT,
		dirattr     = ATTR_DIR_MOUNTSTATUS,
		fileattr    = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH | ATTR_FILE_DATAALLOCSIZE,
		forkattr    = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_REALDEVID,
	}
	request.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME
	request.commonattr |= ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID
	// The same size the Linux reader gives getdents, for the same reason: most
	// directories come back in one call.
	buf: [32 * mem.Kilobyte]u8
	options := u64(FSOPT_ATTR_CMN_EXTENDED)
	first := true
	for {
		count := getattrlistbulk(c.int(fd), &request, raw_data(buf[:]), len(buf), options)
		// Unsupported extended requests get one plain retry on
		// a new descriptor, never a replay after any entries have been read.
		if count < 0 &&
		   first &&
		   options != 0 &&
		   (posix.errno() == .EINVAL || posix.errno() == .ENOTSUP) {
			posix.close(fd)
			// Reopened as the first open was, so the retry keeps its refusal of links.
			fd, open_errno = open_listed(d, w, &path)
			if open_errno != .NONE {
				mark_unread(w, d.index, denied_errno(open_errno))
				return nodes, bytes, false
			}
			request.forkattr = 0
			options = 0
			continue
		}
		first = false
		if count < 0 {
			mark_unread(w, d.index, denied_errno(posix.errno()))
			return nodes, bytes, false
		}
		if count == 0 {
			break
		}
		at := 0
		for _ in 0 ..< count {
			e, length, parsed := parse_entry(buf[at:])
			if !parsed {
				mark_unread(w, d.index, false)
				return nodes, bytes, false
			}
			at += length
			if e.darwin.failed {
				mark_unread(w, d.index, false)
			}
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
				append(&w.found, Dir{index = index, path = child, ancestors = below})
			}
			nodes += 1
			bytes += charged
		}
	}

	// After the children are queued and before any of them is opened.
	if w.after_list != nil {
		w.after_list(d.path, w.after_list_data)
	}
	return nodes, bytes, true
}

/*
The root a walk that is not following links keeps open for the whole walk, as the
Linux reader keeps one.

`fd` is the directory opened from the path the caller named, following any link in
it: the caller chose that path. `root` is that path, so a child's path can be turned
back into a path relative to `fd`. Shared by every worker.
*/
@(private)
Anchor :: struct {
	fd:        posix.FD, // -1 when the walk is not anchored
	root:      string, // owned; empty when fd < 0
	errno:     posix.Errno, // why the root did not open; NONE when fd >= 0
	allocator: mem.Allocator,
}

@(private)
anchor_prepare :: proc(
	path: string,
	follow: bool,
	allocator: mem.Allocator,
) -> (
	a: Anchor,
	err: mem.Allocator_Error,
) {
	a.fd = -1
	a.allocator = allocator
	if follow {
		return a, nil
	}
	buf: Path
	fd, errno := open_pieces(posix.AT_FDCWD, path, {.DIRECTORY, .CLOEXEC}, &buf)
	if errno != .NONE {
		a.errno = errno
		return a, nil
	}
	root, clone_err := strings.clone(path, allocator)
	if clone_err != nil {
		posix.close(fd)
		return a, clone_err
	}
	a.fd = fd
	a.root = root
	return a, nil
}

@(private)
anchor_release :: proc(a: ^Anchor) {
	if a.fd >= 0 {
		posix.close(a.fd)
		a.fd = -1
	}
	delete(a.root, a.allocator)
	a.root = ""
}

// O_NOFOLLOW_ANY from <sys/fcntl.h>, macOS 11 and later: the open fails with ELOOP
// if any component of the path it resolves is a symbolic link.
@(private = "file")
O_NOFOLLOW_ANY :: 0x20000000

/*
The directory `d` for listing.

When the walk holds an anchor, every directory is opened relative to that
descriptor with O_NOFOLLOW_ANY, so a directory or an ancestor below the root that
was replaced by a symbolic link since it was listed is refused, not followed. When
it does not, and the caller asked to follow links, the path is opened as given.
When it does not and the caller did not, the open is refused.
*/
@(private = "file")
open_listed :: proc(d: Dir, w: ^Worker, buf: ^Path) -> (posix.FD, posix.Errno) {
	if w.held.fd >= 0 {
		rel, rel_ok := rel_under(w.held.root, d.path)
		if !rel_ok {
			return -1, .ENOENT
		}
		if rel == "" {
			rel = "."
		}
		// A listing never names "..", which would climb out of the root.
		if climbs(rel) {
			return -1, .EXDEV
		}
		flags := posix.O_Flags{.DIRECTORY, .CLOEXEC} | transmute(posix.O_Flags)c.int(O_NOFOLLOW_ANY)
		return open_pieces(w.held.fd, rel, flags, buf)
	}
	if !w.follow {
		if w.held.errno != .NONE {
			return -1, w.held.errno
		}
		return -1, .ENOENT
	}
	return open_pieces(posix.AT_FDCWD, d.path, {.DIRECTORY, .CLOEXEC}, buf)
}

/*
`path` opened from `dir` with `flags`: in one call when it is shorter than
PATH_MAX (1024 bytes, sys/syslimits.h; open(2) refuses a longer path with
ENAMETOOLONG), and otherwise a piece at a time, each piece from the descriptor the
one before it opened (next_piece). Each piece is opened with the same flags, so with
O_NOFOLLOW_ANY the chain refuses a link in any piece, as the single call would.
Only a directory past PATH_MAX takes more than one call; a path n times PATH_MAX
costs n + 1 opens. test_a_directory_deeper_than_path_max_is_read reads a tree 6,000
bytes deep.
*/
@(private = "file")
open_pieces :: proc(dir: posix.FD, path: string, flags: posix.O_Flags, buf: ^Path) -> (posix.FD, posix.Errno) {
	at := dir
	owned := false
	rest := path
	for {
		piece, after, ok := next_piece(rest, int(posix.PATH_MAX))
		if !ok {
			if owned {
				posix.close(at)
			}
			return -1, .ENAMETOOLONG
		}
		cpiece, _ := terminate(piece, buf)
		fd := posix.openat(at, cpiece, flags)
		errno := posix.errno() if fd < 0 else .NONE
		if owned {
			posix.close(at)
		}
		if fd < 0 {
			return -1, errno
		}
		if after == "" {
			return fd, .NONE
		}
		at, owned, rest = fd, true, after
	}
}

// Whether a relative path has a ".." component.
@(private = "file")
climbs :: proc(rel: string) -> bool {
	rest := rel
	for part in strings.split_iterator(&rest, "/") {
		if part == ".." {
			return true
		}
	}
	return false
}

/*
One entry from the front of a getattrlistbulk buffer, and how far to step to the next.

An entry is its length, the set of attributes actually returned, then each returned
attribute in the order getattrlistbulk(2) lays them out: the error, then the rest of
the common attributes by bit value, then the directory attributes, then the file
attributes by bit value. Only what was returned is present, and a directory returns no
file attributes nor a file any directory ones, so each is read only if its bit is set.
The name is a view into `buf`, which the next call overwrites.

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
		e.darwin.failed = (take_u32(&r) or_return) != 0
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
	if returned.dirattr & ATTR_DIR_MOUNTSTATUS != 0 {
		e.mount = (take_u32(&r) or_return) & DIR_MNTSTATUS_MNTPOINT != 0
	}
	// Without both halves of the id there is no telling one file's names apart from
	// another's, so the entry is charged as though it had one name.
	// e.account stays empty. Darwin facts are published once by card 48.
	if returned.fileattr & ATTR_FILE_LINKCOUNT != 0 {
		links := take_u32(&r) or_return
		if returned.commonattr & (ATTR_CMN_DEVID | ATTR_CMN_FILEID) ==
		   ATTR_CMN_DEVID | ATTR_CMN_FILEID {
			e.links = links
			e.darwin.account.links = links
			e.darwin.account.known += {.Links}
		}
	}
	if returned.fileattr & ATTR_FILE_ALLOCSIZE != 0 {
		v := i64(take_u64(&r) or_return)
		if v >= 0 {
			e.disk = u64(v)
			e.darwin.account.allocated = u64(v)
			e.darwin.account.known += {.Allocated}
		}
	}
	if returned.fileattr & ATTR_FILE_DATALENGTH != 0 {
		v := i64(take_u64(&r) or_return)
		if v >= 0 {
			e.darwin.account.logical = u64(v)
			e.darwin.account.known += {.Logical}
		}
	}
	if returned.fileattr & ATTR_FILE_DATAALLOCSIZE != 0 {
		v := i64(take_u64(&r) or_return)
		if v >= 0 {
			e.darwin.data_allocated = u64(v)
			e.darwin.data_known = true
		}
	}
	// Extended common attributes follow the file attributes, in bit order,
	// at four-byte alignment. Read only bits the kernel actually returned.
	if returned.forkattr & ATTR_CMNEXT_PRIVATESIZE != 0 {
		v := i64(take_u64(&r) or_return)
		if v >= 0 {
			e.darwin.account.exclusive = u64(v)
			e.darwin.account.known += {.Exclusive}
		}
	}
	if returned.forkattr & ATTR_CMNEXT_REALDEVID != 0 {
		e.darwin.device = u64(take_u32(&r) or_return)
		e.darwin.device_known = true
	}
	if returned.forkattr & ATTR_CMNEXT_CLONEID != 0 {
		e.darwin.clone = take_u64(&r) or_return
	}
	if e.darwin.failed {
		e.darwin.account = {}
		e.darwin.data_known = false
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
	if r.buf[start + length - 1] != 0 {
		return "", false
	}
	return string(r.buf[start:][:length - 1]), true
}

// Whether an errno says permission was what a directory lacked.
@(private)
denied_errno :: proc(errno: posix.Errno) -> bool {
	return errno == .EACCES || errno == .EPERM
}

// Scratch is what a worker keeps between directories. The buffer a batch lands
// in lives on the stack.
@(private)
Scratch :: struct {
	// The chains of directories a walk that follows links keeps (Ancestor),
	// which a directory queued by this worker may be read with by another.
	ancestry: mem.Dynamic_Arena,
}

@(private)
scratch_make :: proc(allocator: mem.Allocator) -> Scratch {
	s: Scratch
	// Takes no memory until the first Ancestor, which only a walk that follows
	// links makes.
	mem.dynamic_arena_init(&s.ancestry, allocator, allocator)
	return s
}

@(private)
scratch_destroy :: proc(s: ^Scratch) {
	mem.dynamic_arena_destroy(&s.ancestry)
}

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
ATTR_CMN_RETURNED_ATTRS :: 0x80000000
@(private)
ATTR_FILE_LINKCOUNT :: 0x00000001
@(private)
ATTR_DIR_MOUNTSTATUS :: 0x00000004
@(private)
DIR_MNTSTATUS_MNTPOINT :: 0x00000001
ATTR_FILE_ALLOCSIZE :: 0x00000004

// enum vtype from <sys/vnode.h>, the values ATTR_CMN_OBJTYPE takes.
@(private)
VDIR :: 2
@(private)
VLNK :: 5

@(private = "file", default_calling_convention = "c")
foreign libc {
	getattrlistbulk :: proc(fd: c.int, al: ^Attr_List, buf: rawptr, n: uint, opt: u64) -> c.int ---
}

// Extended-attribute bits from Apple's xnu bsd/sys/attr.h:
// https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/attr.h
// The returned types are described in getattrlist(2). REALDEVID scopes clone
// keys to the device reported for each filesystem object.
@(private)
ATTR_FILE_DATALENGTH :: 0x00000200
ATTR_FILE_DATAALLOCSIZE :: 0x00000400
@(private)
ATTR_CMNEXT_PRIVATESIZE :: 0x00000008
@(private)
ATTR_CMNEXT_REALDEVID :: 0x00000040
ATTR_CMNEXT_CLONEID :: 0x00000100
FSOPT_ATTR_CMN_EXTENDED :: 0x00000020

@(private)
Darwin_Measurement :: struct {
	account:                          scan.Account,
	data_allocated, device, clone:    u64,
	data_known, device_known, failed: bool,
}

@(private)
charge_darwin :: proc(w: ^Worker, e: ^Entry) -> bool {
	m := &e.darwin
	if e.directory ||
	   e.symlink ||
	   e.extra ||
	   !m.data_known ||
	   !m.device_known ||
	   .Allocated not_in m.account.known ||
	   .Logical not_in m.account.known {
		return true
	}
	charge, shared, ok := charge_clone(
		w.clones,
		{m.device, m.clone},
		{m.data_allocated, m.account.logical},
		e.disk,
	)
	if !ok {
		w.err = .Out_Of_Memory
		return false
	}
	e.disk = charge
	e.shared = shared
	if shared {
		scan.mark_scan_order(w.writer.tree)
	}
	return true
}

@(private)
record_darwin_account :: proc(w: ^Worker, index: u32, e: Entry) -> bool {
	if e.directory || e.symlink || e.darwin.account.known == {} {
		return true
	}
	// Private allocation is a measurement, not a promise of free volume bytes.
	// No conversion to Reclaim, even when snapshot enumeration found none.
	if !scan.account_set(w.writer.tree, index, e.darwin.account) {
		w.err = .Out_Of_Memory
		return false
	}
	return true
}
