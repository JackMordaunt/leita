#+build darwin
package walk_fuzz

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"

import walk ".."

foreign import libc "system:System"

/*
The macOS materialiser builds a spec under the temp directory, on the APFS data
volume. A tmpfs of the spec is an APFS disk image attached at its node: a sparse
image cloned from a template made once per machine, case-sensitive for a mount of
odd id and case-insensitive for one of even id, so a spec nests volumes of both
kinds inside each other. hdiutil attaches an image without root
(as user 501 on macOS 14.8 and 26.6, CI run 40111434348).

A clone is made with clonefile(2), so it shares its data with what it is a clone
of; `sizes_match` asks the clone ids whether it does. A fork is an extended
attribute or a resource fork, set with setxattr(2).

What APFS cannot hold, `fit` turns into what it can before the spec is built: a
bind (macOS has none) becomes an empty directory; a name that is not UTF-8
(APFS refuses it), a twin that differs only in Unicode normalisation (APFS
compares names normalised, on every volume), a twin that differs only in case on
a case-insensitive volume, and a name that would take a path past PATH_MAX (1024
bytes), get their plain names back. Each refusal was seen on macOS 14.8 and
26.6 (CI run 40111434348): EILSEQ for the bytes, EEXIST for the twins.

The temp directory is reached through the firmlink /private to the data volume,
so every start also has a second path, under /System/Volumes/Data, which a scan
must agree with (`aliases`).
*/

// What the name of a fixture's base adds to the temp directory, at most: the
// process and count may each take ten digits.
@(private = "file")
BASE_SUFFIX :: len("/leita-fuzz-tree-") + 10 + 1 + 10 + len("/root")

// The size of each disk image; a sparse image takes only what is written in it.
@(private = "file")
IMAGE_SIZE :: "64m"

// The firmlinked data volume, as /usr/share/firmlinks names it.
@(private = "file")
DATA_VOLUME :: "/System/Volumes/Data"

@(private = "file")
host_once: sync.Once
@(private = "file")
host: struct {
	temp:           string, // the temp directory, symlinks resolved, no trailing slash
	case_sensitive: bool, // whether the temp directory's volume tells case apart
	images:         string, // where the templates are kept
	reason:         string, // why no tree can be made here, "" if one can
}

// probe says why no tree can be made here, "" if one can. It makes the templates
// the first time, and detaches what a case killed before its own cleanup left
// attached.
probe :: proc(allocator := context.temp_allocator) -> (reason: string) {
	prepare_host()
	if host.reason != "" {
		return host.reason
	}

	sweep(allocator)
	return ""
}

// prepare_host finds the temp directory and makes the templates, once a process. What it
// keeps is the heap's; what it needs on the way, an arena's it frees.
@(private = "file")
prepare_host :: proc() {
	sync.once_do(&host_once, proc() {
		heap := runtime.heap_allocator()
		arena: vmem.Arena
		if vmem.arena_init_growing(&arena) != nil {
			host.reason = "no memory to look at the temp directory with"
			return
		}
		defer vmem.arena_destroy(&arena)

		scratch := vmem.arena_allocator(&arena)

		temp, err := os.temp_directory(scratch)
		if err != nil {
			host.reason = fmt.aprintf("no temp directory (%v)", err, allocator = heap)
			return
		}
		real := posix.realpath(c_string(strings.trim_right(temp, "/"), scratch))
		if real == nil {
			host.reason = fmt.aprintf("the temp directory %s does not resolve (%v)", temp, posix.errno(), allocator = heap)
			return
		}
		host.temp = strings.clone(string(real), heap)
		posix.free(rawptr(real))

		host.case_sensitive = case_conf(c_string(host.temp, scratch), PC_CASE_SENSITIVE) == 1
		host.images = fmt.aprintf("%s/leita-fuzz-images-%d", host.temp, posix.geteuid(), allocator = heap)
		os.make_directory(host.images)

		for sensitive in ([]bool{false, true}) {
			if why := make_template(sensitive, scratch); why != "" {
				host.reason = strings.clone(why, heap)
				return
			}
		}
	})
}

// template is the path of the image every volume of a kind is cloned from.
@(private = "file")
template :: proc(sensitive: bool, allocator: runtime.Allocator) -> string {
	return fmt.aprintf("%s/%s.sparseimage", host.images, "apfs-cs" if sensitive else "apfs-ci", allocator = allocator)
}

