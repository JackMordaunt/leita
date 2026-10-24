#+build windows
package walk_fuzz

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:unicode/utf8"

foreign import kernel32 "system:Kernel32.lib"
foreign import advapi32 "system:Advapi32.lib"
foreign import ntdll "system:ntdll.lib"

/*
The Windows materialiser builds a spec on NTFS volumes made for the run.
`just fuzz` starts this program through tools/ntfs-volumes, which, as an
administrator, makes partitions of one VHDX, formats each NTFS with short names
on, mounts each in a folder and names the folders in LEITA_FUZZ_NTFS. A case
builds under the first; each tmpfs of the spec is the next of the others,
emptied and mounted at the tmpfs's directory, so a spec can nest volumes. A case
runs in a child of its own, and the volumes outlive it.

What each kind of node is made as:

	File, Sparse, Scatter  a file; Sparse and Scatter are marked sparse, then sized
	Link                   a hard link (CreateHardLinkW)
	Symlink                to a directory, a junction when its id is even and a
	                       directory symlink when odd; to anything else a file symlink
	Dangling               a junction (even) or a symlink (odd) to a path not there
	Unreadable             a directory with an empty protected DACL
	Mount, tmpfs           a volume of the pool mounted at the directory
	Mount, bind            a junction to the directory (JUNCTION_BINDS in model.odin)

Every path is \\?\ prefixed, so a name with a trailing dot or space, a device
name and a path longer than MAX_PATH are made as they are spelled. What NTFS
cannot hold is spelled as Windows programs that meet it spell it (host_name).
Two names in a directory that differ only in case are made in a directory set
case-sensitive; where the system refuses that, the second takes its plain name.
*/

// POOL_ENV names the folders the volumes are mounted in, separated by ';'.
POOL_ENV :: "LEITA_FUZZ_NTFS"

@(private)
Pool_Volume :: struct {
	folder: string, // where tools/ntfs-volumes mounted it, as \\?\C:\...
	guid:   string, // \\?\Volume{...}\
}

@(private)
pool_once: sync.Once
@(private)
pool: []Pool_Volume
@(private)
pool_reason: string

// load_pool reads the pool from POOL_ENV once, into `allocator`, where it is
// kept for the process's life.
@(private)
load_pool :: proc(allocator: runtime.Allocator) {
	allocator := allocator
	sync.once_do(&pool_once, proc(data: rawptr) {
		pool, pool_reason = read_pool((^runtime.Allocator)(data)^)
	}, &allocator)
}

