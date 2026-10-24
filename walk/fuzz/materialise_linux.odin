package walk_fuzz

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

/*
The Linux materialiser builds a spec under a temp directory. A tmpfs mount and a
bind mount need a mount namespace of the process's own: `just fuzz` runs the
program under `unshare --user --map-root-user --mount`. A process that already
has threads cannot unshare (unshare(2), CLONE_NEWUSER), so the namespace is the
program's, not each case's, and every case's mounts are gone with it.

probe asks whether a mount can be made and a bind told from a directory. Where
it cannot the suite says so and runs only what needs no mount.
*/

probe :: proc(allocator := context.temp_allocator) -> (reason: string) {
	dir, err := scratch_dir("probe", allocator)
	if err != nil {
		return format_reason(allocator, "no temp directory to try a mount in (%v)", err)
	}
	defer os.remove_all(dir)
	cdir := c(dir, allocator)
	if errno := linux.mount("tmpfs", cdir, "tmpfs", {}, nil); errno != .NONE {
		return format_reason(allocator, "a tmpfs would not mount (%v): no user and mount namespace", errno)
	}
	defer linux.umount2(cdir, {.MNT_DETACH})
	st: linux.Statx
	if linux.statx(linux.AT_FDCWD, cdir, {}, {.MNT_ID}, &st) != .NONE || .MNT_ID not_in st.mask {
		return "this kernel gives no mount ids (Linux 5.8), so a bind cannot be told from a directory"
	}
	return ""
}

// scratch_dir makes a directory of its own under the temp directory. Its name is
// the process, a count and what it is for, not random: a case that drew from the
// run's random stream would change every case after it.
@(private)
scratch_dir :: proc(what: string, allocator: runtime.Allocator) -> (path: string, err: os.Error) {
	@(static) count: u32
	parent := os.temp_directory(allocator) or_else "/tmp"
	n := intrinsics.atomic_add(&count, 1)
	path = fmt.aprintf("%s/leita-fuzz-%s-%d-%d", parent, what, os.get_pid(), n, allocator = allocator)
	return path, os.make_directory(path)
}

@(private)
c :: proc(s: string, allocator: runtime.Allocator) -> cstring {
	return strings.clone_to_cstring(s, allocator)
}

// build makes the spec. The error is what failed, in words. Whatever was made
// before a failure is undone by `destroy`.
build :: proc(spec: Spec, fx: ^Fixture, allocator := context.temp_allocator) -> string {
	fx.allocator = allocator
	base, err := scratch_dir("tree", allocator)
	if err != nil {
		return format_reason(allocator, "no directory to build in (%v)", err)
	}
	fx.base = base
	fx.root = fmt.aprintf("%s/root", base, allocator = allocator)
	fx.paths = make(map[int]string, allocator)
	fx.mounted = make([dynamic]string, allocator)
	fx.locked = make([dynamic]string, allocator)
	// Outside the scan's root: a directory of mode 0 to ask whether this
	// process is refused one.
	probe_dir := fmt.aprintf("%s/mode0", base, allocator = allocator)
	if e := linux.mkdir(c(probe_dir, allocator), {}); e != .NONE {
		return format_reason(allocator, "mkdir %s: %v", probe_dir, e)
	}
	for n in spec.nodes {
		if why := make_node(spec, fx, n, allocator); why != "" {
			return why
		}
	}
	// A bind shows what its source holds once everything is made.
	for n in spec.nodes {
		if n.kind == .Mount && n.mount == .Bind {
			if why := bind(fx, n, allocator); why != "" {
				return why
			}
		}
	}
	// Last, so that making what is inside is not refused.
	for i := len(spec.nodes) - 1; i >= 0; i -= 1 {
		if spec.nodes[i].kind == .Unreadable {
			if why := lock(fx, spec.nodes[i].id, allocator); why != "" {
				return why
			}
		}
	}
	if restore, ok := deny(fx); ok {
		_, e := linux.open(c(probe_dir, allocator), {.DIRECTORY})
		fx.denies = e == .EACCES
		restore()
	}
	return ""
}

