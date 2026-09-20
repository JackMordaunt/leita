#+build linux
package walk

import "core:mem"
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

	// Sized so a directory of any ordinary size comes back in one call. core:os
	// starts at 512 bytes and grows only when the kernel refuses, which cost it
	// roughly twice the getdents calls for the same tree.
	buf: [32 * mem.Kilobyte]u8
	for {
		n, errno := linux.getdents(fd, buf[:])
		if errno != .NONE {
			return nodes, bytes, false
		}
		if n == 0 {
			return nodes, bytes, true
		}
		offset := 0
		for entry in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(entry)
			if name == "." || name == ".." {
				continue
			}
			e := Entry {
				name      = name,
				directory = entry.type == .DIR,
				symlink   = entry.type == .LNK,
			}
			// The name sits in the buffer already terminated, so it addresses the
			// entry without being copied anywhere first.
			mask := linux.Statx_Mask{.TYPE, .SIZE, .BLOCKS}
			st: linux.Statx
			if linux.statx(fd, cstring(raw_data(name)), {.SYMLINK_NOFOLLOW}, mask, &st) == .NONE {
				// Some filesystems leave the type out of a directory entry. Those are
				// the only ones that have to be told apart here.
				if entry.type == .UNKNOWN {
					e.directory = linux.S_ISDIR(st.mode)
					e.symlink = linux.S_ISLNK(st.mode)
				}
				e.size = st.size
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
	}
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