@(private)
read_pool :: proc(allocator: runtime.Allocator) -> (volumes: []Pool_Volume, reason: string) {
	list := os.get_env(POOL_ENV, allocator)
	if list == "" {
		return nil, "no NTFS volumes to build on: tools/ntfs-volumes makes them for just fuzz, as an administrator"
	}
	out := make([dynamic]Pool_Volume, allocator)
	for folder in strings.split(list, ";", allocator) {
		if folder == "" {
			continue
		}
		buf: [64]u16
		if !GetVolumeNameForVolumeMountPointW(wide(strings.concatenate({folder, `\`}, allocator), allocator), &buf[0], len(buf)) {
			return nil, fmt.aprintf("%s is not a mounted volume (%d)", folder, win.GetLastError(), allocator = allocator)
		}
		append(&out, Pool_Volume{folder = extended_path(folder, allocator), guid = narrow(buf[:], allocator)})
	}
	if len(out) < 2 {
		return nil, "LEITA_FUZZ_NTFS names fewer than two volumes"
	}
	return out[:], ""
}

probe :: proc(allocator := context.temp_allocator) -> (reason: string) {
	load_pool(runtime.heap_allocator())
	return strings.clone(pool_reason, allocator)
}

// extended_path is a full path with the \\?\ prefix, which turns off the
// rewriting Win32 does to a path: dots and spaces at the end of a name kept,
// device names left alone, no MAX_PATH.
@(private)
extended_path :: proc(path: string, allocator: runtime.Allocator) -> string {
	if strings.has_prefix(path, `\\?\`) {
		return strings.clone(path, allocator)
	}
	p, _ := strings.replace_all(path, "/", `\`, allocator)
	return strings.concatenate({`\\?\`, p}, allocator)
}

/*
wide is a path as Windows takes it. Paths here are WTF-8: UTF-8, and a lone
surrogate written as UTF-8 would write it (three bytes from ED A0 to ED BF),
since a name on NTFS is any sequence of 16-bit units and not every one is UTF-16.
*/
@(private)
wide :: proc(s: string, allocator: runtime.Allocator) -> win.wstring {
	out := make([dynamic]u16, 0, len(s) + 1, allocator)
	for i := 0; i < len(s); {
		if s[i] == 0xED && i + 2 < len(s) && s[i + 1] >= 0xA0 && s[i + 1] <= 0xBF && s[i + 2] & 0xC0 == 0x80 {
			append(&out, 0xD000 | (u16(s[i + 1]) & 0x3F) << 6 | u16(s[i + 2]) & 0x3F)
			i += 3
			continue
		}
		r, n := utf8.decode_rune_in_string(s[i:])
		if r >= 0x10000 {
			r -= 0x10000
			append(&out, u16(0xD800 + (r >> 10)), u16(0xDC00 + (r & 0x3FF)))
		} else {
			append(&out, u16(r))
		}
		i += n
	}
	append(&out, 0)
	return win.wstring(raw_data(out))
}

// narrow is a name or path Windows gave, up to its NUL, as WTF-8.
@(private)
narrow :: proc(units: []u16, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(units) && units[i] != 0; i += 1 {
		u := rune(units[i])
		if u >= 0xD800 && u < 0xDC00 && i + 1 < len(units) && units[i + 1] >= 0xDC00 && units[i + 1] < 0xE000 {
			strings.write_rune(&b, 0x10000 + (u - 0xD800) << 10 + (rune(units[i + 1]) - 0xDC00))
			i += 1
		} else if u >= 0xD800 && u < 0xE000 {
			write_surrogate(&b, u)
		} else {
			strings.write_rune(&b, u)
		}
	}
	return strings.to_string(b)
}

@(private)
write_surrogate :: proc(b: ^strings.Builder, u: rune) {
	strings.write_byte(b, 0xE0 | u8(u >> 12))
	strings.write_byte(b, 0x80 | u8((u >> 6) & 0x3F))
	strings.write_byte(b, 0x80 | u8(u & 0x3F))
}

/*
host_name is a spec name as NTFS can hold it. A character Win32 refuses in a name,
a control character or one of "*:<>?\|, is moved to the private use area at
U+F000 plus its code, as Cygwin and WSL store it. A byte that is not UTF-8 becomes
the lone surrogate U+DC00 plus the byte, a name Windows takes and no UTF-16 decoder
gives back; except in a directory's name, which is part of the path of what it
holds, and a path is handed to the walk as UTF-8, so there it takes the private
use spelling as well.
*/
@(private)
host_name :: proc(name: string, holder: bool, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(name); {
		r, n := utf8.decode_rune_in_string(name[i:])
		switch {
		case r == utf8.RUNE_ERROR && n <= 1:
			if holder {
				strings.write_rune(&b, 0xF000 + rune(name[i]))
			} else {
				write_surrogate(&b, 0xDC00 | rune(name[i]))
			}
			n = 1
		case r < 0x20 || strings.contains_rune(`"*:<>?\|`, r):
			strings.write_rune(&b, 0xF000 + r)
		case:
			strings.write_string(&b, name[i:i + n])
		}
		i += n
	}
	return strings.to_string(b)
}

// scratch_name is a directory name of this process's own for one case. Not
// random: a case that drew from the run's random stream would change every case
// after it.
@(private)
scratch_name :: proc(what: string, allocator: runtime.Allocator) -> string {
	@(static) count: u32
	n := intrinsics.atomic_add(&count, 1)
	return fmt.aprintf("leita-fuzz-%s-%d-%d", what, os.get_pid(), n, allocator = allocator)
}

// fit is the spec as Windows can hold it, which is all of it: a name NTFS refuses
// is made as `host_name` says, a clone is made as a copy, and a fork is not made,
// which the model needs nothing of.
fit :: proc(spec: Spec, allocator := context.temp_allocator) -> Spec {
	return spec
}

// aliases are the other paths to the directory of node `start`: none here.
aliases :: proc(fx: ^Fixture, start: int, allocator := context.temp_allocator) -> []string {
	return nil
}

/*
The pool's volumes are lent to one fixture at a time, from `build` until its
`destroy`. The fuzz suite isolates each case in a process of its own, but
`just test` runs the properties and the regressions on threads of one process,
and two cases lent the same volume emptied it under each other.
*/
@(private)
lease: sync.Mutex
@(private)
holder: ^Fixture

// build makes the spec. The error is what failed, in words. Whatever was made
// before a failure is undone by `destroy`.
build :: proc(spec: Spec, fx: ^Fixture, allocator := context.temp_allocator) -> string {
	fx.allocator = allocator
	if why := probe(allocator); why != "" {
		return why
	}

	sync.mutex_lock(&lease)
	holder = fx

	fx.paths = make(map[int]string, allocator)
	fx.mounted = make([dynamic]string, allocator)
	fx.locked = make([dynamic]string, allocator)
	fx.volumes = make(map[int]string, allocator)

	tmpfs := 0
	for n in spec.nodes {
		if n.kind == .Mount && n.mount == .Tmpfs {
			tmpfs += 1
		}
	}
	if tmpfs > len(pool) - 1 {
		return format_reason(allocator, "the spec mounts %d volumes and the pool lends %d", tmpfs, len(pool) - 1)
	}

	fx.base = fmt.aprintf(`%s\%s`, pool[0].folder, scratch_name("tree", allocator), allocator = allocator)
	fx.root = fmt.aprintf(`%s\root`, fx.base, allocator = allocator)
	if !win.CreateDirectoryW(wide(fx.base, allocator), nil) {
		return format_reason(allocator, "mkdir %s: %d", fx.base, win.GetLastError())
	}
	// Outside the scan's root: a locked directory to ask whether this process
	// is refused one.
	probe_dir := fmt.aprintf(`%s\locked`, fx.base, allocator = allocator)
	if !win.CreateDirectoryW(wide(probe_dir, allocator), nil) {
		return format_reason(allocator, "mkdir %s: %d", probe_dir, win.GetLastError())
	}
	if why := lock(fx, probe_dir, allocator); why != "" {
		return why
	}

	lent := 1
	sensitive := make(map[int]bool, allocator)
	for n in spec.nodes {
		if why := make_node(spec, fx, n, &lent, &sensitive, allocator); why != "" {
			return why
		}
	}

	// A bind shows what its source holds once everything is made.
	for n in spec.nodes {
		if n.kind == .Mount && n.mount == .Bind {
			if why := junction(fx.paths[n.id], fx.paths[n.target], allocator); why != "" {
				return why
			}
		}
	}

	// Last, so that making what is inside is not refused.
	for i := len(spec.nodes) - 1; i >= 0; i -= 1 {
		if spec.nodes[i].kind == .Unreadable {
			if why := lock(fx, fx.paths[spec.nodes[i].id], allocator); why != "" {
				return why
			}
		}
	}

	h := win.CreateFileW(
		wide(probe_dir, allocator),
		win.FILE_LIST_DIRECTORY,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		fx.denies = win.GetLastError() == win.ERROR_ACCESS_DENIED
	} else {
		win.CloseHandle(h)
	}

	// Written out, so the walk, Win32 and the MFT reader all see the tree as it
	// will stay: NTFS settles a sparse file's allocation when it writes it.
	flush(pool[0].guid, allocator)
	for _, guid in fx.volumes {
		flush(guid, allocator)
	}
	return ""
}

@(private)
make_node :: proc(
	spec: Spec,
	fx: ^Fixture,
	n: Node,
	lent: ^int,
	sensitive: ^map[int]bool,
	allocator: runtime.Allocator,
) -> string {
	path: string
	if n.id == 0 {
		path = strings.clone(fx.root, allocator)
	} else {
		name := host_name(n.name, can_hold(n), allocator)
		if twin_before(spec, n) && !sensitive[n.parent] {
			// Windows tells these apart only in a directory set to.
			if set_case_sensitive(fx.paths[n.parent], allocator) {
				sensitive[n.parent] = true
			} else {
				if !intrinsics.atomic_exchange(&case_noted, true) {
					fmt.eprintln("tree: a directory could not be made case-sensitive, so a name that differs from another only in case takes its plain name")
				}
				name = name_of(n, allocator)
			}
		}
		path = fmt.aprintf(`%s\%s`, fx.paths[n.parent], name, allocator = allocator)
	}
	fx.paths[n.id] = path
	wpath := wide(path, allocator)
	switch n.kind {
	case .Dir, .Unreadable:
		if !win.CreateDirectoryW(wpath, nil) {
			return format_reason(allocator, "mkdir %s: %d", path, win.GetLastError())
		}
	case .File, .Sparse, .Scatter:
		return make_file(path, n.size, n.kind, allocator)
	case .Link:
		if !win.CreateHardLinkW(wpath, wide(fx.paths[n.target], allocator), nil) {
			return format_reason(allocator, "link %s: %d", path, win.GetLastError())
		}
	case .Symlink:
		t, _ := find(spec, n.target)
		return link(path, fx.paths[n.target], n.target == 0 || can_hold(t) || t.kind == .Mount, n.id, allocator)
	case .Dangling:
		missing := fmt.aprintf(`%s\missing-%d`, fx.base, n.id, allocator = allocator)
		return link(path, missing, true, n.id, allocator)
	case .Mount:
		if !win.CreateDirectoryW(wpath, nil) {
			return format_reason(allocator, "mkdir %s: %d", path, win.GetLastError())
		}
		if n.mount == .Tmpfs {
			v := pool[lent^]
			lent^ += 1
			empty_volume(v.folder, allocator)
			if why := mount(path, v.guid, allocator); why != "" {
				return why
			}
			append(&fx.mounted, path)
			fx.volumes[n.id] = v.guid
		}
	}
	return ""
}

// Whether this process has said that names differing only in case were made plain.
@(private)
case_noted: bool

// twin_before says whether a node earlier in the same directory has its name
// but for case, as NTFS compares names.
@(private)
twin_before :: proc(spec: Spec, n: Node) -> bool {
	for m in spec.nodes {
		if m.id == n.id {
			return false
		}
		if m.parent == n.parent && m.name != n.name && strings.equal_fold(m.name, n.name) {
			return true
		}
	}
	return false
}

// FileCaseSensitiveInfo, which core:sys/windows does not name.
@(private)
FILE_CASE_SENSITIVE_INFO_CLASS :: win.FILE_INFO_BY_HANDLE_CLASS(23)
@(private)
FILE_CS_FLAG_CASE_SENSITIVE_DIR :: 1

// set_case_sensitive sets a directory to tell names apart by case.
@(private)
set_case_sensitive :: proc(dir: string, allocator: runtime.Allocator) -> bool {
	h := win.CreateFileW(
		wide(dir, allocator),
		win.FILE_READ_ATTRIBUTES | win.FILE_WRITE_ATTRIBUTES,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		return false
	}
	defer win.CloseHandle(h)

	flags := u32(FILE_CS_FLAG_CASE_SENSITIVE_DIR)
	return bool(win.SetFileInformationByHandle(h, FILE_CASE_SENSITIVE_INFO_CLASS, &flags, size_of(flags)))
}

// link makes a link at `path` to `target`: to a directory, a junction or a
// directory symlink by whether `id` is even, so both are drawn; to anything
// else a file symlink. A host that refuses a symlink (no Developer Mode and no
// administrator) gets a junction for a directory.
@(private)
link :: proc(path, target: string, directory: bool, id: int, allocator: runtime.Allocator) -> string {
	if directory && id % 2 == 0 {
		if !win.CreateDirectoryW(wide(path, allocator), nil) {
			return format_reason(allocator, "mkdir %s: %d", path, win.GetLastError())
		}
		return junction(path, target, allocator)
	}
	flags := u32(win.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)
	if directory {
		flags |= win.SYMBOLIC_LINK_FLAG_DIRECTORY
	}
	if win.CreateSymbolicLinkW(wide(path, allocator), wide(target, allocator), flags) {
		return ""
	}
	err := win.GetLastError()
	if directory {
		if !win.CreateDirectoryW(wide(path, allocator), nil) {
			return format_reason(allocator, "mkdir %s: %d", path, win.GetLastError())
		}
		return junction(path, target, allocator)
	}
	return format_reason(allocator, "symlink %s: %d", path, err)
}

// junction makes the empty directory `path` a junction to `target`, which need
// not be there: FSCTL_SET_REPARSE_POINT with a mount point's tag, which needs no
// privilege (card 77's tests make them the same way).
@(private)
junction :: proc(path, target: string, allocator: runtime.Allocator) -> string {
	nt := target
	if strings.has_prefix(nt, `\\?\`) {
		nt = nt[4:]
	}
	return reparse_mount(path, strings.concatenate({`\??\`, nt}, allocator), allocator)
}

@(private)
reparse_mount :: proc(path, substitute: string, allocator: runtime.Allocator) -> string {
	d := win.CreateFileW(
		wide(path, allocator),
		win.GENERIC_WRITE,
		0,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if d == win.INVALID_HANDLE_VALUE {
		return format_reason(allocator, "open %s: %d", path, win.GetLastError())
	}
	defer win.CloseHandle(d)

	w := wide(substitute, allocator)
	units := len(string16(w))
	names := (units + 1 + 1) * size_of(u16)
	data := int(offset_of(win.MOUNT_POINT_REPARSE_BUFFER, PathBuffer)) + names
	total := size_of(win.REPARSE_DATA_BUFFER) + data
	if total > win.MAXIMUM_REPARSE_DATA_BUFFER_SIZE {
		return format_reason(allocator, "junction %s: a target of %d units is too long", path, units)
	}

	buf: [win.MAXIMUM_REPARSE_DATA_BUFFER_SIZE / size_of(u32)]u32
	raw := ([^]u8)(&buf)
	rdb := (^win.REPARSE_DATA_BUFFER)(raw)
	rdb.ReparseTag = win.IO_REPARSE_TAG_MOUNT_POINT
	rdb.ReparseDataLength = u16(data)
	mp := (^win.MOUNT_POINT_REPARSE_BUFFER)(&raw[size_of(win.REPARSE_DATA_BUFFER)])
	mp.SubstituteNameOffset = 0
	mp.SubstituteNameLength = u16(units * size_of(u16))
	// The print name is left empty.
	mp.PrintNameOffset = u16((units + 1) * size_of(u16))
	mp.PrintNameLength = 0
	path_buffer := ([^]u16)(&mp.PathBuffer)
	copy(path_buffer[:units], ([^]u16)(w)[:units])
	path_buffer[units] = 0
	path_buffer[units + 1] = 0
	returned: win.DWORD
	if !win.DeviceIoControl(d, win.FSCTL_SET_REPARSE_POINT, &buf, win.DWORD(total), nil, 0, &returned, nil) {
		return format_reason(allocator, "junction %s to %s: %d", path, substitute, win.GetLastError())
	}
	return ""
}

// mount mounts a volume of the pool at the empty directory `path`: through the
// mount manager where it takes the path, as mountvol does, and where it does
// not, a mount point set on the directory by hand, which NTFS follows the same.
@(private)
mount :: proc(path, guid: string, allocator: runtime.Allocator) -> string {
	if SetVolumeMountPointW(wide(strings.concatenate({path, `\`}, allocator), allocator), wide(guid, allocator)) {
		return ""
	}
	// \\?\Volume{...}\ as the object manager names it.
	return reparse_mount(path, strings.concatenate({`\??\`, guid[4:]}, allocator), allocator)
}

// What a locked directory's DACL is, and what it is given back to remove it.
@(private)
LOCKED_SDDL :: "D:P"
@(private)
OPEN_SDDL :: "D:(A;OICI;FA;;;WD)"
@(private)
DACL_SECURITY_INFORMATION :: 0x00000004
@(private)
PROTECTED_DACL_SECURITY_INFORMATION :: 0x80000000
@(private)
UNPROTECTED_DACL_SECURITY_INFORMATION :: 0x20000000
@(private)
SDDL_REVISION_1 :: 1

// lock gives a directory a protected DACL with nothing in it, which refuses
// everyone the owner does not let back in. An administrator is refused too: a
// walk does not enable the backup privilege.
@(private)
lock :: proc(fx: ^Fixture, path: string, allocator: runtime.Allocator) -> string {
	if !set_dacl(path, LOCKED_SDDL, PROTECTED_DACL_SECURITY_INFORMATION, allocator) {
		return format_reason(allocator, "lock %s: %d", path, win.GetLastError())
	}
	append(&fx.locked, path)
	return ""
}

@(private)
unlock :: proc(path: string, allocator: runtime.Allocator) -> bool {
	return set_dacl(path, OPEN_SDDL, UNPROTECTED_DACL_SECURITY_INFORMATION, allocator)
}

@(private)
set_dacl :: proc(path, sddl: string, protection: u32, allocator: runtime.Allocator) -> bool {
	sd: win.PSECURITY_DESCRIPTOR
	if !ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(sddl, allocator), SDDL_REVISION_1, &sd, nil) {
		return false
	}
	defer win.LocalFree(sd)

	return bool(SetFileSecurityW(wide(path, allocator), DACL_SECURITY_INFORMATION | protection, sd))
}

// FSCTL_SET_SPARSE, which core:sys/windows does not name.
@(private)
FSCTL_SET_SPARSE :: 0x000900C4

@(private)
make_file :: proc(path: string, size: u64, kind: Kind, allocator: runtime.Allocator) -> string {
	h := win.CreateFileW(wide(path, allocator), win.GENERIC_WRITE, 0, nil, win.CREATE_NEW, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE {
		return format_reason(allocator, "create %s: %d", path, win.GetLastError())
	}
	defer win.CloseHandle(h)

	if kind == .Sparse || kind == .Scatter {
		// Marked sparse first, so the size set after it is a hole and costs nothing.
		returned: win.DWORD
		if !win.DeviceIoControl(h, FSCTL_SET_SPARSE, nil, 0, nil, 0, &returned, nil) {
			return format_reason(allocator, "make %s sparse: %d", path, win.GetLastError())
		}
		if !win.SetFilePointerEx(h, win.LARGE_INTEGER(size), nil, win.FILE_BEGIN) || !win.SetEndOfFile(h) {
			return format_reason(allocator, "size %s: %d", path, win.GetLastError())
		}
	}

	switch kind {
	case .Scatter:
		// Four pieces of data, a block each, with holes between them and the
		// last at the end, as on Linux.
		block: [4096]u8
		for &x, i in block {
			x = u8('A' + i % 26)
		}

		for k in u64(0) ..< 4 {
			at := (size * k / 4) &~ 4095
			if k == 3 {
				at = (size - 1) &~ 4095
			}
			if why := write_at(h, path, block[:min(u64(len(block)), size - at)], at, allocator); why != "" {
				return why
			}
		}
	case .Sparse:
		// The size is a hole, and one byte at the start is data.
		if size > 0 {
			one := []u8{'x'}
			return write_at(h, path, one, 0, allocator)
		}
	case .File, .Dir, .Link, .Symlink, .Dangling, .Unreadable, .Mount:
		return write_out(h, path, size, 'a', allocator)
	}
	return ""
}

@(private)
write_at :: proc(h: win.HANDLE, path: string, data: []u8, at: u64, allocator: runtime.Allocator) -> string {
	o: win.OVERLAPPED
	o.Offset = u32(at)
	o.OffsetHigh = u32(at >> 32)
	written: win.DWORD
	if !win.WriteFile(h, raw_data(data), win.DWORD(len(data)), &written, &o) || int(written) != len(data) {
		return format_reason(allocator, "write %s: %d", path, win.GetLastError())
	}
	return ""
}

// write_out writes `size` bytes of a pattern starting at `first` where the
// handle stands.
@(private)
write_out :: proc(h: win.HANDLE, path: string, size: u64, first: u8, allocator: runtime.Allocator) -> string {
	chunk: [4096]u8
	for &x, i in chunk {
		x = first + u8(i % 26)
	}
	for left := size; left > 0; {
		part := min(u64(len(chunk)), left)
		written: win.DWORD
		if !win.WriteFile(h, &chunk[0], win.DWORD(part), &written, nil) || written == 0 {
			return format_reason(allocator, "write %s: %d", path, win.GetLastError())
		}
		left -= u64(written)
	}
	return ""
}

// destroy unmounts what was mounted, newest first, unlocks what was locked,
// removes everything, empties the volumes it was lent and frees what the fixture
// holds.
destroy :: proc(fx: ^Fixture) {
	allocator := fx.allocator
	for i := len(fx.mounted) - 1; i >= 0; i -= 1 {
		DeleteVolumeMountPointW(wide(strings.concatenate({fx.mounted[i], `\`}, allocator), allocator))
	}

	for p in fx.locked {
		unlock(p, allocator)
	}

	if fx.base != "" {
		remove_tree(fx.base, allocator)
	}
	for _, guid in fx.volumes {
		for v in pool {
			if v.guid == guid {
				empty_volume(v.folder, allocator)
			}
		}
	}

	for _, p in fx.paths {
		delete(p, allocator)
	}
	delete(fx.paths)
	delete(fx.mounted)
	delete(fx.locked)
	delete(fx.volumes)
	delete(fx.root, allocator)
	delete(fx.base, allocator)

	if holder == fx {
		holder = nil
		sync.mutex_unlock(&lease)
	}
	fx^ = {}
}

// foreign_name says whether a name at a volume's root is the volume's own:
// System Volume Information, which a volume formatted NTFS is made with, the recycle bin, and
// the metadata files ($MFT and the rest) a reader of the MFT sees.
foreign_name :: proc(name: string) -> bool {
	return name == "System Volume Information" || strings.has_prefix(name, "$")
}

// empty_volume removes everything at a volume's root but what the volume
// came with, so a case that died part way leaves nothing for the next.
@(private)
empty_volume :: proc(folder: string, allocator: runtime.Allocator) {
	for name in entries(folder, allocator) {
		if !foreign_name(name) {
			remove_tree(fmt.aprintf(`%s\%s`, folder, name, allocator = allocator), allocator)
		}
	}
}

// entries are the names in a directory, "." and ".." left out; nil when it cannot
// be listed, and once more after it is unlocked.
@(private)
entries :: proc(dir: string, allocator: runtime.Allocator) -> []string {
	out := make([dynamic]string, allocator)
	data: win.WIN32_FIND_DATAW
	pattern := wide(strings.concatenate({dir, `\*`}, allocator), allocator)
	h := win.FindFirstFileW(pattern, &data)
	if h == win.INVALID_HANDLE_VALUE && win.GetLastError() == win.ERROR_ACCESS_DENIED && unlock(dir, allocator) {
		h = win.FindFirstFileW(pattern, &data)
	}
	if h == win.INVALID_HANDLE_VALUE {
		return nil
	}
	defer win.FindClose(h)

	for {
		name := narrow(data.cFileName[:], allocator)
		if name != "." && name != ".." {
			append(&out, name)
		}
		if !win.FindNextFileW(h, &data) {
			break
		}
	}
	return out[:]
}

// remove_tree removes a path and what it holds, never following a reparse
// point: a junction, a symlink or a mount point is removed and what it shows
// is left alone.
@(private)
remove_tree :: proc(path: string, allocator: runtime.Allocator) {
	w := wide(path, allocator)
	attrs := win.GetFileAttributesW(w)
	if attrs == win.INVALID_FILE_ATTRIBUTES {
		return
	}
	directory := attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0
	if attrs & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		if directory {
			DeleteVolumeMountPointW(wide(strings.concatenate({path, `\`}, allocator), allocator))
			win.RemoveDirectoryW(w)
		} else {
			win.DeleteFileW(w)
		}
		return
	}
	if !directory {
		win.SetFileAttributesW(w, win.FILE_ATTRIBUTE_NORMAL)
		win.DeleteFileW(w)
		return
	}
	for name in entries(path, allocator) {
		remove_tree(fmt.aprintf(`%s\%s`, path, name, allocator = allocator), allocator)
	}
	win.RemoveDirectoryW(w)
}

// deny does nothing: a locked directory's DACL refuses this process already.
deny :: proc(fx: ^Fixture) -> (restore: proc(), ok: bool) {
	return proc() {}, true
}

// File_Figures are what Windows says of one file.
@(private)
File_Figures :: struct {
	length, allocation: u64,
	occupied:           u64, // GetCompressedFileSizeW: the allocation less the holes
	mapped:             u64, // the clusters NTFS maps to the disk, in bytes
	mapped_known:       bool, // false for a file held in its MFT record
	links:              u32,
	attributes:         u32,
	cluster:            u64, // of the volume the file is on
}

@(private)
figures :: proc(path: string, allocator: runtime.Allocator) -> (f: File_Figures, err: string) {
	h := win.CreateFileW(
		wide(path, allocator),
		win.FILE_READ_ATTRIBUTES,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		return {}, format_reason(allocator, "open %s: %d", path, win.GetLastError())
	}
	defer win.CloseHandle(h)

	std: win.FILE_STANDARD_INFO
	basic: win.FILE_BASIC_INFO
	if !win.GetFileInformationByHandleEx(h, .FileStandardInfo, &std, size_of(std)) ||
	   !win.GetFileInformationByHandleEx(h, .FileBasicInfo, &basic, size_of(basic)) {
		return {}, format_reason(allocator, "ask %s: %d", path, win.GetLastError())
	}
	size: File_Fs_Size_Information
	iosb: win.IO_STATUS_BLOCK
	if NtQueryVolumeInformationFile(h, &iosb, &size, size_of(size), FILE_FS_SIZE_INFORMATION) < 0 {
		return {}, format_reason(allocator, "the cluster size of %s: unknown", path)
	}

	high: win.DWORD
	low := GetCompressedFileSizeW(wide(path, allocator), &high)
	if low == 0xFFFF_FFFF && win.GetLastError() != win.NO_ERROR {
		return {}, format_reason(allocator, "compressed size of %s: %d", path, win.GetLastError())
	}
	cluster := u64(size.sectors_per_allocation_unit) * u64(size.bytes_per_sector)
	clusters, known := mapped_clusters(h)
	return {
			length = u64(max(i64(std.EndOfFile), 0)),
			allocation = u64(max(i64(std.AllocationSize), 0)),
			occupied = u64(high) << 32 | u64(low),
			mapped = clusters * cluster,
			mapped_known = known,
			links = u32(std.NumberOfLinks),
			attributes = basic.FileAttributes,
			cluster = cluster,
		},
		""
}

@(private)
FSCTL_GET_RETRIEVAL_POINTERS :: 0x00090073

@(private)
ERROR_MORE_DATA :: 234

// RETRIEVAL_POINTERS_BUFFER from <winioctl.h>, with room for 32 extents a call.
@(private)
Retrieval_Pointers :: struct {
	count:   u32,
	_:       u32,
	start:   i64,
	extents: [32]struct {
		next: i64,
		lcn:  i64,
	},
}

/*
mapped_clusters counts the clusters FSCTL_GET_RETRIEVAL_POINTERS says the file's
data stream holds on the disk; a hole is an extent at LCN -1. It is how NTFS itself
says where the data is, apart from both the sizes the walk asks for and the MFT
reader's run lists. Not known for a file whose data is in its MFT record, which has
no extents.
*/
@(private)
mapped_clusters :: proc(h: win.HANDLE) -> (clusters: u64, ok: bool) {
	from: i64
	for {
		out: Retrieval_Pointers
		returned: win.DWORD
		done := win.DeviceIoControl(h, FSCTL_GET_RETRIEVAL_POINTERS, &from, size_of(from), &out, size_of(out), &returned, nil)
		if !done && win.GetLastError() != ERROR_MORE_DATA {
			return 0, false
		}
		at := out.start
		for e in out.extents[:min(out.count, len(out.extents))] {
			if e.lcn != -1 {
				clusters += u64(e.next - at)
			}
			at = e.next
		}
		if done || out.count == 0 {
			return clusters, true
		}
		from = at
	}
}

@(private)
File_Fs_Size_Information :: struct {
	total_allocation_units:      i64,
	available_allocation_units:  i64,
	sectors_per_allocation_unit: u32,
	bytes_per_sector:            u32,
}

@(private)
FILE_FS_SIZE_INFORMATION :: 3

/*
allocated is what the files named by `nodes` occupy, as Win32 says it apart
from the walk: the allocation FileStandardInfo gives, or for a sparse or
compressed file the clusters NTFS maps (mapped_clusters), which leaves the holes
out. GetCompressedFileSizeW stops at the file's length, and NTFS gives a sparse
file a compression unit at a time, 16 clusters, so a sparse file of 4096 bytes
holds 64 KiB on the 4 KiB clusters tools/ntfs-volumes formats.
A file whose data is in its MFT record has an allocation that is not a whole
number of clusters, and is charged its length, as walk/charge.odin charges it.
*/
allocated :: proc(fx: ^Fixture, nodes: []int, allocator := context.temp_allocator) -> (bytes: u64, err: string) {
	for id in nodes {
		path := fx.paths[id]
		f, why := figures(path, allocator)
		if why != "" {
			return 0, why
		}
		charge := f.allocation
		if f.attributes & (win.FILE_ATTRIBUTE_SPARSE_FILE | win.FILE_ATTRIBUTE_COMPRESSED) != 0 {
			charge = f.mapped if f.mapped_known else f.occupied
		}
		if f.cluster > 0 && charge % f.cluster != 0 {
			charge = f.length
		}
		bytes += charge
	}
	return bytes, ""
}

// sizes_match is "" when each file is the size the spec says.
sizes_match :: proc(spec: Spec, fx: ^Fixture, allocator := context.temp_allocator) -> string {
	for n in spec.nodes {
		if !is_file(n) {
			continue
		}
		f, err := figures(fx.paths[n.id], allocator)
		if err != "" {
			return err
		}
		if f.length != n.size {
			return format_reason(allocator, "%s is %d bytes, the spec says %d", n.name, f.length, n.size)
		}
	}
	return ""
}

@(private)
do_op :: proc(m: ^Churn, op: Op) -> string {
	heap := m.allocator
	// Paths and messages, within what a path may be.
	space: [65536]u8
	scratch: mem.Arena
	mem.arena_init(&scratch, space[:])
	temp := mem.arena_allocator(&scratch)
	switch op.kind {
	case .Create:
		path := fmt.aprintf(`%s\%s`, m.paths[op.parent], host_name(op.name, false, temp), allocator = heap)
		m.paths[op.id] = path
		if why := make_file(path, op.size, .File, temp); why != "" {
			return strings.clone(why, heap)
		}
	case .Delete:
		path := m.paths[op.id]
		if !win.DeleteFileW(wide(path, temp)) {
			return format_reason(heap, "delete %s: %d", path, win.GetLastError())
		}
	case .Rename:
		from := m.paths[op.id]
		to := fmt.aprintf(`%s\%s`, m.paths[op.parent], host_name(op.name, false, temp), allocator = heap)
		if !win.MoveFileExW(wide(from, temp), wide(to, temp), 0) {
			why := format_reason(heap, "rename %s to %s: %d", from, to, win.GetLastError())
			delete(to, heap)
			return why
		}
		delete(from, heap)
		m.paths[op.id] = to
	case .Grow:
		path := m.paths[op.id]
		h := win.CreateFileW(wide(path, temp), FILE_APPEND_DATA, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
		if h == win.INVALID_HANDLE_VALUE {
			return format_reason(heap, "open %s: %d", path, win.GetLastError())
		}
		defer win.CloseHandle(h)

		if why := write_out(h, path, op.size, 'a', temp); why != "" {
			return strings.clone(why, heap)
		}
	}
	return ""
}

@(private)
FILE_APPEND_DATA :: 0x0004

@(default_calling_convention = "system")
foreign kernel32 {
	GetVolumeNameForVolumeMountPointW :: proc(mount: win.wstring, volume: [^]u16, length: win.DWORD) -> win.BOOL ---
	SetVolumeMountPointW :: proc(mount: win.wstring, volume: win.wstring) -> win.BOOL ---
	DeleteVolumeMountPointW :: proc(mount: win.wstring) -> win.BOOL ---
	GetCompressedFileSizeW :: proc(path: win.wstring, high: ^win.DWORD) -> win.DWORD ---
}

@(default_calling_convention = "system")
foreign advapi32 {
	SetFileSecurityW :: proc(path: win.wstring, what: win.SECURITY_INFORMATION, sd: win.PSECURITY_DESCRIPTOR) -> win.BOOL ---
	ConvertStringSecurityDescriptorToSecurityDescriptorW :: proc(sddl: win.wstring, revision: win.DWORD, sd: ^win.PSECURITY_DESCRIPTOR, size: ^win.ULONG) -> win.BOOL ---
}

@(default_calling_convention = "system")
foreign ntdll {
	NtQueryVolumeInformationFile :: proc(file: win.HANDLE, iosb: ^win.IO_STATUS_BLOCK, info: rawptr, length: u32, class: i32) -> win.NTSTATUS ---
}
