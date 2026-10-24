package walk_fuzz

import "base:runtime"
import "core:fmt"
import "core:strings"

import harness "jm:fuzz"

/*
A tree spec says what a filesystem holds and where it is mounted, without
making any of it. The spec is the unit everything else works on: the generator
draws one from a case's bytes, the model computes what a scan must report from
it, the materialiser builds it, and the shrinker makes it smaller by editing it,
so a failure ends as a few readable lines and not as bytes.

Nodes are stored flat. Node 0 is the root directory. A node's parent is the id
of a directory, a tmpfs mount or the root, and comes earlier in the slice, so a
reader can build in order. Ids and names are fixed when the node is drawn and
survive shrinking: the f7 of a minimal spec is the f7 of the case that failed.

New kinds of input plug in here: a kind of node is a Kind and the one place
that makes its plain name is `name_of`. Strange names, sizes and link storms are
made over a drawn tree by `make_strange` (strange.odin), which touches neither
the model's rules for a drawn tree nor the shrinker.
*/

// Kind is what a node is. The order is the draw order: a zero byte gives the
// first, and a plain empty file is the simplest thing a directory can hold.
Kind :: enum u8 {
	File, // a regular file of `size` bytes, all of them written
	Dir,
	Sparse, // a regular file of `size` bytes apparent, almost all a hole
	Link, // a hard link: another name for the file or sparse file `target`
	Symlink, // a symbolic link to the node `target`
	Dangling, // a symbolic link to nothing
	Unreadable, // a directory with mode 0 holding whatever its children say
	Mount, // a mount point, of `mount` kind
	// Last, so the draw table above keeps its meaning for the cases saved in the
	// corpus: it is made from a File by `make_strange`, not drawn.
	Scatter, // a regular file of `size` bytes apparent, written in pieces with holes between: many extents
}

// Mount_Kind is what is mounted on a Mount node.
Mount_Kind :: enum u8 {
	Tmpfs, // a new empty tmpfs, which the node's children are made in
	Bind, // a bind of the directory `target`; it holds nothing of its own
}

NONE :: -1

Node :: struct {
	id:     int,
	parent: int,
	name:   string,
	kind:   Kind,
	mount:  Mount_Kind,
	size:   u64, // File, Sparse: the apparent size
	// Link: the file; Symlink: the node; Bind: the directory; a File, Sparse or
	// Scatter: the file it is a clone of, NONE for one that is no clone.
	target: int,
	fork:   Fork, // File, Sparse, Scatter: what it carries besides its data
}

/*
A clone is a regular file made from another one on its filesystem, of the same
kind, size and fork, and a name of its own. Where the filesystem shares blocks
between files (APFS clonefile), the clone shares all of its data; where it
cannot, the materialiser makes a copy. The model counts a clone as a file of its
own either way, and what it occupies is the materialiser's to say (`allocated`):
the bytes it shares are charged once.
*/

// Fork is what a file carries besides its data. macOS writes an extended
// attribute or a resource fork; a materialiser with neither makes none, and
// the model needs nothing of it.
Fork :: enum u8 {
	None,
	Xattr, // an extended attribute of XATTR_BYTES, more than APFS keeps in the inode
	Resource, // a resource fork of RESOURCE_BYTES, which takes blocks of its own
}

XATTR_BYTES :: 20000
RESOURCE_BYTES :: 65536

Spec :: struct {
	nodes: []Node,
}

// FILE_SIZES is what a written file may be. Zero is first so shrinking ends at
// an empty file; the rest straddle a block (4096) and a page.
FILE_SIZES := []u64{0, 1, 511, 4096, 4097, 65536, 1 << 20}

// SPARSE_SIZES is the apparent size of a sparse file, from small to larger than
// any disk here.
SPARSE_SIZES := []u64{4096, 1 << 20, 1 << 30, 1 << 34}

KINDS := []Kind{.File, .Dir, .Sparse, .Link, .Symlink, .Dangling, .Unreadable, .Mount}

MOUNT_KINDS := []Mount_Kind{.Tmpfs, .Bind}

// BOUNDARY_SIZES are sizes a written file is made at for `make_strange`: either side of
// a block, of two, of a page of the walk's buffers, and one past a mebibyte.
BOUNDARY_SIZES := []u64{4095, 4096, 4097, 8191, 8193, 65535, 65537, 1 << 20 + 1}

// SPARSE_EDGES are the apparent sizes of a hole around where a 32-bit count
// wraps, and a terabyte.
SPARSE_EDGES := []u64{1, 4097, 1 << 31 - 1, 1 << 32, 1 << 32 + 1, 1 << 40}

