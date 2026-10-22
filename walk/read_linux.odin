#+build linux
package walk

import "base:intrinsics"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"

import "../btrfs"
import "../kstat"
import "../scan"

/*
Read one directory with the calls the work actually needs.

core:os describes every entry in full: an fd opened and closed around it, a statx on
that fd, and the entry's path read back through /proc/self/fd. Four syscalls, where
one statx against the directory answers everything the tree records. Walking 14,478
entries cost 64,235 calls that way against du's 21,511 for the same tree, and the
procfs readlink was over half of it.

getdents also names each entry's type, so only a regular file is asked about again,
along with the rare entry whose filesystem left the type out. A directory and a
symlink are never charged, so their statx bought nothing but the syscall; on
~/Source, 86,466 of 639,221 statx calls (13.5%) were spent on directories that way
(2026-10-12). statx reports allocated blocks as readily as length, so the on-disk
figure stays exact for the entries still asked, rather than the length rounded up to
a guessed block: a sparse or compressed file is charged what it occupies.
*/
@(private)
read_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	path: Path
	fd, open_errno := open_listed(d, w, &path)
	if open_errno != .NONE {
		mark_unread(w, d.index, denied_errno(open_errno))
		return 0, 0, false
	}
	defer linux.close(fd)

	// The device and filesystem this directory lies on: handed down by the parent
	// that asked about it, or, for the root and a followed link, asked of the open
	// directory here.
	device, filesystem, on_btrfs := d.device, d.filesystem, d.btrfs
	if device == 0 {
		st: linux.Statx
		if statx_compat(fd, "", {.EMPTY_PATH}, {.MNT_ID}, &st) == .NONE {
			device = statx_device(st)
			// Said once a directory, not once an entry: a kernel that never gives a
			// mount id never gives it, and only a walk that reads a directory can have
			// been short of one.
			if .MNT_ID not_in st.mask {
				scan.mark_gap(w.writer.tree, .Mount_Id)
			}
		}
		if sync.atomic_load(&kstat.missing) {
			scan.mark_gap(w.writer.tree, .Statx)
			scan.mark_gap(w.writer.tree, .Mount_Id)
		}
		filesystem, on_btrfs = filesystem_of(fd)
	}
	// The directories this one lies under, kept only below a mount the walk entered
	// or while following links (mounts_linux.odin); nil on the path almost every
	// directory takes.
	above := d.ancestors
	if above == nil && w.follow {
		climbed, climbed_ok := climb(w, fd)
		if !climbed_ok {
			return 0, 0, false
		}
		above = climbed
	}
	// On btrfs, each regular file's extents are searched for through this
	// directory's fd (see btrfs_linux.odin); nil when the search is off.
	pool: ^Btrfs_Pool
	if on_btrfs || w.btrfs.stand_in {
		pool = btrfs_pool_for(w, filesystem)
	}

	// Every name first, then every statx in inode order (see Scratch).
	s := &w.scratch
	clear(&s.names)
	clear(&s.listed)
	// Sized so a directory of any ordinary size comes back in one call. core:os
	// starts at 512 bytes and grows only when the kernel refuses, which cost it
	// roughly twice the getdents calls for the same tree.
	buf: [32 * mem.Kilobyte]u8
	for {
		n, errno := linux.getdents(fd, buf[:])
		if errno != .NONE {
			mark_unread(w, d.index, denied_errno(errno))
			return 0, 0, false
		}
		if n == 0 {
			break
		}
		offset := 0
		for entry in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(entry)
			if name == "." || name == ".." {
				continue
			}
			// Kept terminated, so statx can be handed the name where it lies.
			at := len(s.names)
			if _, err := append(&s.names, name); err != nil {
				w.err = .Out_Of_Memory
				return 0, 0, false
			}
			if _, err := append(&s.names, 0); err != nil {
				w.err = .Out_Of_Memory
				return 0, 0, false
			}
			if _, err := append(&s.listed, Dirent{u64(entry.ino), at, len(name), entry.type});
			   err != nil {
				w.err = .Out_Of_Memory
				return 0, 0, false
			}
		}
	}
	slice.sort_by_key(s.listed[:], proc(l: Dirent) -> u64 {return l.ino})

	// One claim and one copy for the whole directory. Doing both per entry put a
	// shared counter and every worker's arena mutex on the profile: the arenas sit
	// side by side, so neighbours fought over one cache line (2026-10-12). The names
	// are already contiguous in the scratch buffer, separators included.
	count := len(s.listed)
	first: u32
	span: scan.Name_Span
	if count > 0 {
		claimed, claim_err := scan.claim(&w.writer, u32(count))
		if claim_err != nil {
			w.err = .Out_Of_Memory
			return 0, 0, false
		}
		copied, names_ok := scan.intern_span(&w.writer, s.names[:])
		if !names_ok {
			w.err = .Out_Of_Memory
			return 0, 0, false
		}
		first, span = claimed, copied
	}

	// Entries statx could not answer are left out, and the slots claimed for them
	// stay unused at the end of the run (as copy_dir leaves a file gone).
	kept: u32
	short, denied: bool
	for l in s.listed {
		name := string(s.names[l.at:][:l.len])
		e := Entry {
			name = name,
		}
		// Only a regular file can be charged anything, only an entry whose type
		// getdents left out (.UNKNOWN) needs asking what it even is, and only a
		// directory can be another filesystem's mount point. A symlink and the
		// other special types (FIFO, socket, device, whiteout) are none of these,
		// so record charges them nothing whether or not they are stat'd; skipping
		// the call for them changes no result, only the syscall count.
		//
		// NO_AUTOMOUNT, so asking about an automount point does not mount it
		// (AT_NO_AUTOMOUNT in statx(2)).
		index := first + kept
		child_device, child_filesystem, child_btrfs := device, filesystem, on_btrfs
		below := above
		follow := true
		asked := l.type == .REG || l.type == .UNKNOWN || l.type == .DIR
		st: linux.Statx
		errno := linux.Errno.NONE
		if asked {
			mask := linux.Statx_Mask{.TYPE, .BLOCKS, .NLINK}
			if l.type == .DIR {
				mask = {.TYPE, .INO, .MNT_ID}
			}
			flags := linux.FD_Flags{.SYMLINK_NOFOLLOW, .NO_AUTOMOUNT}
			errno = stat_entry(statx_compat, fd, cstring(&s.names[l.at]), flags, mask, &st)
		}
		switch kind_of(l.type, errno, st.mode) {
		case .Gone:
			continue
		case .Unknown:
			short = true
			denied ||= denied_errno(errno)
			continue
		case .Directory:
			e.directory = true
			child_device = statx_device(st)
			if device != 0 && child_device != device {
				e.mount, child_filesystem, child_btrfs = stops_at(
					fd,
					&s.names[l.at],
					st,
					filesystem,
					on_btrfs,
				)
			}
			// Only a mount can lead back to a directory already above it.
			if !e.mount && (.MOUNT_ROOT in st.attributes || above != nil) {
				entered: bool
				e.mount, below, entered = enter(w, fd, above, st)
				if !entered {
					return nodes, bytes, false
				}
			}
		case .Symlink:
			e.symlink = true
			if w.follow {
				followed: bool
				follow, below, followed = follow_link(w, fd, cstring(&s.names[l.at]), above)
				if !followed {
					return nodes, bytes, false
				}
			}
		case .File:
			if asked {
				// Blocks are counted in 512 byte units whatever the filesystem
				// builds them from (stx_blocks in statx(2)).
				e.disk = st.blocks * 512
				e.links = st.nlink
				e.id = {
					device = statx_device(st),
					inode  = u64(l.ino),
				}
				// Which name a file with several is charged to is settled first,
				// so only that name claims its extents (counts). An extra keeps
				// st_blocks, as it does off btrfs, and is charged nothing.
				if e.links > 1 {
					counted, counted_ok := counts(w, index, d.index, e)
					if !counted_ok {
						return nodes, bytes, false
					}
					e.extra = !counted
				}
				if pool != nil && linux.S_ISREG(st.mode) && !e.extra {
					if !charge_extents(w, fd, &pool, &e) {
						return nodes, bytes, false
					}
				}
			}
		}
		kept += 1
		stored := scan.name_at(span, l.at, l.len)
		descend, charged, recorded := record_at(w, index, d.index, e, stored)
		if !recorded {
			return nodes, bytes, false
		}
		if descend && follow {
			child, join_err := join(d.path, name, w.allocator)
			if join_err != nil {
				w.err = .Out_Of_Memory
				return nodes, bytes, false
			}
			// A followed link may lead anywhere, so its directory learns its own
			// device and filesystem when read.
			next := Dir {
				index     = index,
				path      = child,
				ancestors = below,
			}
			if e.directory {
				next.device, next.filesystem = child_device, child_filesystem
				next.btrfs = child_btrfs
			}
			append(&w.found, next)
		}
		nodes += 1
		bytes += charged
	}
	if short {
		mark_unread(w, d.index, denied)
	}
	// After the children are queued and before any of them is opened.
	if w.after_list != nil {
		w.after_list(d.path, w.after_list_data)
	}
	return nodes, bytes, true
}

