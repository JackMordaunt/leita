#+build freebsd
package walk

import "core:mem"
import "core:strings"
import "core:sys/posix"

import "../scan"

// FreeBSD supplies directory names through readdir and allocation through fstatat.
// st_blocks counts 512-byte units, including on sparse and compressed files:
// https://man.freebsd.org/cgi/man.cgi?query=stat&sektion=2
@(private)
read_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	buf: Path
	fd, errno := open_listed(d, w, &buf)
	if errno != .NONE {
		mark_unread(w, d.index, denied_errno(errno))
		return 0, 0, false
	}
	// The opened mount, rather than st_dev, also distinguishes nullfs aliases.
	// Asking every opened directory catches mount changes since its listing and
	// followed links onto another filesystem without resolving their path again.
	mount, mount_ok := scan.mount_id_freebsd(fd)
	if !mount_ok {
		posix.close(fd)
		mark_unread(w, d.index, false)
		return 0, 0, false
	}
	if mount != w.held.mount {
		posix.close(fd)
		scan.node_mark(scan.node(w.writer.tree, d.index), {.Mount})
		return 0, 0, true
	}
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		errno = posix.errno()
		posix.close(fd)
		mark_unread(w, d.index, denied_errno(errno))
		return 0, 0, false
	}
	// Refuse a directory replaced after its parent listed it, including a mount
	// installed at that path between listing and opening it.
	if d.identified && (u64(st.st_dev) != d.listed[0] || u64(st.st_ino) != d.listed[1]) {
		posix.close(fd)
		mark_unread(w, d.index, false)
		return 0, 0, false
	}
	below := d.ancestors
	if w.follow {
		id := File_Id{device = u64(st.st_dev), inode = u64(st.st_ino)}
		if on_path(below, id) {
			posix.close(fd)
			return 0, 0, true
		}
		pushed, pushed_ok := push(w, id, below, ancestry(w))
		if !pushed_ok {
			posix.close(fd)
			return 0, 0, false
		}
		below = pushed
	}
	device := st.st_dev
	// fdopendir takes ownership on success; closedir closes the descriptor.
	dir := posix.fdopendir(fd)
	if dir == nil {
		errno = posix.errno()
		posix.close(fd)
		mark_unread(w, d.index, denied_errno(errno))
		return 0, 0, false
	}
	defer posix.closedir(dir)
	for {
		posix.set_errno(.NONE)
		listed := posix.readdir(dir)
		if listed == nil {
			errno = posix.errno()
			if errno != .NONE {
				mark_unread(w, d.index, denied_errno(errno))
				return nodes, bytes, false
			}
			break
		}
		cname := cstring(raw_data(listed.d_name[:]))
		name := string(cname)
		if name == "." || name == ".." {
			continue
		}
		child_stat: posix.stat_t
		if posix.fstatat(fd, cname, &child_stat, {.SYMLINK_NOFOLLOW}) != .OK {
			errno = posix.errno()
			if errno != .ENOENT && errno != .ENOTDIR {
				mark_unread(w, d.index, denied_errno(errno))
			}
			continue
		}
		e := Entry {
			name = name,
			directory = posix.S_ISDIR(child_stat.st_mode),
			symlink = posix.S_ISLNK(child_stat.st_mode),
			id = {device = u64(child_stat.st_dev), inode = u64(child_stat.st_ino)},
		}
		e.mount = e.directory && child_stat.st_dev != device
		if posix.S_ISREG(child_stat.st_mode) {
			e.disk = u64(max(i64(child_stat.st_blocks), 0)) * 512
			e.links = u32(min(u64(child_stat.st_nlink), u64(max(u32))))
			e.account = file_account({
				logical = u64(max(i64(child_stat.st_size), 0)),
				allocated = e.disk,
				charge = e.disk,
				links = e.links,
				allocated_known = true,
				links_known = true,
			})
		}
		index, descend, charged, recorded := record(w, d.index, e)
		if !recorded {
			return nodes, bytes, false
		}
		if descend {
			child, join_err := join(d.path, name, w.allocator)
			if join_err != nil {
				w.err = .Out_Of_Memory
				return nodes, bytes, false
			}
			next := Dir {
				index = index,
				path = child,
				ancestors = below,
				identified = e.directory,
				listed = {e.id.device, e.id.inode, 0},
			}
			if _, append_err := append(&w.found, next); append_err != nil {
				delete(child, w.allocator)
				w.err = .Out_Of_Memory
				return nodes, bytes, false
			}
		}
		nodes += 1
		bytes += charged
	}
	if w.after_list != nil {
		w.after_list(d.path, w.after_list_data)
	}
	return nodes, bytes, true
}

