#+build linux
package walk

import "core:mem"
import "core:slice"
import "core:strings"
import "core:sys/linux"

/*
Read one directory with the calls the work actually needs.

core:os describes every entry in full: an fd opened and closed around it, a statx on
that fd, and the entry's path read back through /proc/self/fd. Four syscalls, where
one statx against the directory answers everything the tree records. Walking 14,478
entries cost 64,235 calls that way against du's 21,511 for the same tree, and the
procfs readlink was over half of it.

getdents also names each entry's type, so most are settled without asking again, and
statx reports allocated blocks as readily as length. That makes the on-disk figure
exact here rather than the length rounded up to a guessed block, so a sparse or
compressed file is charged what it occupies.
*/
@(private)
read_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	path: Path
	cpath, path_ok := terminate(d.path, &path)
	if !path_ok {
		return 0, 0, false
	}
	// Not NOFOLLOW: the queue holds directories, and symlinks only when the caller
	// asked for those to be followed, so refusing a link here would refuse exactly
	// the ones it was told to walk. DIRECTORY still rejects a link onto a file.
	fd, open_errno := linux.open(cpath, {.DIRECTORY, .CLOEXEC})
	if open_errno != .NONE {
		return 0, 0, false
	}
	defer linux.close(fd)

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

	for l in s.listed {
		name := string(s.names[l.at:][:l.len])
		e := Entry {
			name      = name,
			directory = l.type == .DIR,
			symlink   = l.type == .LNK,
		}
		mask := linux.Statx_Mask{.TYPE, .BLOCKS}
		st: linux.Statx
		if linux.statx(fd, cstring(&s.names[l.at]), {.SYMLINK_NOFOLLOW}, mask, &st) == .NONE {
			// Some filesystems leave the type out of a directory entry. Those are
			// the only ones that have to be told apart here.
			if l.type == .UNKNOWN {
				e.directory = linux.S_ISDIR(st.mode)
				e.symlink = linux.S_ISLNK(st.mode)
			}
			if !e.directory && !e.symlink {
				// Blocks are counted in 512 byte units whatever the filesystem
				// builds them from.
				e.disk = st.blocks * 512
			}
		}
		index, descend, recorded := record(w, d.index, e)
		if !recorded {
			return nodes, bytes, false
		}
		if descend {
			child, join_err := join(d.path, name, w.allocator)
			if join_err != nil {
				w.err = .Out_Of_Memory
				return nodes, bytes, false
			}
			append(&w.found, Dir{index = index, path = child})
		}
		nodes += 1
		bytes += e.disk
	}
	return nodes, bytes, true
}

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
	names:  [dynamic]u8,
	listed: [dynamic]Dirent,
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
	return {names = make([dynamic]u8, allocator), listed = make([dynamic]Dirent, allocator)}
}

@(private)
scratch_destroy :: proc(s: ^Scratch) {
	delete(s.names)
	delete(s.listed)
}

// A path as the kernel wants it. Long enough for anything the kernel will accept, so
// building one costs no allocation.
@(private)
Path :: [4096]u8

@(private)
terminate :: proc(path: string, buf: ^Path) -> (cstring, bool) {
	if len(path) >= len(buf) {
		return nil, false
	}
	copy(buf[:], path)
	buf[len(path)] = 0
	return cstring(&buf[0]), true
}

// The child's path, which getdents does not hand back and the queue needs.
@(private)
join :: proc(dir, name: string, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	if strings.has_suffix(dir, "/") {
		return strings.concatenate({dir, name}, allocator)
	}
	return strings.concatenate({dir, "/", name}, allocator)
}