/*
What one entry is, from the type getdents gave it and, when statx was asked about
it, the error and mode it answered with (.NONE when it was not asked).

An entry statx could not answer is Unknown, and is not recorded: neither its size
nor, where getdents left the type out, whether it is a directory to walk is known,
and a file recorded at 0 bytes would be indistinguishable from an empty one, in the
tree and in the baseline kept from it. Its directory is marked unread instead, so
the total says it is short and an update reads the directory again. A mode 0644
directory lists its names but refuses a statx of every one. An entry gone since it
was listed (ENOENT) holds nothing now, so it is left out without the mark.
*/
@(private)
Kind :: enum u8 {
	File,
	Directory,
	Symlink,
	Gone,
	Unknown,
}

@(private)
kind_of :: proc(type: linux.Dirent_Type, errno: linux.Errno, mode: linux.Mode) -> Kind {
	#partial switch errno {
	case .NONE:
	case .ENOENT:
		return .Gone
	case:
		return .Unknown
	}
	#partial switch type {
	case .DIR:
		// getdents and statx can disagree when the name was replaced by a symlink
		// between them. statx was asked not to follow, so a link mode is the
		// link, and queuing the name as a directory would open it next.
		if linux.S_ISLNK(mode) {
			return .Symlink
		}
		return .Directory
	case .LNK:
		return .Symlink
	case .UNKNOWN:
		// Some filesystems leave the type out of a directory entry (DT_UNKNOWN
		// in getdents(2)). Those are the only ones that have to be told apart
		// here.
		if linux.S_ISDIR(mode) {
			return .Directory
		}
		if linux.S_ISLNK(mode) {
			return .Symlink
		}
	}
	return .File
}