// SCATTER_SIZES are the apparent sizes of a file written in pieces.
SCATTER_SIZES := []u64{4097, 65537, 1 << 20, 1 << 24}

// MAX_NODES is how many nodes besides the root the plain draw makes; `make_strange`
// adds at most 12 links on top.
MAX_NODES :: 24

// NAME_MAX is the longest name in bytes (limits.h NAME_MAX; ext4 and tmpfs take it).
NAME_MAX :: 255

// draw makes a spec from the bytes src gives. Zero bytes give a root alone;
// every choice is ordered simplest first, so a zero byte stays the simplest tree.
draw :: proc(src: ^harness.Source, allocator := context.allocator) -> Spec {
	nodes := make([dynamic]Node, 0, MAX_NODES + 1, allocator)
	append(&nodes, Node{id = 0, parent = NONE, kind = .Dir, target = NONE})
	count := harness.integer_in(src, 0, MAX_NODES + 1)
	holders := make([dynamic]int, 0, MAX_NODES + 1, context.temp_allocator)
	for i in 1 ..= count {
		clear(&holders)
		for n in nodes {
			if can_hold(n) {
				append(&holders, n.id)
			}
		}
		n := Node {
			id     = i,
			parent = harness.choice(src, holders[:]),
			kind   = harness.choice(src, KINDS),
			target = NONE,
		}
		spec := Spec{nodes[:]}
		switch n.kind {
		case .File:
			n.size = harness.choice(src, FILE_SIZES)
		case .Sparse:
			n.size = harness.choice(src, SPARSE_SIZES)
		case .Link:
			files := linkable_files(spec, domain(spec, n.parent))
			if len(files) == 0 {
				// Nothing to link to here: a file with nothing in it.
				n.kind = .File
			} else {
				n.target = harness.choice(src, files)
			}
		case .Symlink:
			n.target = harness.choice(src, ids(spec))
		case .Dangling:
		case .Dir, .Unreadable, .Scatter:
		case .Mount:
			n.mount = harness.choice(src, MOUNT_KINDS)
			if n.mount == .Bind {
				n.target = harness.choice(src, plain_dirs(spec))
			}
		}
		n.name = name_of(n, allocator)
		append(&nodes, n)
	}

	make_strange(&nodes, src, allocator)
	return {nodes[:]}
}

// name_of is a node's name: short, unique in its directory because the id is in
// it, and a hint of what it is.
name_of :: proc(n: Node, allocator := context.allocator) -> string {
	prefix: string
	switch n.kind {
	case .File:
		prefix = "f"
	case .Dir:
		prefix = "d"
	case .Sparse:
		prefix = "s"
	case .Link:
		prefix = "l"
	case .Symlink:
		prefix = "y"
	case .Dangling:
		prefix = "x"
	case .Unreadable:
		prefix = "u"
	case .Mount:
		prefix = "t" if n.mount == .Tmpfs else "b"
	case .Scatter:
		prefix = "e"
	}
	if is_clone(n) {
		prefix = "c"
	}
	return fmt.aprintf("%s%d", prefix, n.id, allocator = allocator)
}

// holds says whether a node can have children.
can_hold :: proc(n: Node) -> bool {
	return n.kind == .Dir || n.kind == .Unreadable || (n.kind == .Mount && n.mount == .Tmpfs)
}

// is_file says whether a node is a regular file's own name, not a link.
is_file :: proc(n: Node) -> bool {
	return n.kind == .File || n.kind == .Sparse || n.kind == .Scatter
}

// is_clone says whether a node is a file made as a clone of another.
is_clone :: proc(n: Node) -> bool {
	return is_file(n) && n.target != NONE
}

// cloned says whether a clone was made of the file `id`.
cloned :: proc(spec: Spec, id: int) -> bool {
	for n in spec.nodes {
		if is_clone(n) && n.target == id {
			return true
		}
	}
	return false
}

find :: proc(spec: Spec, id: int) -> (node: Node, ok: bool) {
	for n in spec.nodes {
		if n.id == id {
			return n, true
		}
	}
	return {}, false
}

// domain is the filesystem a directory lies on, by the id of the tmpfs mount
// that makes it, or 0 for the one the root is on. A hard link stays inside one.
domain :: proc(spec: Spec, dir: int) -> int {
	at := dir
	for at != NONE {
		n, ok := find(spec, at)
		if !ok {
			return 0
		}
		if n.kind == .Mount && n.mount == .Tmpfs {
			return n.id
		}
		at = n.parent
	}
	return 0
}