@(private)
make_node :: proc(spec: Spec, fx: ^Fixture, n: Node, allocator: runtime.Allocator) -> string {
	path: string
	if n.id == 0 {
		path = strings.clone(fx.root, allocator)
	} else {
		path = fmt.aprintf("%s/%s", fx.paths[n.parent], n.name, allocator = allocator)
	}
	fx.paths[n.id] = path
	cpath := c(path, allocator)
	errno: linux.Errno
	what: string
	switch n.kind {
	case .Dir, .Unreadable:
		errno, what = linux.mkdir(cpath, {.IRUSR, .IWUSR, .IXUSR}), "mkdir"
	case .File, .Sparse, .Scatter:
		return make_file(path, n.size, n.kind, allocator)
	case .Link:
		errno, what = linux.link(c(fx.paths[n.target], allocator), cpath), "link"
	case .Symlink:
		errno, what = linux.symlink(c(relative(spec, n.parent, n.target, allocator), allocator), cpath), "symlink"
	case .Dangling:
		missing := fmt.aprintf("missing-%d", n.id, allocator = allocator)
		errno, what = linux.symlink(c(missing, allocator), cpath), "symlink"
	case .Mount:
		if errno = linux.mkdir(cpath, {.IRUSR, .IWUSR, .IXUSR}); errno != .NONE {
			what = "mkdir"
			break
		}
		if n.mount == .Tmpfs {
			errno, what = linux.mount("tmpfs", cpath, "tmpfs", {}, nil), "mount tmpfs on"
			if errno == .NONE {
				append(&fx.mounted, path)
			}
		}
	}
	if errno != .NONE {
		return format_reason(allocator, "%s %s: %v", what, path, errno)
	}
	return ""
}

@(private)
bind :: proc(fx: ^Fixture, n: Node, allocator: runtime.Allocator) -> string {
	from, at := fx.paths[n.target], fx.paths[n.id]
	if e := linux.mount(c(from, allocator), c(at, allocator), nil, {.BIND}, nil); e != .NONE {
		return format_reason(allocator, "bind %s on %s: %v", from, at, e)
	}
	append(&fx.mounted, at)
	return ""
}

@(private)
lock :: proc(fx: ^Fixture, id: int, allocator: runtime.Allocator) -> string {
	at := fx.paths[id]
	if e := linux.chmod(c(at, allocator), {}); e != .NONE {
		return format_reason(allocator, "chmod %s: %v", at, e)
	}
	append(&fx.locked, at)
	return ""
}