// How many times statx is asked before an EINTR is taken as its answer.
@(private)
STATX_TRIES :: 4

/*
Ask `ask` (statx) about `name`, again when a signal cut the call short: EINTR says
nothing about the entry, only about the call. Bounded, so an entry interrupted
every time ends as one not known rather than a hang.
*/
@(private)
stat_entry :: proc(
	ask: kstat.Call,
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
	mask: linux.Statx_Mask,
	st: ^linux.Statx,
) -> linux.Errno {
	errno: linux.Errno
	for _ in 0 ..< STATX_TRIES {
		errno = ask(dir, name, flags, mask, st)
		if errno != .EINTR {
			break
		}
	}
	return errno
}

/*
Charge a regular file on btrfs what its extents occupy that no file before it was
charged for, in place of st_blocks, searched for through its directory's fd. A
refusal turns the search off for the pool, and *pool to nil, so the rest of the
walk charges st_blocks without asking again. A search that fails otherwise leaves
this one file at st_blocks, logical as the refused ones are. False only when out of
memory.
*/
@(private)
charge_extents :: proc(w: ^Worker, dir: linux.Fd, pool: ^^Btrfs_Pool, e: ^Entry) -> bool {
	owner := btrfs.owner_of(e.id.device, e.id.inode)
	c, err := w.btrfs.search(dir, e.id.inode, w.scratch.args, &pool^.extents, owner)
	switch err {
	case .None:
		e.disk = c.disk
		e.shared = c.shared
	case .Not_Permitted, .Not_Btrfs, .Unsupported:
		btrfs_search_stop(w, pool^)
		pool^ = nil
	case .Out_Of_Memory:
		w.err = .Out_Of_Memory
		return false
	case .Not_Found, .Io, .Malformed:
		scan.mark_logical(w.writer.tree)
	}
	return true
}