// linkable_files are the files in domain a hard link may name.
linkable_files :: proc(spec: Spec, in_domain: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for n in spec.nodes {
		if is_file(n) && domain(spec, n.parent) == in_domain {
			append(&out, n.id)
		}
	}
	return out[:]
}

// plain_dirs are the directories a bind is drawn of: the root and every Dir that
// no unreadable directory lies above. A bind of one below an unreadable
// directory is made by `make_strange` (the walk treats it differently, and the
// model says how, in walks_bind), so a corpus case saved before it draws the
// same binds it always did.
plain_dirs :: proc(spec: Spec, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for n in spec.nodes {
		if n.kind == .Dir && !under_unreadable(spec, n.id) {
			append(&out, n.id)
		}
	}
	return out[:]
}

// all_dirs are every directory a bind may show.
all_dirs :: proc(spec: Spec, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for n in spec.nodes {
		if n.kind == .Dir {
			append(&out, n.id)
		}
	}
	return out[:]
}

under_unreadable :: proc(spec: Spec, id: int) -> bool {
	at := id
	for at != NONE {
		n, ok := find(spec, at)
		if !ok {
			return false
		}
		if n.kind == .Unreadable {
			return true
		}
		at = n.parent
	}
	return false
}

ids :: proc(spec: Spec, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, len(spec.nodes), allocator)
	for n in spec.nodes {
		append(&out, n.id)
	}
	return out[:]
}

// children are the ids of what a node holds, in spec order.
children :: proc(spec: Spec, id: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for n in spec.nodes {
		if n.parent == id {
			append(&out, n.id)
		}
	}
	return out[:]
}

// path_of is a node's path below the spec's root, "" for the root.
path_of :: proc(spec: Spec, id: int, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, allocator)
	at := id
	for at != NONE {
		n, ok := find(spec, at)
		if !ok {
			break
		}
		if n.parent != NONE {
			append(&parts, n.name)
		}
		at = n.parent
	}
	b := strings.builder_make(allocator)
	for i := len(parts) - 1; i >= 0; i -= 1 {
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, '/')
		}
		strings.write_string(&b, parts[i])
	}
	return strings.to_string(b)
}

// format_reason formats the reason a spec or a step is turned down.
format_reason :: proc(allocator: runtime.Allocator, format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args, allocator = allocator)
}

// valid says whether a spec obeys the rules the model and the materialiser rest
// on. A drawn spec always does; a shrunk one is checked, so a step that breaks a
// rule is not taken.
valid :: proc(spec: Spec, allocator := context.temp_allocator) -> (why: string, ok: bool) {
	if len(spec.nodes) == 0 || spec.nodes[0].id != 0 || spec.nodes[0].kind != .Dir {
		return "node 0 is not the root directory", false
	}
	seen := make(map[int]bool, allocator)
	names := make(map[string]bool, allocator)
	for n, i in spec.nodes {
		if seen[n.id] {
			return format_reason(allocator, "id %d twice", n.id), false
		}
		if i > 0 {
			p, found := find(spec, n.parent)
			if !found || !seen[p.id] || !can_hold(p) {
				return format_reason(allocator, "%s: its parent %d is not a directory before it", n.name, n.parent), false
			}
			key := format_reason(allocator, "%d/%s", n.parent, n.name)
			if names[key] {
				return format_reason(allocator, "%s: the name is taken", n.name), false
			}
			names[key] = true
		}
		seen[n.id] = true
		if i > 0 {
			if reason := name_fault(n.name); reason != "" {
				return format_reason(allocator, "%q: %s", n.name, reason), false
			}
		}
		if n.fork != .None && !is_file(n) {
			return format_reason(allocator, "%s: a fork on what is not a file", n.name), false
		}
		if is_clone(n) {
			t, found := find(spec, n.target)
			if !found || !is_file(t) || is_clone(t) || t.kind != n.kind || t.size != n.size || t.fork != n.fork {
				return format_reason(allocator, "%s: a clone of %d, which is not a file like it", n.name, n.target), false
			}
			if domain(spec, t.parent) != domain(spec, n.parent) {
				return format_reason(allocator, "%s: a clone across filesystems", n.name), false
			}
		}
		switch n.kind {
		case .Link:
			t, found := find(spec, n.target)
			if !found || !is_file(t) {
				return format_reason(allocator, "%s: links to %d, which is not a file", n.name, n.target), false
			}
			if domain(spec, t.parent) != domain(spec, n.parent) {
				return format_reason(allocator, "%s: links across filesystems", n.name), false
			}
		case .Symlink:
			if _, found := find(spec, n.target); !found {
				return format_reason(allocator, "%s: points at %d, which is not there", n.name, n.target), false
			}
		case .Mount:
			if n.mount == .Bind {
				if t, found := find(spec, n.target); !found || t.kind != .Dir {
					return format_reason(allocator, "%s: binds %d, which is not a directory", n.name, n.target), false
				}
			}
		case .File, .Dir, .Sparse, .Dangling, .Unreadable, .Scatter:
		}
	}
	return "", true
}