// make_template makes a template unless one is there. It is made under a name of
// its own and renamed into place, so a process that finds it finds it whole.
@(private = "file")
make_template :: proc(sensitive: bool, allocator: runtime.Allocator) -> string {
	final := template(sensitive, allocator)
	if os.exists(final) {
		return ""
	}

	kind := "cs" if sensitive else "ci"
	partial := fmt.aprintf("%s/making-%d-%s.sparseimage", host.images, posix.getpid(), kind, allocator = allocator)
	fs := "Case-sensitive APFS" if sensitive else "APFS"
	ok, out := run({"hdiutil", "create", "-quiet", "-size", IMAGE_SIZE, "-fs", fs, "-volname", "leita-fuzz", "-type", "SPARSE", partial}, allocator)
	if !ok {
		os.remove(partial)
		return fmt.aprintf("hdiutil cannot make an %s image here: %s", fs, out, allocator = allocator)
	}
	if posix.rename(c_string(partial, allocator), c_string(final, allocator)) != 0 {
		os.remove(partial)
		return fmt.aprintf("rename %s: %v", partial, posix.errno(), allocator = allocator)
	}
	return ""
}

// run runs a command and says whether it exited 0, with what it printed.
@(private = "file")
run :: proc(command: []string, allocator: runtime.Allocator) -> (ok: bool, output: string) {
	state, out, errout, err := os.process_exec({command = command}, allocator)
	if err != nil {
		return false, fmt.aprintf("%v", err, allocator = allocator)
	}
	output = fmt.aprintf("%s%s", strings.trim_space(string(out)), strings.trim_space(string(errout)), allocator = allocator)
	return state.exited && state.exit_code == 0, output
}

// sweep detaches every volume mounted in a fixture whose process is gone: a case
// that crashed or was killed for a hang never ran its own `destroy`.
@(private = "file")
sweep :: proc(allocator: runtime.Allocator) {
	ok, out := run({"mount"}, allocator)
	if !ok {
		return
	}

	marker := fmt.aprintf("%s/leita-fuzz-tree-", host.temp, allocator = allocator)
	stale := make([dynamic]string, allocator)
	for line in strings.split_lines_iterator(&out) {
		_, _, rest := strings.partition(line, " on ")
		at := strings.index(rest, marker)
		if at < 0 {
			continue
		}
		point := rest[at:]
		if paren := strings.index(point, " ("); paren >= 0 {
			point = point[:paren]
		}
		pid_text := point[len(marker):]
		if dash := strings.index_byte(pid_text, '-'); dash >= 0 {
			pid_text = pid_text[:dash]
		}
		pid, number := strconv.parse_int(pid_text)
		if !number || (posix.kill(posix.pid_t(pid), posix.Signal(0)) == .FAIL && posix.errno() == .ESRCH) {
			append(&stale, point)
		}
	}

	// The deepest first, so a volume inside another lets go of it.
	slice.sort_by(stale[:], proc(a, b: string) -> bool {return len(a) > len(b)})
	for point in stale {
		run({"hdiutil", "detach", "-force", point}, allocator)
	}
}

// case_sensitive says whether the filesystem `in_domain` tells names apart by case.
@(private = "file")
case_sensitive :: proc(in_domain: int) -> bool {
	if in_domain == 0 {
		prepare_host()
		return host.case_sensitive
	}
	return in_domain % 2 == 1
}

// fit is the spec as APFS can hold it; see the comment at the top.
fit :: proc(spec: Spec, allocator := context.temp_allocator) -> Spec {
	prepare_host()
	nodes := copy_nodes(spec, allocator)
	out := Spec{nodes}
	for &n, i in nodes {
		if i == 0 {
			continue
		}
		if n.kind == .Mount && n.mount == .Bind {
			n.kind, n.mount, n.target = .Dir, .Tmpfs, NONE
		}
		plain := name_of(n, allocator)
		if n.name == plain {
			continue
		}
		path := len(host.temp) + BASE_SUFFIX + 1 + len(path_of(out, n.parent, allocator)) + 1 + len(n.name)
		if !utf8.valid_string(n.name) || path >= posix.PATH_MAX || twin_before(nodes[:i], n, case_sensitive(domain(out, n.parent)), allocator) {
			n.name = plain
		}
	}
	return out
}