@(private)
Anchor :: struct {
	fd: posix.FD,
	root: string,
	errno: posix.Errno,
	mount: [2]i32,
	allocator: mem.Allocator,
}

@(private)
anchor_prepare :: proc(path: string, follow: bool, allocator: mem.Allocator) -> (a: Anchor, err: mem.Allocator_Error) {
	a.fd = -1
	a.allocator = allocator
	_ = follow
	buf: Path
	fd, errno := open_pieces(posix.AT_FDCWD, path, false, &buf)
	if errno != .NONE {
		a.errno = errno
		return a, nil
	}
	mount, mount_ok := scan.mount_id_freebsd(fd)
	if !mount_ok {
		posix.close(fd)
		a.errno = .EIO
		return a, nil
	}
	a.mount = mount
	root, clone_err := strings.clone(path, allocator)
	if clone_err != nil {
		posix.close(fd)
		return a, clone_err
	}
	a.fd, a.root = fd, root
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

@(private)
open_listed :: proc(d: Dir, w: ^Worker, buf: ^Path) -> (posix.FD, posix.Errno) {
	if w.held.errno != .NONE {
		return -1, w.held.errno
	}
	if w.held.fd >= 0 && d.path == w.held.root {
		fd := posix.openat(w.held.fd, ".", {.DIRECTORY, .CLOEXEC})
		return fd, posix.errno() if fd < 0 else .NONE
	}
	if w.held.fd >= 0 && !w.follow {
		rel, ok := rel_under(w.held.root, d.path)
		if !ok {
			return -1, .ENOENT
		}
		if rel == "" {
			rel = "."
		}
		return open_pieces(w.held.fd, rel, true, buf)
	}
	if !w.follow {
		return -1, w.held.errno if w.held.errno != .NONE else .ENOENT
	}
	return open_pieces(posix.AT_FDCWD, d.path, false, buf)
}

// Open each component from the descriptor for its parent. O_NOFOLLOW on each
// component refuses a symlink in any ancestor below the held root, while keeping
// paths deeper than PATH_MAX usable. The caller's root may itself contain links.
@(private)
open_pieces :: proc(dir: posix.FD, path: string, nofollow: bool, buf: ^Path) -> (posix.FD, posix.Errno) {
	at := dir
	owned := false
	defer if owned {posix.close(at)}
	rest := path
	if strings.has_prefix(rest, "/") {
		if nofollow {
			return -1, .EXDEV
		}
		at = posix.open("/", {.DIRECTORY, .CLOEXEC})
		if at < 0 {
			return -1, posix.errno()
		}
		owned = true
	}
	flags := posix.O_Flags{.DIRECTORY, .CLOEXEC}
	if nofollow {
		flags += {.NOFOLLOW}
	}
	for part in strings.split_iterator(&rest, "/") {
		if part == "" || part == "." {
			continue
		}
		if nofollow && part == ".." {
			return -1, .EXDEV
		}
		cpart, ok := terminate(part, buf)
		if !ok {
			return -1, .ENAMETOOLONG
		}
		next := posix.openat(at, cpart, flags)
		if next < 0 {
			return -1, posix.errno()
		}
		if owned {
			posix.close(at)
		}
		at, owned = next, true
	}
	if !owned {
		at = posix.openat(dir, ".", flags)
		if at < 0 {
			return -1, posix.errno()
		}
	}
	owned = false
	return at, .NONE
}

@(private)
denied_errno :: proc(errno: posix.Errno) -> bool {
	return errno == .EACCES || errno == .EPERM
}

@(private)
Scratch :: struct {
	ancestry: mem.Dynamic_Arena,
}

@(private)
scratch_make :: proc(allocator: mem.Allocator) -> Scratch {
	s: Scratch
	mem.dynamic_arena_init(&s.ancestry, allocator, allocator)
	return s
}

@(private)
scratch_destroy :: proc(s: ^Scratch) {
	mem.dynamic_arena_destroy(&s.ancestry)
}