// render writes a spec as the tree it is, one node a line, for a person.
render :: proc(spec: Spec, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	render_dir(&b, spec, 0, 0, allocator)
	return strings.to_string(b)
}

// quoted is a name quoted, and cut short in the middle when it is long: the
// rendering of a 255-byte name is not worth the lines.
@(private)
quoted :: proc(name: string, allocator := context.temp_allocator) -> string {
	if len(name) <= 48 {
		return fmt.aprintf("%q", name, allocator = allocator)
	}
	return fmt.aprintf("%q...%q (%d bytes)", name[:24], name[len(name) - 8:], len(name), allocator = allocator)
}

// target_name is how the rendering names a node another refers to: its path
// below the root, "/" for the root.
@(private)
target_name :: proc(spec: Spec, id: int, allocator := context.temp_allocator) -> string {
	if id == 0 {
		return "\"/\""
	}
	return quoted(path_of(spec, id, allocator), allocator)
}

@(private)
render_dir :: proc(b: ^strings.Builder, spec: Spec, id, depth: int, allocator: runtime.Allocator) {
	n, _ := find(spec, id)
	for _ in 0 ..< depth {
		strings.write_string(b, "  ")
	}
	if id == 0 {
		strings.write_string(b, "/ dir\n")
	} else {
		fmt.sbprintf(b, "%s ", quoted(n.name, allocator))
		switch n.kind {
		case .File:
			fmt.sbprintf(b, "file %d bytes", n.size)
		case .Scatter:
			fmt.sbprintf(b, "file %d bytes apparent, written in pieces", n.size)
		case .Sparse:
			fmt.sbprintf(b, "sparse file %d bytes apparent", n.size)
		case .Dir:
			strings.write_string(b, "dir")
		case .Unreadable:
			strings.write_string(b, "unreadable dir")
		case .Link:
			fmt.sbprintf(b, "hard link to %s", target_name(spec, n.target, allocator))
		case .Symlink:
			fmt.sbprintf(b, "symlink to %s", target_name(spec, n.target, allocator))
		case .Dangling:
			strings.write_string(b, "dangling symlink")
		case .Mount:
			if n.mount == .Tmpfs {
				strings.write_string(b, "mount tmpfs")
			} else {
				fmt.sbprintf(b, "mount bind of %s", target_name(spec, n.target, allocator))
			}
		}
		if is_clone(n) {
			fmt.sbprintf(b, ", a clone of %s", target_name(spec, n.target, allocator))
		}
		switch n.fork {
		case .None:
		case .Xattr:
			fmt.sbprintf(b, ", an xattr of %d bytes", XATTR_BYTES)
		case .Resource:
			fmt.sbprintf(b, ", a resource fork of %d bytes", RESOURCE_BYTES)
		}
		strings.write_byte(b, '\n')
	}
	for c in children(spec, id, allocator) {
		render_dir(b, spec, c, depth + 1, allocator)
	}
}