// twin_before says whether a sibling before `n` has a name APFS takes for its own.
@(private = "file")
twin_before :: proc(before: []Node, n: Node, sensitive: bool, allocator: runtime.Allocator) -> bool {
	key := fold(n.name, sensitive, allocator)
	for m, i in before {
		if i > 0 && m.parent == n.parent && fold(m.name, sensitive, allocator) == key {
			return true
		}
	}
	return false
}

// fold is a name as APFS compares it, for the names the generator makes: é
// decomposed, and the ASCII letters in one case where case is not told apart.
@(private = "file")
fold :: proc(name: string, sensitive: bool, allocator: runtime.Allocator) -> string {
	out, _ := strings.replace_all(name, "é", "é", allocator)
	if !sensitive {
		out = strings.to_lower(out, allocator)
	}
	return out
}

// aliases are the other paths to the directory of node `start`: its path through
// the data volume, which the firmlink /private leads to.
aliases :: proc(fx: ^Fixture, start: int, allocator := context.temp_allocator) -> []string {
	path := fx.paths[start]
	if !strings.has_prefix(path, "/private/") {
		return nil
	}
	alias := strings.concatenate({DATA_VOLUME, path}, allocator)
	a, b: posix.stat_t
	if posix.stat(c_string(path, allocator), &a) != .OK || posix.stat(c_string(alias, allocator), &b) != .OK || a.st_dev != b.st_dev || a.st_ino != b.st_ino {
		return nil
	}
	out := make([]string, 1, allocator)
	out[0] = alias
	return out
}

@(private = "file")
c_string :: proc(s: string, allocator: runtime.Allocator) -> cstring {
	return strings.clone_to_cstring(s, allocator)
}

// scratch_dir makes a directory of its own under the temp directory, named for
// the process and a count, not at random: a case that drew from the run's random
// stream would change every case after it.
@(private = "file")
scratch_dir :: proc(what: string, allocator: runtime.Allocator) -> (path: string, ok: bool) {
	@(static) count: u32
	n := intrinsics.atomic_add(&count, 1)
	path = fmt.aprintf("%s/leita-fuzz-%s-%d-%d", host.temp, what, posix.getpid(), n, allocator = allocator)
	return path, posix.mkdir(c_string(path, allocator), {.IRUSR, .IWUSR, .IXUSR}) == .OK
}

// build makes the spec, which `fit` has made one APFS can hold. The error is
// what failed, in words. Whatever was made before a failure is undone by `destroy`.
build :: proc(spec: Spec, fx: ^Fixture, allocator := context.temp_allocator) -> string {
	fx.allocator = allocator
	if why := probe(allocator); why != "" {
		return why
	}
	base, made := scratch_dir("tree", allocator)
	if !made {
		return format_reason(allocator, "no directory to build in (%v)", posix.errno())
	}
	fx.base = base
	fx.root = fmt.aprintf("%s/root", base, allocator = allocator)
	fx.paths = make(map[int]string, allocator)
	fx.mounted = make([dynamic]string, allocator)
	fx.locked = make([dynamic]string, allocator)
	images := fmt.aprintf("%s/images", base, allocator = allocator)
	probe_dir := fmt.aprintf("%s/mode0", base, allocator = allocator)
	for dir in ([]string{images, probe_dir}) {
		if posix.mkdir(c_string(dir, allocator), {.IRUSR, .IWUSR, .IXUSR}) != .OK {
			return format_reason(allocator, "mkdir %s: %v", dir, posix.errno())
		}
	}

	for n in spec.nodes {
		if why := make_node(spec, fx, n, images, allocator); why != "" {
			return why
		}
	}

	for i := len(spec.nodes) - 1; i >= 0; i -= 1 {
		if spec.nodes[i].kind == .Unreadable {
			at := fx.paths[spec.nodes[i].id]
			if posix.chmod(c_string(at, allocator), {}) != .OK {
				return format_reason(allocator, "chmod %s: %v", at, posix.errno())
			}
			append(&fx.locked, at)
		}
	}

	if posix.chmod(c_string(probe_dir, allocator), {}) != .OK {
		return format_reason(allocator, "chmod %s: %v", probe_dir, posix.errno())
	}
	if _, ok := deny(fx); ok {
		fd := posix.open(c_string(probe_dir, allocator), {.DIRECTORY})
		fx.denies = fd == -1 && posix.errno() == .EACCES
		if fd != -1 {
			posix.close(fd)
		}
	}
	posix.chmod(c_string(probe_dir, allocator), {.IRUSR, .IWUSR, .IXUSR})
	return ""
}

