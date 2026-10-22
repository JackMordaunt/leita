#+build linux
package btrfs

import "core:mem"
import "core:strings"
import "core:sys/linux"

import "../kstat"

/*
Measure every regular file under path, a file or a directory, into u, as compsize
does without -x (do_recursive_search in compsize.c, kilobyte/compsize at d79eacf, opens each entry O_NOFOLLOW and
never compares devices): directories are followed onto other subvolumes, a
snapshot among them, and symlinks are not. visit, when given, sees each file once
it is measured.
*/
measure :: proc(path: string, u: ^Usage, visit: Visit = nil, data: rawptr = nil) -> Error {
	cpath, cpath_err := strings.clone_to_cstring(path)
	if cpath_err != nil {
		return .Out_Of_Memory
	}
	defer delete(cpath)
	// One search buffer for the whole walk: it is 64 KiB, too much to take per file.
	m := Measure {
		u     = u,
		visit = visit,
		data  = data,
	}
	m.args = new(Search_Args)
	if m.args == nil {
		return .Out_Of_Memory
	}
	defer free(m.args)
	m.path = strings.builder_make()
	defer strings.builder_destroy(&m.path)
	strings.write_string(&m.path, path)
	fd, errno := linux.open(cpath, {.NOFOLLOW, .NONBLOCK, .CLOEXEC})
	if errno != .NONE {
		return .Not_Found
	}
	return measure_fd(&m, fd)
}

// What one call of measure carries down the tree: the path so far and the buffer
// every search reuses.
@(private)
Measure :: struct {
	u:     ^Usage,
	visit: Visit,
	data:  rawptr,
	path:  strings.Builder,
	args:  ^Search_Args,
}

// Measure what fd is, and beneath it if a directory, then close it. m.path holds its
// path.
@(private)
measure_fd :: proc(m: ^Measure, fd: linux.Fd) -> Error {
	defer linux.close(fd)
	st: linux.Statx
	if kstat.statx(fd, "", {.EMPTY_PATH}, {.TYPE, .INO, .BLOCKS}, &st) != .NONE {
		return .Io
	}
	if linux.S_ISREG(st.mode) {
		f: File
		defer file_destroy(&f)
		if err := search(fd, u64(st.ino), m.args, m.u, &f); err != .None {
			return err
		}
		m.u.files += 1
		m.u.blocks += st.blocks * 512
		if m.visit != nil {
			m.visit(strings.to_string(m.path), &f, st.blocks * 512, m.data)
		}
		return .None
	}
	if !linux.S_ISDIR(st.mode) {
		return .None
	}
	buf: [32 * mem.Kilobyte]u8
	for {
		n, errno := linux.getdents(fd, buf[:])
		if errno != .NONE {
			return .Io
		}
		if n == 0 {
			return .None
		}
		offset := 0
		for entry in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(entry)
			if name == "." || name == ".." {
				continue
			}
			if entry.type != .DIR && entry.type != .REG && entry.type != .UNKNOWN {
				continue
			}
			// A name is at most 255 bytes (NAME_MAX), so it is terminated in place
			// rather than copied to the heap for every entry of the walk.
			cname: [256]u8
			copy(cname[:255], name)
			child, open_errno := linux.openat(
				fd,
				cstring(&cname[0]),
				{.NOFOLLOW, .NONBLOCK, .CLOEXEC},
			)
			if open_errno != .NONE {
				// Gone since it was listed, or not ours to read.
				continue
			}
			mark := strings.builder_len(m.path)
			strings.write_byte(&m.path, '/')
			strings.write_string(&m.path, name)
			err := measure_fd(m, child)
			resize(&m.path.buf, mark)
			if err != .None {
				return err
			}
		}
	}
}

/*
Every file extent item of one inode, from the subvolume fd lies in, charged to f
and u.
*/
@(private)
search :: proc(fd: linux.Fd, ino: u64, args: ^Search_Args, u: ^Usage, f: ^File) -> Error {
	it := Items {
		fd   = fd,
		ino  = ino,
		args = args,
	}
	for {
		item, ok, err := next_item(&it)
		if !ok {
			return err
		}
		if charge(item, u, f) != .None {
			return .Malformed
		}
	}
}

