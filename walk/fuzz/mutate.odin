package walk_fuzz

import "base:runtime"
import "core:fmt"
import "core:strings"

import harness "jm:fuzz"

/*
A mutator changes a tree while a scan reads it. What it does is a list of ops
drawn from the case's bytes, applied in order to the real files by a thread
(materialise_linux.odin) and to a copy of the spec, so the spec after the last
op is known, and so is the most a scan under way may say.

A scan that runs while files come and go has no one right answer. It reads a
directory at one moment and the next directory at another, so it may see a file
renamed from one directory to another in both, or in neither unless it was
there the whole time. What it cannot do is report what never was. The bounds
(`Bounds`) are what it may report:

	names    a name, a directory entry for a file, was there from the start to
	         the end of the script, or it was there for a moment. A scan finds
	         every name of the first kind, and each placement of the second at
	         most once. Files and extra names together are names.
	files    the files are at least the inodes with a name of the first kind, and
	         at most the names a scan may meet: a file renamed under the scan
	         may be met at both ends, and one link is not recognised as the
	         same inode seen before, so it is two files.
	disk     the bytes allocated are at least those of the inodes found by a name
	         of the first kind, as they were before the first op (files only
	         grow), and at most what every inode that ever was can occupy, once
	         for each place the scan may meet it.
	the rest directories, symbolic links, mounts and directories unread are not
	         touched by an op, so they are exactly the model's.

Ops are limited to the names the model counts and a scan from the root reaches,
so those bounds are all there is to work out. Directories are never renamed or
removed: they would need the same bounds for every name below. A node that has
something named for it, a hard link or a symbolic link or a bind, is not
removed, so a spec after the ops is still one the model reads.
*/

Op_Kind :: enum u8 {
	Create, // a new file `name` of `size` bytes in `parent`
	Delete, // remove the file `id`
	Rename, // move the file `id` to `name` in `parent`, on the same filesystem
	Grow, // append `size` bytes to the file `id`
}

OP_KINDS := []Op_Kind{.Create, .Delete, .Rename, .Grow}

Op :: struct {
	kind:   Op_Kind,
	id:     int, // Create: the new node's id
	parent: int,
	name:   string,
	size:   u64,
}

// MAX_OPS is how many ops a script may hold.
MAX_OPS :: 32

// GROWTHS are what a file may grow by.
GROWTHS := []u64{1, 4095, 4096, 100000}

// draw_ops makes a script for a spec, and the spec after it. A zero byte gives an
// empty script.
draw_ops :: proc(spec: Spec, src: ^harness.Source, allocator := context.allocator) -> (ops: []Op, after: Spec) {
	sim := make([dynamic]Node, 0, len(spec.nodes) + MAX_OPS, allocator)
	append(&sim, ..spec.nodes)
	out := make([dynamic]Op, 0, MAX_OPS, allocator)
	next := 0
	for n in spec.nodes {
		next = max(next, n.id + 1)
	}
	count := harness.integer_in(src, 0, MAX_OPS + 1)
	for _ in 0 ..< count {
		kind := harness.choice(src, OP_KINDS)
		now := Spec{sim[:]}
		leaves := movable(now, context.temp_allocator)
		op := Op {
			kind = kind,
		}
		switch kind {
		case .Create:
			holders := reachable_dirs(now, context.temp_allocator)
			op.id = next
			op.parent = harness.choice(src, holders)
			op.size = harness.choice(src, FILE_SIZES)
			op.name = name_of(Node{id = op.id, kind = .File}, allocator)
		case .Delete:
			free := make([dynamic]int, context.temp_allocator)
			for id in leaves {
				if !named_by_another(now, id) {
					append(&free, id)
				}
			}
			if len(free) == 0 {
				continue
			}
			op.id = harness.choice(src, free[:])
		case .Rename:
			if len(leaves) == 0 {
				continue
			}
			op.id = harness.choice(src, leaves)
			op.parent = harness.choice(src, moves_to(now, op.id, context.temp_allocator))
			op.name = format_reason(allocator, "r%d_%d", op.id, len(out))
		case .Grow:
			grow := make([dynamic]int, context.temp_allocator)
			for id in leaves {
				// Not a clone, nor a file a clone was made of: the oracle charges a
				// clone's data once, which holds only while both are unwritten.
				if n, _ := find(now, id); n.kind == .File && n.size > 0 && !is_clone(n) && !cloned(now, id) {
					append(&grow, id)
				}
			}
			if len(grow) == 0 {
				continue
			}
			op.id = harness.choice(src, grow[:])
			op.size = harness.choice(src, GROWTHS)
		}
		if !apply_to_spec(&sim, op, allocator) {
			continue
		}
		if kind == .Create {
			next += 1
		}
		append(&out, op)
	}
	return out[:], Spec{sim[:]}
}