@(private = "file")
make_node :: proc(spec: Spec, fx: ^Fixture, n: Node, images: string, allocator: runtime.Allocator) -> string {
	path: string
	if n.id == 0 {
		path = strings.clone(fx.root, allocator)
	} else {
		path = fmt.aprintf("%s/%s", fx.paths[n.parent], n.name, allocator = allocator)
	}
	fx.paths[n.id] = path
	cpath := c_string(path, allocator)
	what: string
	failed := false
	switch n.kind {
	case .Dir, .Unreadable:
		what, failed = "mkdir", posix.mkdir(cpath, {.IRUSR, .IWUSR, .IXUSR}) != .OK
	case .File, .Sparse, .Scatter:
		if is_clone(n) {
			// The clone has the target's forks already: clonefile copied a resource
			// fork in CI run 40111434348, and `allocated` checks the blocks.
			if clonefile(c_string(fx.paths[n.target], allocator), cpath, 0) != 0 {
				return format_reason(allocator, "clonefile %s to %s: %v", fx.paths[n.target], path, posix.errno())
			}
			return ""
		}
		if why := make_file(path, n.size, n.kind, allocator); why != "" {
			return why
		}
		return add_fork(path, n.fork, allocator)
	case .Link:
		what, failed = "link", posix.link(c_string(fx.paths[n.target], allocator), cpath) != .OK
	case .Symlink:
		what, failed = "symlink", posix.symlink(c_string(relative(spec, n.parent, n.target, allocator), allocator), cpath) != .OK
	case .Dangling:
		missing := fmt.aprintf("missing-%d", n.id, allocator = allocator)
		what, failed = "symlink", posix.symlink(c_string(missing, allocator), cpath) != .OK
	case .Mount:
		if posix.mkdir(cpath, {.IRUSR, .IWUSR, .IXUSR}) != .OK {
			what, failed = "mkdir", true
			break
		}
		if n.mount == .Bind {
			return format_reason(allocator, "%s: macOS has no bind mounts, and fit makes none", path)
		}
		return attach(fx, n, path, images, allocator)
	}
	if failed {
		return format_reason(allocator, "%s %s: %v", what, path, posix.errno())
	}
	return ""
}

// attach clones a template and attaches it at `path`, and keeps the disk it came
// up as, which is what detach must name.
@(private = "file")
attach :: proc(fx: ^Fixture, n: Node, path, images: string, allocator: runtime.Allocator) -> string {
	image := fmt.aprintf("%s/%d.sparseimage", images, n.id, allocator = allocator)
	from := template(case_sensitive(n.id), allocator)
	if clonefile(c_string(from, allocator), c_string(image, allocator), 0) != 0 {
		return format_reason(allocator, "clonefile %s to %s: %v", from, image, posix.errno())
	}
	// With owners honoured the volume's directories are this user's on disk, so
	// another volume can be attached on one of them; without, macOS refuses the
	// nested attach (Permission denied, CI run 40115180312).
	ok, out := run({"hdiutil", "attach", "-nobrowse", "-noverify", "-noautofsck", "-owners", "on", "-mountpoint", path, image}, allocator)
	if !ok {
		return format_reason(allocator, "hdiutil attach %s on %s: %s", image, path, out)
	}

	first, _, _ := strings.partition(out, "\n")
	device, _, _ := strings.partition(first, "\t")
	device = strings.trim_space(device)
	if !strings.has_prefix(device, "/dev/disk") {
		// Attached all the same: the mount point is what detach is left to name.
		append(&fx.mounted, strings.clone(path, allocator))
		return format_reason(allocator, "hdiutil attach named no disk: %q", out)
	}

	append(&fx.mounted, strings.clone(device, allocator))
	return ""
}

// detach ejects a disk, and retries while macOS says it is busy, which on a loaded
// runner it does for a while after the volume is unmounted (card 697; see
// walk/read_darwin_test.odin, detach_image).
@(private = "file")
detach :: proc(device: string, allocator: runtime.Allocator) -> bool {
	ATTEMPTS :: 40
	for _ in 1 ..= ATTEMPTS {
		ok, out := run({"hdiutil", "detach", "-force", device}, allocator)
		if ok {
			return true
		}
		if !strings.contains(out, "busy") {
			return false
		}
		time.sleep(500 * time.Millisecond)
	}
	return false
}