/*
Charge one regular file to a pool's Extents: every file extent item of inode `ino`
in the subvolume `fd` lies in. fd need not be the file's own: any file or directory
of the same subvolume searches the same tree, so a walk can pass the directory it is
listing and open nothing per file. args is the caller's, reused from file to file.

Not_Permitted without CAP_SYS_ADMIN and Not_Btrfs off btrfs, before anything is
claimed. A search that fails part way leaves what it claimed paid for by this file,
though the caller then charges it something else.
*/
charge_file :: proc(
	fd: linux.Fd,
	ino: u64,
	args: ^Search_Args,
	e: ^Extents,
	owner: u64,
) -> (
	c: Charge,
	err: Error,
) {
	it := Items {
		fd   = fd,
		ino  = ino,
		args = args,
	}
	for {
		item, ok, next_err := next_item(&it)
		if !ok {
			return c, next_err
		}
		#partial switch charge_shared(item, e, owner, &c) {
		case .None:
		case .Out_Of_Memory:
			return c, .Out_Of_Memory
		case:
			return c, .Malformed
		}
	}
}

/*
The file extent items of one inode, a buffer at a time. The kernel fills the buffer
with as many items as fit; the next call starts past the last one's offset, until a
call finds none.
*/
@(private)
Items :: struct {
	fd:   linux.Fd,
	ino:  u64,
	args: ^Search_Args,
	next: u64, // the offset the next call starts at
	rest: []u8, // what the last call returned that is not yet handed out
	left: u32, // items in rest
	done: bool, // the last call reached the end
}

// The next file extent item, or ok clear once there are none, err saying whether
// that is the end or a failure.
@(private)
next_item :: proc(it: ^Items) -> (item: []u8, ok: bool, err: Error) {
	for {
		for it.left > 0 {
			it.left -= 1
			if len(it.rest) < size_of(Search_Header) {
				return nil, false, .Malformed
			}
			h := (^Search_Header)(raw_data(it.rest))^
			it.rest = it.rest[size_of(Search_Header):]
			if int(h.len) > len(it.rest) {
				return nil, false, .Malformed
			}
			body := it.rest[:h.len]
			it.rest = it.rest[h.len:]
			if it.left == 0 {
				if h.offset == max(u64) {
					it.done = true
				}
				it.next = h.offset + 1
			}
			if h.type == BTRFS_EXTENT_DATA_KEY {
				return body, true, .None
			}
		}
		if it.done {
			return nil, false, .None
		}
		args := it.args
		args.key = {
			tree_id      = 0,
			min_objectid = it.ino,
			max_objectid = it.ino,
			min_offset   = it.next,
			max_offset   = max(u64),
			min_transid  = 0,
			max_transid  = max(u64),
			min_type     = BTRFS_EXTENT_DATA_KEY,
			max_type     = BTRFS_EXTENT_DATA_KEY,
			nr_items     = max(u32),
		}
		args.buf_size = size_of(args.buf)
		got := int(linux.ioctl(it.fd, BTRFS_IOC_TREE_SEARCH_V2, uintptr(args)))
		if got < 0 {
			#partial switch linux.Errno(-got) {
			case .EPERM, .EACCES:
				return nil, false, .Not_Permitted
			case .ENOTTY, .EINVAL, .EOPNOTSUPP:
				return nil, false, .Not_Btrfs
			}
			return nil, false, .Io
		}
		if args.key.nr_items == 0 {
			return nil, false, .None
		}
		it.left = args.key.nr_items
		it.rest = args.buf[:]
	}
}

// From linux/btrfs.h and btrfs_tree.h: _IOWR(0x94, 17, struct
// btrfs_ioctl_search_args_v2), which the kernel refuses without CAP_SYS_ADMIN, and
// the key type of a file extent item.
@(private)
BTRFS_IOC_TREE_SEARCH_V2 :: 0xc0709411
@(private)
BTRFS_EXTENT_DATA_KEY :: 108

// struct btrfs_ioctl_search_key, 104 bytes.
@(private)
Search_Key :: struct {
	tree_id:      u64,
	min_objectid: u64,
	max_objectid: u64,
	min_offset:   u64,
	max_offset:   u64,
	min_transid:  u64,
	max_transid:  u64,
	min_type:     u32,
	max_type:     u32,
	nr_items:     u32,
	_:            u32,
	_:            [4]u64,
}
#assert(size_of(Search_Key) == 104)

// struct btrfs_ioctl_search_args_v2 with a 64 KiB buffer, room for 771 regular
// extents a call: each is a 32 byte Search_Header and a 53 byte
// struct btrfs_file_extent_item (ITEM_SIZE, from linux/btrfs_tree.h). The ioctl's size names only the fixed part.
Search_Args :: struct {
	key:      Search_Key,
	buf_size: u64,
	buf:      [64 * mem.Kilobyte]u8,
}

// struct btrfs_ioctl_search_header, 32 bytes, before each item in the buffer.
@(private)
Search_Header :: struct #packed {
	transid:  u64,
	objectid: u64,
	offset:   u64,
	type:     u32,
	len:      u32,
}
#assert(size_of(Search_Header) == 32)