// Whether an errno says permission was what a directory lacked.
@(private)
denied_errno :: proc(errno: linux.Errno) -> bool {
	return errno == .EACCES || errno == .EPERM
}

// The device a statx answer lies on, as one number.
@(private)
statx_device :: proc(st: linux.Statx) -> u64 {
	return u64(st.dev_major) << 32 | u64(st.dev_minor)
}

/*
Whether a directory on another device than the one listing it is somewhere the walk
stops, and the filesystem it lies on. A directory is only asked this when its device
changes, which a scan of this machine's / did 13 times (2026-10-15), so the open and
the statfs stay off the path almost every directory takes.

The rule is the same filesystem, not the same device, except where the kernel gives
none to compare: statfs fsid 0, which CentOS 7.9's 3.10.0-1160 reported for /dev, /dev/shm and /run
(2026-10-22), leaves the
device the only thing that tells one from another, and a change of it is a mount. Another filesystem mounted
here, /proc, /sys, a tmpfs /run or /tmp, another disk, a network or FUSE mount, is
a mount: recorded, not walked, as the macOS and Windows readers treat one (e.mount
in read_darwin.odin and read_windows.odin). A btrfs subvolume has a device of its
own but draws on the same pool, so it is walked:
/home and /var/log are subvolumes of / on this machine (2026-10-15), and stopping
at them hid their usage. Its statfs fsid will not do to tell, since btrfs folds the
subvolume's id into it (/ gave 32afd77a847e028d and /home ...028c); the pool's own
UUID, from BTRFS_IOC_FS_INFO, is the same for every subvolume.

A read-only btrfs subvolume is stopped at as a mount is: snapper's snapshots under
/.snapshots are each a whole copy of the system, and walking them would charge the
disk for every one. An automount point is a mount without being opened, which
would mount it.

A bind keeps the device of what it shows, so one within a filesystem never reaches
this test; enter (mounts_linux.odin) asks about every mount the walk would go into,
whether it came here or not. A total is meant
to be the space the filesystem gives back, so a bind of a tree the walk reads
anyway is a mount: mount --bind /var /mnt/var, and a scan of / shows /mnt/var as a
mount point of size 0, with /var counted once, where it lies. A bind of a tree the
walk does not otherwise reach is walked as the directory it appears to be, since
it is the only place that tree is counted: a scan of /mnt alone reads /mnt/var.
Of two binds of one tree outside the scan, the one with the lower mount id is
walked and the other is a mount. A bind of a directory the walk is inside is
always a mount.
*/
@(private)
stops_at :: proc(
	dir: linux.Fd,
	name: ^u8,
	st: linux.Statx,
	parent: u128,
	parent_btrfs: bool,
) -> (
	mount: bool,
	filesystem: u128,
	on_btrfs: bool,
) {
	if .AUTOMOUNT in st.attributes {
		return true, 0, false
	}
	// O_PATH needs no permission on the directory itself (open(2)), so a mount
	// this user cannot read, such as a /boot of mode 0700, is still told apart.
	path, path_errno := linux.openat(dir, cstring(name), {.PATH, .DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if path_errno != .NONE {
		// Gone since it was listed; recorded as the directory it appeared to be.
		return false, parent, parent_btrfs
	}
	fs: linux.Stat_FS
	statfs_errno := linux.fstatfs(path, &fs)
	linux.close(path)
	if statfs_errno != .NONE {
		return false, parent, parent_btrfs
	}
	if fs.type != .BTRFS_SUPER_MAGIC {
		filesystem = statfs_id(fs)
		// fsid 0 carries no identity, so a filesystem of the parent's type looks the
		// same as the parent's. This is only asked
		// when the device changed, which then decides.
		return filesystem != parent || fs.fsid == {}, filesystem, false
	}
	// The pool's UUID and the subvolume's flags need a descriptor opened for
	// reading. A btrfs directory this user cannot open is walked as any unreadable
	// directory is, which reads nothing beneath it.
	fd, errno := linux.openat(dir, cstring(name), {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if errno != .NONE {
		return false, parent, parent_btrfs
	}
	defer linux.close(fd)
	filesystem = btrfs_pool(fd, fs)
	if filesystem != parent {
		return true, filesystem, true
	}
	flags: u64
	got := linux.ioctl(fd, BTRFS_IOC_SUBVOL_GETFLAGS, uintptr(&flags))
	return int(got) >= 0 && flags & BTRFS_SUBVOL_RDONLY != 0, filesystem, true
}

/*
What tells one filesystem from another: the pool's UUID on btrfs, whose statfs fsid
differs from one subvolume to the next, and the statfs fsid and type elsewhere. 0
when statfs fails. on_btrfs says which of the two it is.
*/
@(private)
filesystem_of :: proc(fd: linux.Fd) -> (filesystem: u128, on_btrfs: bool) {
	fs: linux.Stat_FS
	if linux.fstatfs(fd, &fs) != .NONE {
		return 0, false
	}
	if fs.type == .BTRFS_SUPER_MAGIC {
		return btrfs_pool(fd, fs), true
	}
	return statfs_id(fs), false
}

@(private)
statfs_id :: proc(fs: linux.Stat_FS) -> u128 {
	return u128(u32(fs.fsid[0])) | u128(u32(fs.fsid[1])) << 32 | u128(u32(fs.type)) << 64
}

// The UUID of the btrfs pool `fd` lies on, or the statfs identity where the kernel
// will not say. `fd` must be opened for reading: ioctl is not among the calls
// open(2) lists as allowed on an O_PATH one.
@(private)
btrfs_pool :: proc(fd: linux.Fd, fs: linux.Stat_FS) -> u128 {
	info: Btrfs_Fs_Info
	if int(linux.ioctl(fd, BTRFS_IOC_FS_INFO, uintptr(&info))) < 0 {
		return statfs_id(fs)
	}
	return transmute(u128)info.fsid
}

// From linux/btrfs.h: _IOR(0x94, 25, __u64) and _IOR(0x94, 31, struct
// btrfs_ioctl_fs_info_args), neither of which needs privilege.
@(private)
BTRFS_IOC_SUBVOL_GETFLAGS :: 0x80089419
@(private)
BTRFS_IOC_FS_INFO :: 0x8400941f
@(private)
BTRFS_SUBVOL_RDONLY :: 1 << 1

// struct btrfs_ioctl_fs_info_args, 1024 bytes; only the UUID is read.
@(private)
Btrfs_Fs_Info :: struct {
	max_id:          u64,
	num_devices:     u64,
	fsid:            [16]u8,
	nodesize:        u32,
	sectorsize:      u32,
	clone_alignment: u32,
	csum_type:       u16,
	csum_size:       u16,
	flags:           u64,
	generation:      u64,
	metadata_uuid:   [16]u8,
	reserved:        [944]u8,
}
#assert(size_of(Btrfs_Fs_Info) == 1024)

/*
Scratch is what one worker reuses from one directory to the next: the names a
directory holds, each terminated, and where each lies with its inode number.

A directory is listed whole before any entry is asked about, so the entries can be
asked about in inode order. getdents hands entries back in the order the directory
keeps them, which on an indexed ext4 directory is the order of their names'
hashes, unrelated to where their inodes lie. Asked in inode order, a cold read
can take the inode table's blocks in turn rather than jumping between them. btrfs
keys its inode items by inode number too, so the order suits its tree as well. The
cold-cache gain is expected, not yet measured: measuring it needs the caches
dropped, which needs root. With the
table already cached it changes nothing measurable: /usr on btrfs, 442,612 entries,
read in 133 to 189 ms with the sort and without (2026-10-08).
*/
@(private)
Scratch :: struct {
	names:     [dynamic]u8,
	listed:    [dynamic]Dirent,
	// The btrfs pool this worker last charged files to, and the buffer its searches
	// reuse, taken when the first pool to search is met (btrfs_linux.odin).
	pool:      ^Btrfs_Pool,
	args:      ^btrfs.Search_Args,
	// The Ancestors this worker made (mounts_linux.odin). Kept for the whole walk,
	// not one directory: the directories found below one carry them down to
	// whichever worker reads those, so they go with the scratch, once every worker
	// has finished.
	ancestry:  mem.Dynamic_Arena,
	allocator: mem.Allocator,
}

// Dirent is one directory entry as getdents described it: its inode, where its
// name lies in Scratch.names, and its type if the filesystem says.
@(private)
Dirent :: struct {
	ino:  u64,
	at:   int,
	len:  int,
	type: linux.Dirent_Type,
}

@(private)
scratch_make :: proc(allocator: mem.Allocator) -> Scratch {
	s := Scratch {
		names     = make([dynamic]u8, allocator),
		listed    = make([dynamic]Dirent, allocator),
		allocator = allocator,
	}
	// Takes no memory until the first Ancestor, which most walks never make.
	mem.dynamic_arena_init(&s.ancestry, allocator, allocator)
	return s
}

@(private)
scratch_destroy :: proc(s: ^Scratch) {
	delete(s.names)
	delete(s.listed)
	free(s.args, s.allocator)
	mem.dynamic_arena_destroy(&s.ancestry)
}

/*
The root a walk that is not following links keeps open for the whole walk.

`fd` is the directory opened from the path the caller named. `root` is that
path, so a child's path can be turned back into a path relative to `fd`. The
descriptor and the path are shared by every worker. Each worker's copy of
`openat2` is its own: it starts set, and `open_child` clears it when that call
returns ENOSYS.
*/
@(private)
Anchor :: struct {
	fd:        int, // -1 when the walk is not anchored
	root:      string, // owned; empty when fd < 0
	openat2:   bool,
	errno:     linux.Errno, // why the root did not open; NONE when fd >= 0
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
	a.openat2 = true
	a.allocator = allocator
	if follow {
		return a, nil
	}
	buf: Path
	cpath, path_ok := terminate(path, &buf)
	if !path_ok {
		a.errno = .ENAMETOOLONG
		return a, nil
	}
	// The caller's path is opened here. Children are opened from the descriptor.
	fd, errno := linux.open(cpath, {.DIRECTORY, .CLOEXEC})
	if errno != .NONE {
		a.errno = errno
		return a, nil
	}
	root, clone_err := strings.clone(path, allocator)
	if clone_err != nil {
		linux.close(fd)
		a.fd = -1
		return a, clone_err
	}
	a.fd = int(i32(fd))
	a.root = root
	return a, nil
}

@(private)
anchor_release :: proc(a: ^Anchor) {
	if a.fd >= 0 {
		linux.close(linux.Fd(i32(a.fd)))
		a.fd = -1
	}
	delete(a.root, a.allocator)
	a.root = ""
}

// `path` relative to `root`, as `join` built it. Not ok unless `path` is `root`
// or a slash separates `root` from the rest.
@(private)
rel_under :: proc(root, path: string) -> (rel: string, ok: bool) {
	if path == root {
		return "", true
	}
	base := root
	if len(base) > 1 && base[len(base) - 1] == '/' {
		base = base[:len(base) - 1]
	}
	if base == "/" {
		if len(path) > 1 && path[0] == '/' {
			return path[1:], true
		}
		return "", false
	}
	if len(path) <= len(base) || path[:len(base)] != base || path[len(base)] != '/' {
		return "", false
	}
	rest := path[len(base) + 1:]
	if rest == "" {
		return "", false
	}
	return rest, true
}

// Packed for the openat2 syscall below: flags, mode, resolve. The size
// argument is the size of this struct.
@(private)
Open_How :: struct {
	flags:   u64,
	mode:    u64,
	resolve: u64,
}
#assert(size_of(Open_How) == 24)

@(private)
RESOLVE_NO_SYMLINKS :: u64(0x04)
@(private)
RESOLVE_BENEATH :: u64(0x08)

// openat2 with RESOLVE_NO_SYMLINKS and RESOLVE_BENEATH.
@(private)
open_beneath :: proc(dir: linux.Fd, rel: cstring) -> (linux.Fd, linux.Errno) {
	how := Open_How {
		flags   = u64(transmute(u32)linux.Open_Flags{.DIRECTORY, .CLOEXEC}),
		resolve = RESOLVE_NO_SYMLINKS | RESOLVE_BENEATH,
	}
	ret := int(
		intrinsics.syscall(
			linux.SYS_openat2,
			uintptr(i32(dir)),
			transmute(uintptr)rel,
			uintptr(&how),
			uintptr(size_of(Open_How)),
		),
	)
	if ret < 0 {
		return {}, linux.Errno(-ret)
	}
	return linux.Fd(i32(ret)), .NONE
}

// Open `rel` a component at a time with O_NOFOLLOW. A ".." component returns
// EXDEV. `dir` itself is left open.
@(private)
open_nofollow :: proc(dir: linux.Fd, rel: string) -> (linux.Fd, linux.Errno) {
	fd := dir
	owned := false
	i := 0
	for i < len(rel) {
		start := i
		for i < len(rel) && rel[i] != '/' {
			i += 1
		}
		if i > start {
			comp := rel[start:i]
			if comp == ".." {
				if owned {
					linux.close(fd)
				}
				return {}, .EXDEV
			}
			buf: [256]u8
			if len(comp) >= len(buf) {
				if owned {
					linux.close(fd)
				}
				return {}, .ENAMETOOLONG
			}
			copy(buf[:], comp)
			buf[len(comp)] = 0
			next, errno := linux.openat(fd, cstring(&buf[0]), {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
			if owned {
				linux.close(fd)
			}
			if errno != .NONE {
				return {}, errno
			}
			fd = next
			owned = true
		}
		if i < len(rel) && rel[i] == '/' {
			i += 1
		}
	}
	if !owned {
		return {}, .ENOENT
	}
	return fd, .NONE
}

@(private)
open_child :: proc(
	a: ^Anchor,
	dir: linux.Fd,
	crel: cstring,
	rel: string,
) -> (
	linux.Fd,
	linux.Errno,
) {
	if a.openat2 {
		fd, errno := open_beneath(dir, crel)
		if errno != .ENOSYS {
			return fd, errno
		}
		a.openat2 = false
	}
	return open_nofollow(dir, rel)
}

/*
The directory `d` for listing.

When the walk holds an anchor, the root is reopened with its own offset and
every other directory is opened relative to that descriptor. When it does not,
and the caller asked to follow links, the path is opened as given. When it
does not and the caller did not, the open is refused.
*/
@(private)
open_listed :: proc(d: Dir, w: ^Worker, buf: ^Path) -> (linux.Fd, linux.Errno) {
	if w.held.fd >= 0 {
		rel, rel_ok := rel_under(w.held.root, d.path)
		if !rel_ok {
			return {}, .ENOENT
		}
		if rel == "" {
			return linux.openat(linux.Fd(i32(w.held.fd)), ".", {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
		}
		crel, term_ok := terminate(rel, buf)
		if !term_ok {
			return {}, .ENAMETOOLONG
		}
		return open_child(&w.held, linux.Fd(i32(w.held.fd)), crel, rel)
	}
	if !w.follow {
		if w.held.errno != .NONE {
			return {}, w.held.errno
		}
		return {}, .ENOENT
	}
	cpath, path_ok := terminate(d.path, buf)
	if !path_ok {
		return {}, .ENAMETOOLONG
	}
	return linux.open(cpath, {.DIRECTORY, .CLOEXEC})
}