@(private = "file")
add_fork :: proc(path: string, fork: Fork, allocator: runtime.Allocator) -> string {
	name: cstring
	size: int
	switch fork {
	case .None:
		return ""
	case .Xattr:
		name, size = "user.leita-fuzz", XATTR_BYTES
	case .Resource:
		name, size = "com.apple.ResourceFork", RESOURCE_BYTES
	}
	value := make([]u8, size, allocator)
	slice.fill(value, 'r')
	if setxattr(c_string(path, allocator), name, raw_data(value), uint(size), 0, XATTR_NOFOLLOW) != 0 {
		return format_reason(allocator, "setxattr %s on %s: %v", name, path, posix.errno())
	}
	return ""
}

@(private = "file")
make_file :: proc(path: string, size: u64, kind: Kind, allocator: runtime.Allocator) -> string {
	fd := posix.open(c_string(path, allocator), {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
	if fd == -1 {
		return format_reason(allocator, "create %s: %v", path, posix.errno())
	}
	defer posix.close(fd)

	put :: proc(fd: posix.FD, data: []u8, at: u64) -> bool {
		return posix.pwrite(fd, raw_data(data), len(data), posix.off_t(at)) == len(data)
	}
	#partial switch kind {
	case .Scatter:
		// Four pieces of data, a block each, with holes between them and the last
		// at the end, as the Linux materialiser writes them.
		if posix.ftruncate(fd, posix.off_t(size)) != .OK {
			return format_reason(allocator, "truncate %s: %v", path, posix.errno())
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
			if !put(fd, block[:min(u64(len(block)), size - at)], at) {
				return format_reason(allocator, "write %s: %v", path, posix.errno())
			}
		}
	case .Sparse:
		if posix.ftruncate(fd, posix.off_t(size)) != .OK {
			return format_reason(allocator, "truncate %s: %v", path, posix.errno())
		}
		if size > 0 && !put(fd, {'x'}, 0) {
			return format_reason(allocator, "write %s: %v", path, posix.errno())
		}
	case:
		chunk: [4096]u8
		for &x, i in chunk {
			x = u8('a' + i % 26)
		}

		for at := u64(0); at < size; at += u64(len(chunk)) {
			if !put(fd, chunk[:min(u64(len(chunk)), size - at)], at) {
				return format_reason(allocator, "write %s: %v", path, posix.errno())
			}
		}
	}
	return ""
}

// destroy detaches what was attached, newest first so a volume inside another
// goes before it, makes what was locked readable, removes everything and frees
// what the fixture holds.
destroy :: proc(fx: ^Fixture) {
	allocator := fx.allocator
	detached := true
	for i := len(fx.mounted) - 1; i >= 0; i -= 1 {
		detached &= detach(fx.mounted[i], allocator)
	}

	set_readable(fx, true)

	// A volume still attached is left with its tree for `sweep`, rather than
	// emptied through its mount point.
	if fx.base != "" && detached {
		os.remove_all(fx.base)
	}

	for _, p in fx.paths {
		delete(p, allocator)
	}
	for d in fx.mounted {
		delete(d, allocator)
	}

	delete(fx.paths)
	delete(fx.clones)
	delete(fx.mounted)
	delete(fx.locked)
	delete(fx.root, allocator)
	delete(fx.base, allocator)
	fx^ = {}
}

// deny says how to give up what lets this process open a directory of mode 0:
// nothing for a user, and as root it gives up nothing, so it is not ok.
deny :: proc(fx: ^Fixture) -> (restore: proc(), ok: bool) {
	if posix.geteuid() == 0 {
		return nil, false
	}
	return proc() {}, true
}

/*
allocated is what the files named by `nodes` occupy: the blocks lstat gives each,
less the data each clone shares with another of them, which is charged once. The
spec says which files are clones of which; getattrlist says how much data each
has, and its allocated size, all forks counted, must agree with lstat's blocks
(it is the size the walk is given, by getattrlistbulk). A clone that shares
nothing with what it is a clone of is a materialiser fault, and `sizes_match`
reports it.
*/
allocated :: proc(fx: ^Fixture, nodes: []int, allocator := context.temp_allocator) -> (bytes: u64, err: string) {
	// The data streams charged, by volume and clone id: an image's inode numbers,
	// and so its clone ids, start where every other image's do.
	paid := make(map[[2]u64]bool, allocator)

	set_readable(fx, true)
	defer set_readable(fx, false)

	for id in nodes {
		path := fx.paths[id]
		st: posix.stat_t
		if posix.lstat(c_string(path, allocator), &st) != .OK {
			return 0, format_reason(allocator, "lstat %s: %v", path, posix.errno())
		}
		blocks := u64(st.st_blocks) * 512
		facts, ok := attributes(path, allocator)
		if !ok {
			return 0, format_reason(allocator, "getattrlist %s: %v", path, posix.errno())
		}
		if facts.allocated != blocks {
			return 0, format_reason(allocator, "%s: lstat says %d bytes, getattrlist %d", path, blocks, facts.allocated)
		}
		bytes += blocks
		if facts.data == 0 || !shares(fx, id) {
			continue
		}
		key := [2]u64{u64(st.st_dev), facts.clone}
		if paid[key] {
			bytes -= facts.data
		}
		paid[key] = true
	}
	return bytes, ""
}

// set_readable gives the unreadable directories their mode back, outermost first, or
// takes it away again, innermost first: lstat of a file below a directory of
// mode 0 is refused to this process (EACCES, CI run 40112391166).
// No scan is running while the oracles look.
@(private = "file")
set_readable :: proc(fx: ^Fixture, readable: bool) {
	buf: [posix.PATH_MAX]u8
	if readable {
		for i := len(fx.locked) - 1; i >= 0; i -= 1 {
			posix.chmod(on_stack(fx.locked[i], &buf), {.IRUSR, .IWUSR, .IXUSR})
		}
		return
	}

	for p in fx.locked {
		posix.chmod(on_stack(p, &buf), {})
	}
}

// on_stack is a path as C wants it, in `buf`; `fit` keeps every path shorter.
@(private = "file")
on_stack :: proc(path: string, buf: ^[posix.PATH_MAX]u8) -> cstring {
	n := copy(buf[:posix.PATH_MAX - 1], path)
	buf[n] = 0
	return cstring(&buf[0])
}

// shares says whether the spec made the node a clone, or made a clone of it.
@(private = "file")
shares :: proc(fx: ^Fixture, id: int) -> bool {
	_, in_group := fx.clones[id]
	return in_group
}

@(private = "file")
Facts :: struct {
	allocated, data, clone: u64,
}

// attributes asks getattrlist for a file's allocated size, all forks, its data
// fork's, and the id of the data stream it may share with clones.
@(private = "file")
attributes :: proc(path: string, allocator: runtime.Allocator) -> (f: Facts, ok: bool) {
	request := Attr_Request {
		bitmapcount = 5,
		commonattr  = walk.ATTR_CMN_RETURNED_ATTRS,
		fileattr    = walk.ATTR_FILE_ALLOCSIZE | walk.ATTR_FILE_DATAALLOCSIZE,
		forkattr    = walk.ATTR_CMNEXT_CLONEID,
	}
	reply: [64]u8
	if getattrlist(c_string(path, allocator), &request, &reply, len(reply), walk.FSOPT_NOFOLLOW | walk.FSOPT_ATTR_CMN_EXTENDED) != 0 {
		return {}, false
	}
	// A u32 length, the five words of what was returned, then each value in bit
	// order at four-byte alignment (getattrlist(2)).
	file := endian.get_u32(reply[16:], .Little) or_return
	fork := endian.get_u32(reply[20:], .Little) or_return
	if file & walk.ATTR_FILE_ALLOCSIZE == 0 || file & walk.ATTR_FILE_DATAALLOCSIZE == 0 {
		return {}, false
	}
	f.allocated = endian.get_u64(reply[24:], .Little) or_return
	f.data = endian.get_u64(reply[32:], .Little) or_return
	if fork & walk.ATTR_CMNEXT_CLONEID != 0 {
		f.clone = endian.get_u64(reply[40:], .Little) or_return
	}
	return f, true
}

// sizes_match is "" when each file is the size the spec says, and each clone
// shares its data stream with what it is a clone of: the model's numbers are only
// worth anything if the files are what it assumes.
sizes_match :: proc(spec: Spec, fx: ^Fixture, allocator := context.temp_allocator) -> string {
	fx.clones = make(map[int]bool, allocator)

	set_readable(fx, true)
	defer set_readable(fx, false)

	for n in spec.nodes {
		if !is_file(n) {
			continue
		}
		st: posix.stat_t
		if posix.lstat(c_string(fx.paths[n.id], allocator), &st) != .OK {
			return format_reason(allocator, "lstat %s: %v", fx.paths[n.id], posix.errno())
		}
		if u64(st.st_size) != n.size {
			return format_reason(allocator, "%s is %d bytes, the spec says %d", n.name, st.st_size, n.size)
		}
		if !is_clone(n) {
			continue
		}
		mine, ok := attributes(fx.paths[n.id], allocator)
		theirs, ok2 := attributes(fx.paths[n.target], allocator)
		if !ok || !ok2 {
			return format_reason(allocator, "getattrlist %s: %v", fx.paths[n.id], posix.errno())
		}
		if mine.data != 0 && (mine.clone == 0 || mine.clone != theirs.clone || mine.data != theirs.data) {
			return format_reason(allocator, "%s is no clone of %s: clone ids %d and %d", n.name, fx.paths[n.target], mine.clone, theirs.clone)
		}
		fx.clones[n.id] = true
		fx.clones[n.target] = true
	}

	// A hard link to a file of a group is a name of the same file.
	for n in spec.nodes {
		if n.kind == .Link && fx.clones[n.target] {
			fx.clones[n.id] = true
		}
	}
	return ""
}

@(private = "file")
Attr_Request :: struct {
	bitmapcount: u16,
	reserved:    u16,
	commonattr:  u32,
	volattr:     u32,
	dirattr:     u32,
	fileattr:    u32,
	forkattr:    u32,
}

// From Apple's xnu bsd/sys/xattr.h and unistd.h; the getattrlist bits are walk's.
@(private = "file")
XATTR_NOFOLLOW :: 0x0001
@(private = "file")
PC_CASE_SENSITIVE :: 11

@(private = "file", default_calling_convention = "c")
foreign libc {
	clonefile :: proc(src, dst: cstring, flags: u32) -> c.int ---
	setxattr :: proc(path, name: cstring, value: rawptr, size: uint, position: u32, options: c.int) -> c.int ---
	getattrlist :: proc(path: cstring, al: ^Attr_Request, buf: rawptr, size: uint, options: c.uint) -> c.int ---
	@(link_name = "pathconf")
	case_conf :: proc(path: cstring, name: c.int) -> c.long ---
}

// do_op does one op of the mutator's script to the real files.
@(private)
do_op :: proc(m: ^Churn, op: Op) -> string {
	heap := m.allocator
	// A path and a message, within what a path may be.
	space: [16384]u8
	scratch: mem.Arena
	mem.arena_init(&scratch, space[:])
	local := mem.arena_allocator(&scratch)

	switch op.kind {
	case .Create:
		path := fmt.aprintf("%s/%s", m.paths[op.parent], op.name, allocator = heap)
		m.paths[op.id] = path
		if why := make_file(path, op.size, .File, local); why != "" {
			return strings.clone(why, heap)
		}
	case .Delete:
		path := m.paths[op.id]
		if posix.unlink(c_string(path, local)) != .OK {
			return format_reason(heap, "unlink %s: %v", path, posix.errno())
		}
	case .Rename:
		from := m.paths[op.id]
		to := fmt.aprintf("%s/%s", m.paths[op.parent], op.name, allocator = heap)
		if posix.rename(c_string(from, local), c_string(to, local)) != 0 {
			why := format_reason(heap, "rename %s to %s: %v", from, to, posix.errno())
			delete(to, heap)
			return why
		}
		delete(from, heap)
		m.paths[op.id] = to
	case .Grow:
		path := m.paths[op.id]
		fd := posix.open(c_string(path, local), {.WRONLY, .APPEND})
		if fd == -1 {
			return format_reason(heap, "open %s: %v", path, posix.errno())
		}
		defer posix.close(fd)

		chunk: [4096]u8
		for &x, i in chunk {
			x = u8('z' - i % 26)
		}

		for left := op.size; left > 0; {
			n := posix.write(fd, raw_data(chunk[:]), uint(min(u64(len(chunk)), left)))
			if n <= 0 {
				return format_reason(heap, "append to %s: %v", path, posix.errno())
			}
			left -= u64(n)
		}
	}
	return ""
}