/*
Shrinking edits the spec, never the bytes. `shrink_steps` lists every spec one step
simpler than the one given, the most useful first: drop a subtree, collapse a
mount to a plain directory, lift a node out of its directory, turn a special file into a plain one, remove a hard
link, make a clone a file of its own, drop a fork, make a file smaller. The caller takes the first that still fails and asks
again, until none does.
*/
shrink_steps :: proc(spec: Spec, allocator := context.temp_allocator) -> []Spec {
	out := make([dynamic]Spec, allocator)
	// Biggest removals first: the last nodes are the leaves, the first the
	// roots of whole subtrees, so go through the ids in order.
	for n in spec.nodes[1:] {
		if s, ok := without(spec, n.id, allocator); ok {
			append(&out, s)
		}
	}
	// Out of its directory into the one above, so a chain of directories
	// between two mounts goes without losing them.
	for n, i in spec.nodes {
		if n.id == 0 || n.parent == 0 {
			continue
		}
		up, _ := find(spec, n.parent)
		nodes := copy_nodes(spec, allocator)
		nodes[i].parent = up.parent
		append(&out, Spec{nodes})
	}
	// A name that is only a name goes back to the plain one.
	for n, i in spec.nodes[1:] {
		if plain := name_of(n, allocator); plain != n.name {
			nodes := copy_nodes(spec, allocator)
			nodes[i + 1].name = plain
			append(&out, Spec{nodes})
		}
	}
	for n, i in spec.nodes {
		if is_clone(n) {
			nodes := copy_nodes(spec, allocator)
			nodes[i].target = NONE
			nodes[i].name = name_of(nodes[i], allocator)
			append(&out, Spec{nodes})
		}
		if n.fork != .None && !is_clone(n) {
			// A clone has the fork of what it is a clone of, so both go together.
			nodes := copy_nodes(spec, allocator)
			for &m in nodes {
				if m.id == n.id || (is_clone(m) && m.target == n.id) {
					m.fork = .None
				}
			}
			append(&out, Spec{nodes})
		}
		switch n.kind {
		case .Mount:
			// A tmpfs collapses into a directory holding the same things, a
			// bind into an empty one.
			append(&out, change(spec, i, {kind = .Dir}, allocator))
		case .Unreadable:
			append(&out, change(spec, i, {kind = .Dir}, allocator))
		case .Sparse, .Scatter:
			append(&out, change(spec, i, {kind = .File, size = 0}, allocator))
		case .Link, .Symlink, .Dangling:
			append(&out, change(spec, i, {kind = .File, size = 0}, allocator))
		case .File:
			for size in FILE_SIZES {
				if size < n.size {
					append(&out, change(spec, i, {kind = .File, size = size}, allocator))
					break
				}
			}
		case .Dir:
		}
		if n.kind == .Sparse {
			for size in SPARSE_SIZES {
				if size < n.size {
					append(&out, change(spec, i, {kind = .Sparse, size = size}, allocator))
					break
				}
			}
		}
		if n.kind == .Scatter {
			for size in SCATTER_SIZES {
				if size < n.size {
					append(&out, change(spec, i, {kind = .Scatter, size = size}, allocator))
					break
				}
			}
		}
	}
	return out[:]
}

// Edit is what changed says to put in a node: its kind and size, nothing else
// kept of what it was. A node that stops being a link, a symlink or a mount
// loses its target.
@(private)
Edit :: struct {
	kind: Kind,
	size: u64,
}

@(private)
change :: proc(spec: Spec, at: int, e: Edit, allocator := context.temp_allocator) -> Spec {
	nodes := copy_nodes(spec, allocator)
	nodes[at].kind = e.kind
	nodes[at].size = e.size
	nodes[at].target = NONE
	nodes[at].mount = .Tmpfs
	nodes[at].fork = .None
	// The name keeps its id and says what the node now is.
	nodes[at].name = name_of(nodes[at], allocator)
	return {nodes}
}

@(private)
copy_nodes :: proc(spec: Spec, allocator := context.temp_allocator) -> []Node {
	nodes := make([]Node, len(spec.nodes), allocator)
	copy(nodes, spec.nodes)
	return nodes
}

// without removes a node, what it holds, and whatever names it: a link to a
// removed file, a bind of a removed directory, a symlink to a removed node.
// False when that leaves the root alone with nothing removed, or the spec invalid.
without :: proc(spec: Spec, id: int, allocator := context.temp_allocator) -> (Spec, bool) {
	gone := make(map[int]bool, allocator)
	gone[id] = true
	for again := true; again; {
		again = false
		for n in spec.nodes {
			if gone[n.id] {
				continue
			}
			if gone[n.parent] || (n.target != NONE && gone[n.target]) {
				gone[n.id] = true
				again = true
			}
		}
	}
	nodes := make([dynamic]Node, allocator)
	for n in spec.nodes {
		if !gone[n.id] {
			append(&nodes, n)
		}
	}
	out := Spec{nodes[:]}
	_, ok := valid(out, allocator)
	return out, ok
}

// minimise makes a spec as small as it can while `fails` stays true of it, in at
// most `budget` calls of fails. It returns the smallest it reached.
minimise :: proc(
	spec: Spec,
	fails: proc(s: Spec, data: rawptr) -> bool,
	data: rawptr,
	budget: int,
	allocator := context.temp_allocator,
) -> Spec {
	best := spec
	left := budget
	for progress := true; progress && left > 0; {
		progress = false
		for cand in shrink_steps(best, allocator) {
			if left == 0 {
				break
			}
			if _, ok := valid(cand, allocator); !ok {
				continue
			}
			left -= 1
			if fails(cand, data) {
				best = cand
				progress = true
				break
			}
		}
	}
	return best
}