// replay applies a script to a spec and says what the spec is after it, false
// when an op does not apply (a shrunk spec or script lost what it names).
replay :: proc(spec: Spec, ops: []Op, allocator := context.temp_allocator) -> (after: Spec, ok: bool) {
	sim := make([dynamic]Node, 0, len(spec.nodes) + len(ops), allocator)
	append(&sim, ..spec.nodes)
	for op in ops {
		if !apply_to_spec(&sim, op, allocator) {
			return {}, false
		}
	}
	return Spec{sim[:]}, true
}

// apply_to_spec does an op to the spec in sim, false and nothing done when it
// does not apply.
@(private)
apply_to_spec :: proc(sim: ^[dynamic]Node, op: Op, allocator: runtime.Allocator) -> bool {
	now := Spec{sim[:]}
	switch op.kind {
	case .Create:
		parent, found := find(now, op.parent)
		if _, taken := find(now, op.id); taken || !found || !can_hold(parent) || parent.kind == .Unreadable || has_child_named(now, op.parent, op.name) {
			return false
		}
		if !reaches(now, op.parent) {
			return false
		}
		append(sim, Node{id = op.id, parent = op.parent, name = op.name, kind = .File, size = op.size, target = NONE})
	case .Delete:
		at := index_of(now, op.id)
		if at < 0 || !is_leaf_name(sim[at]) || named_by_another(now, op.id) || !reaches(now, sim[at].parent) {
			return false
		}
		ordered_remove(sim, at)
	case .Rename:
		at := index_of(now, op.id)
		if at < 0 || !is_leaf_name(sim[at]) || !reaches(now, sim[at].parent) {
			return false
		}
		to, found := find(now, op.parent)
		if !found || !can_hold(to) || to.kind == .Unreadable || !reaches(now, op.parent) || has_child_named(now, op.parent, op.name) {
			return false
		}
		if domain(now, op.parent) != domain(now, sim[at].parent) || index_of(now, op.parent) >= at {
			return false
		}
		sim[at].parent = op.parent
		sim[at].name = op.name
	case .Grow:
		at := index_of(now, op.id)
		if at < 0 || sim[at].kind != .File || sim[at].size == 0 || !reaches(now, sim[at].parent) {
			return false
		}
		sim[at].size += op.size
	}
	return true
}

// is_leaf_name says whether a node is a name the model counts, one of a file.
@(private)
is_leaf_name :: proc(n: Node) -> bool {
	return is_file(n) || n.kind == .Link
}

// reaches says whether a scan from the root reads the directory: nothing between
// is a mount or an unreadable directory.
@(private)
reaches :: proc(spec: Spec, dir: int) -> bool {
	if dir == 0 {
		return true
	}
	n, found := find(spec, dir)
	return found && n.kind == .Dir && below(spec, dir, 0, true)
}

// reachable_dirs are the directories a scan from the root reads, and so the ones
// an op may use.
@(private)
reachable_dirs :: proc(spec: Spec, allocator: runtime.Allocator) -> []int {
	out := make([dynamic]int, allocator)
	for n in spec.nodes {
		if n.kind == .Dir && reaches(spec, n.id) {
			append(&out, n.id)
		}
	}
	return out[:]
}

// movable are the names an op may remove, rename or grow: those in a directory
// the scan reads.
@(private)
movable :: proc(spec: Spec, allocator: runtime.Allocator) -> []int {
	out := make([dynamic]int, allocator)
	for n in spec.nodes {
		if is_leaf_name(n) && reaches(spec, n.parent) {
			append(&out, n.id)
		}
	}
	return out[:]
}

// moves_to are the directories a name may be renamed into: on its filesystem and
// before it in the spec, which is where a parent must lie.
@(private)
moves_to :: proc(spec: Spec, id: int, allocator: runtime.Allocator) -> []int {
	out := make([dynamic]int, allocator)
	at := index_of(spec, id)
	for n, i in spec.nodes {
		if i < at && n.kind == .Dir && reaches(spec, n.id) && domain(spec, n.id) == domain(spec, spec.nodes[at].parent) {
			append(&out, n.id)
		}
	}
	if len(out) == 0 {
		append(&out, spec.nodes[at].parent)
	}
	return out[:]
}

// named_by_another says whether a link, a symbolic link or a bind refers to the node.
@(private)
named_by_another :: proc(spec: Spec, id: int) -> bool {
	for n in spec.nodes {
		if n.target == id && n.id != id {
			return true
		}
	}
	return false
}

@(private)
has_child_named :: proc(spec: Spec, dir: int, name: string) -> bool {
	for n in spec.nodes {
		if n.parent == dir && n.name == name {
			return true
		}
	}
	return false
}

// Bounds are what a scan that ran while the ops were done may report.
Bounds :: struct {
	names:     [2]int, // files plus extra names
	files:     [2]int,
	disk_most: u64, // the most the inodes that ever were can occupy
	always:    []int, // a name present throughout, for each file present throughout: where to ask what it occupied
	exact:     Tally, // everything an op leaves alone
}