@(private)
make_file :: proc(path: string, size: u64, kind: Kind, allocator: runtime.Allocator) -> string {
	fd, e := linux.open(c(path, allocator), {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
	if e != .NONE {
		return format_reason(allocator, "create %s: %v", path, e)
	}
	defer linux.close(fd)
	if kind == .Scatter {
		// Four pieces of data, a block each, with holes between them and the last
		// at the end, so the file is made of separate runs of blocks.
		if te := linux.ftruncate(fd, i64(size)); te != .NONE {
			return format_reason(allocator, "truncate %s: %v", path, te)
		}
		block: [4096]u8
		for &x, i in block {
			x = u8('A' + i % 26)
		}
		for k in u64(0) ..< 4 {
			at := (size * k / 4) &~ 4095
			if k == 3 {
				at = (size - 1) &~ 4095
			}
			piece := block[:min(u64(len(block)), size - at)]
			if _, we := linux.pwrite(fd, piece, i64(at)); we != .NONE {
				return format_reason(allocator, "write %s: %v", path, we)
			}
		}
		return ""
	}
	if kind == .Sparse {
		// The size is a hole, and one byte at the start is data.
		if te := linux.ftruncate(fd, i64(size)); te != .NONE {
			return format_reason(allocator, "truncate %s: %v", path, te)
		}
		if size > 0 {
			one := []u8{'x'}
			if _, we := linux.pwrite(fd, one, 0); we != .NONE {
				return format_reason(allocator, "write %s: %v", path, we)
			}
		}
		return ""
	}
	chunk: [4096]u8
	for &x, i in chunk {
		x = u8('a' + i % 26)
	}
	for left := size; left > 0; {
		n, we := linux.write(fd, chunk[:min(u64(len(chunk)), left)])
		if we != .NONE {
			return format_reason(allocator, "write %s: %v", path, we)
		}
		left -= u64(n)
	}
	return ""
}

// relative is the path from the directory `from` to the node `to`, as a symbolic
// link written in `from` would say it.
@(private)
relative :: proc(spec: Spec, from, to: int, allocator: runtime.Allocator) -> string {
	up := path_of(spec, from, allocator)
	down := path_of(spec, to, allocator)
	a := strings.split(up, "/", allocator) if up != "" else nil
	d := strings.split(down, "/", allocator) if down != "" else nil
	same := 0
	for same < len(a) && same < len(d) && a[same] == d[same] {
		same += 1
	}
	b := strings.builder_make(allocator)
	for _ in same ..< len(a) {
		strings.write_string(&b, "../")
	}
	strings.write_string(&b, strings.join(d[same:], "/", allocator))
	if strings.builder_len(b) == 0 {
		return "."
	}
	return strings.to_string(b)
}

// destroy unmounts what was mounted, newest first, makes what was locked
// readable, removes everything and frees what the fixture holds.
destroy :: proc(fx: ^Fixture) {
	allocator := fx.allocator
	for i := len(fx.mounted) - 1; i >= 0; i -= 1 {
		linux.umount2(c(fx.mounted[i], allocator), {.MNT_DETACH})
	}
	for p in fx.locked {
		linux.chmod(c(p, allocator), {.IRUSR, .IWUSR, .IXUSR})
	}
	if fx.base != "" {
		os.remove_all(fx.base)
	}
	for _, p in fx.paths {
		delete(p, allocator)
	}
	delete(fx.paths)
	delete(fx.mounted)
	delete(fx.locked)
	delete(fx.root, allocator)
	delete(fx.base, allocator)
	fx^ = {}
}

// What a capability set is, for capget and capset (capget(2)): version 3 and two
// words of 32 capabilities each.
@(private)
Cap_Header :: struct {
	version: u32,
	pid:     i32,
}
@(private)
Cap_Data :: struct {
	effective, permitted, inheritable: u32,
}
@(private)
CAP_VERSION_3 :: 0x20080522
// CAP_DAC_OVERRIDE and CAP_DAC_READ_SEARCH, in the first word.
@(private)
CAP_DAC_BITS :: u32(1 << 1 | 1 << 2)

@(private)
saved_caps: [2]Cap_Data

// deny gives up, for this thread and so for the walkers it starts, what lets root
// open a directory of mode 0, and says how to take them back. Not ok where it
// cannot (not root, or no capget).
deny :: proc(fx: ^Fixture) -> (restore: proc(), ok: bool) {
	head := Cap_Header{CAP_VERSION_3, 0}
	if intrinsics.syscall(linux.SYS_capget, uintptr(&head), uintptr(&saved_caps[0])) != 0 {
		return nil, false
	}
	if saved_caps[0].effective & CAP_DAC_BITS == 0 {
		// Not the capabilities that open it: the mode already refuses.
		return proc() {}, true
	}
	less := saved_caps
	less[0].effective &~= CAP_DAC_BITS
	head = {CAP_VERSION_3, 0}
	if intrinsics.syscall(linux.SYS_capset, uintptr(&head), uintptr(&less[0])) != 0 {
		return nil, false
	}
	return proc() {
			head := Cap_Header{CAP_VERSION_3, 0}
			intrinsics.syscall(linux.SYS_capset, uintptr(&head), uintptr(&saved_caps[0]))
		},
		true
}

// allocated is what the files named by `nodes` occupy, from statx, which is
// what the spec cannot say: a filesystem rounds up to blocks, and a hole costs
// nothing.
allocated :: proc(fx: ^Fixture, nodes: []int, allocator := context.temp_allocator) -> (bytes: u64, err: string) {
	for id in nodes {
		st: linux.Statx
		if e := linux.statx(linux.AT_FDCWD, c(fx.paths[id], allocator), {.SYMLINK_NOFOLLOW}, {.BLOCKS}, &st); e != .NONE {
			return 0, format_reason(allocator, "statx %s: %v", fx.paths[id], e)
		}
		bytes += st.blocks * 512
	}
	return bytes, ""
}

// sizes_match is "" when each file is the size the spec says: the model's
// apparent size is only worth anything if the files are what it assumes.
sizes_match :: proc(spec: Spec, fx: ^Fixture, allocator := context.temp_allocator) -> string {
	for n in spec.nodes {
		if !is_file(n) {
			continue
		}
		st: linux.Statx
		if e := linux.statx(linux.AT_FDCWD, c(fx.paths[n.id], allocator), {.SYMLINK_NOFOLLOW}, {.SIZE}, &st); e != .NONE {
			return format_reason(allocator, "statx %s: %v", fx.paths[n.id], e)
		}
		if st.size != n.size {
			return format_reason(allocator, "%s is %d bytes, the spec says %d", n.name, st.size, n.size)
		}
	}
	return ""
}