// bounds works out what a scan from the root may report, for a spec and the ops
// done to it while the scan ran.
bounds :: proc(spec: Spec, ops: []Op, denies: bool, allocator := context.temp_allocator) -> Bounds {
	b: Bounds
	whole, _ := expected(spec, 0, denies, allocator)
	b.exact = whole
	names := counted_names(spec, 0, denies, allocator)

	touched := make(map[int]bool, allocator)
	biggest := make(map[int]u64, allocator)
	for n in spec.nodes {
		if is_file(n) {
			biggest[n.id] = n.size
		}
	}
	for op in ops {
		switch op.kind {
		case .Create:
			touched[op.id] = true
			biggest[op.id] = op.size
		case .Delete:
			touched[op.id] = true
		case .Rename:
			touched[op.id] = true
		case .Grow:
			// Files only grow, so the size it reached is the most it was.
			biggest[op.id] += op.size
		}
	}
	steady := make(map[int]int, allocator) // group -> names present throughout
	groups := make(map[int]bool, allocator)
	placed := make(map[int]int, allocator) // node -> places a scan may meet it
	untouched := 0
	for id in names {
		n, _ := find(spec, id)
		group := n.target if n.kind == .Link else n.id
		groups[group] = true
		if touched[id] {
			placed[id] += 1
		} else {
			untouched += 1
			steady[group] += 1
		}
	}
	for op in ops {
		if op.kind == .Create || op.kind == .Rename {
			placed[op.id] += 1
		}
	}
	always := make([dynamic]int, allocator)
	for id in names {
		n, _ := find(spec, id)
		group := n.target if n.kind == .Link else n.id
		if !touched[id] && steady[group] > 0 {
			steady[group] = 0
			append(&always, id)
		}
	}
	// A file moved while the scan is under way may be met at both ends of the move,
	// and an inode with one name is not recognised as met before, so it is a file
	// and a charge each time.
	places := 0
	for _, count in placed {
		places += count
	}
	b.names = {untouched, untouched + places}
	b.files = {len(always), untouched + places}
	b.always = always[:]
	for group in groups {
		b.disk_most += room(biggest[group])
	}
	for id, count in placed {
		n, found := find(spec, id)
		group := n.target if found && n.kind == .Link else id
		b.disk_most += u64(count) * room(biggest[group])
	}
	return b
}

// room is the most a file of this apparent size may occupy: its blocks rounded up
// to a page, and a megabyte over for what a filesystem keeps back.
@(private)
room :: proc(size: u64) -> u64 {
	return (size + 4095) / 4096 * 4096 + 1 << 20
}

// counted_names are the nodes a scan from `start` counts as the files and extra
// names it finds: every name it reads, through a bind it walks too.
counted_names :: proc(spec: Spec, start: int, denies: bool, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for n in spec.nodes {
		if is_leaf_name(n) && below(spec, n.id, start, denies) {
			append(&out, n.id)
		}
	}
	for b in spec.nodes {
		if b.kind != .Mount || b.id == start || !below(spec, b.id, start, denies) || !walks_bind(spec, b, start, denies) {
			continue
		}
		for n in spec.nodes {
			if is_leaf_name(n) && below(spec, n.id, b.target, denies) {
				append(&out, n.id)
			}
		}
	}
	return out[:]
}

// bounds_fault says what is wrong with a scan that ran during the ops, "" if it is
// within the bounds. `disk_least` is what the files present throughout occupied
// before the first op.
bounds_fault :: proc(b: Bounds, got: Tally, disk, disk_least: u64, allocator := context.temp_allocator) -> string {
	why := make([dynamic]string, allocator)
	// What no op touches is exact. Files and extra names move with the ops.
	fixed := b.exact
	fixed.files, fixed.extras = got.files, got.extras
	if d := differ(fixed, got, allocator); d != "" {
		append(&why, d)
	}
	if names := got.files + got.extras; names < b.names[0] || names > b.names[1] {
		append(&why, fmt.aprintf("names (files and extra names) %d, outside %d to %d", names, b.names[0], b.names[1], allocator = allocator))
	}
	if got.files < b.files[0] || got.files > b.files[1] {
		append(&why, fmt.aprintf("files %d, outside %d to %d", got.files, b.files[0], b.files[1], allocator = allocator))
	}
	if disk < disk_least || disk > b.disk_most {
		append(&why, fmt.aprintf("allocated %d bytes, outside %d to %d", disk, disk_least, b.disk_most, allocator = allocator))
	}
	return strings.join(why[:], "; ", allocator)
}

// show_ops writes a script as it would be read.
show_ops :: proc(ops: []Op, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for op, i in ops {
		switch op.kind {
		case .Create:
			fmt.sbprintf(&b, "%d  create %s (%d bytes) in dir %d\n", i, op.name, op.size, op.parent)
		case .Delete:
			fmt.sbprintf(&b, "%d  delete node %d\n", i, op.id)
		case .Rename:
			fmt.sbprintf(&b, "%d  rename node %d to %s in dir %d\n", i, op.id, op.name, op.parent)
		case .Grow:
			fmt.sbprintf(&b, "%d  grow node %d by %d bytes\n", i, op.id, op.size)
		}
	}
	return strings.to_string(b)
}
