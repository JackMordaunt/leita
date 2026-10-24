package walk_fuzz

import "core:fmt"
import "core:strings"

/*
The model says what a scan of a directory of the spec must find, from the
spec alone. Nothing here reads a disk.

A scan that starts at a directory counts that directory and what lies under it,
and stops at a mount: a mount node is counted as a mount and what it shows is
not read, whatever it is (a tmpfs is another filesystem, a bind is another view
of a directory that is counted where it is). A hard link group is one file with
the other names counted as extras. A directory a reader cannot open is counted
and not read, when the scan is not allowed past a mode of 0 (`denies`).

One bind is the exception, and it is the walk's rule and not a bug (walk's
read_linux.odin, `stops_at`): a bind is a mount because its tree is counted where
it lies, and a tree the scan is refused is counted nowhere else. So a bind of a
directory below an unreadable one, on the same filesystem as the bind, is walked
as the directory it appears to be, and its tree is read through it, with the
mounts inside it empty directories (a bind made without --rbind shows none of
them). Of several binds of that tree, or of trees one inside another, only the
one with the shortest way in, and of those the earliest made, is walked and
the others are mounts (`hidden_peer`).

On Windows a bind is made as a junction (materialise_windows.odin), and the walk
records a junction as a link it does not follow, so there a bind counts as a
symlink and the rule above never applies. A tmpfs is an NTFS volume mounted in
the directory, which is a mount there as here.
*/

// JUNCTION_BINDS says whether a bind is made as a junction, which the walk counts as a link.
JUNCTION_BINDS :: ODIN_OS == .Windows

// Tally is what a scan finds.
Tally :: struct {
	files:    int, // regular files, a hard link group once
	extras:   int, // further names of a file already counted
	dirs:     int, // directories, the start included, mounts not
	symlinks: int, // symbolic links, followed or not
	mounts:   int, // mount points, recorded and not read
	unread:   int, // directories whose contents the scan could not read
	apparent: u64, // the sizes of `files`
}

// expected is the tally of a scan of the directory `start`, and the node of one
// name for each file counted, which is where a materialised tree can be asked
// for what a file really occupies.
expected :: proc(spec: Spec, start: int, denies: bool, allocator := context.temp_allocator) -> (t: Tally, files: []int) {
	reps := make([dynamic]int, allocator)
	// A group is named by the file it links to, and the first name met is its
	// representative. Names seen later are extras.
	seen := make(map[int]bool, allocator)
	t.dirs = 1
	read(spec, start, start, denies, false, &t, &reps, &seen)
	return t, reps[:]
}

// read counts what lies in `dir` for a scan from `start`. In a view, the tree a
// bind shows, a mount is the empty directory under it.
@(private)
read :: proc(spec: Spec, start, dir: int, denies, view: bool, t: ^Tally, reps: ^[dynamic]int, seen: ^map[int]bool) {
	for id in children(spec, dir) {
		n, _ := find(spec, id)
		switch n.kind {
		case .File, .Sparse, .Scatter, .Link:
			group := n.target if n.kind == .Link else n.id
			if seen[group] {
				t.extras += 1
			} else {
				seen[group] = true
				t.files += 1
				file, _ := find(spec, group)
				t.apparent += file.size
				append(reps, n.id)
			}
		case .Dir:
			t.dirs += 1
			read(spec, start, id, denies, view, t, reps, seen)
		case .Unreadable:
			t.dirs += 1
			if denies {
				t.unread += 1
			} else {
				read(spec, start, id, denies, view, t, reps, seen)
			}
		case .Symlink, .Dangling:
			t.symlinks += 1
		case .Mount:
			switch {
			case JUNCTION_BINDS && n.mount == .Bind:
				t.symlinks += 1
			case view:
				t.dirs += 1
			case walks_bind(spec, n, start, denies):
				t.dirs += 1
				read(spec, start, n.target, denies, true, t, reps, seen)
			case:
				t.mounts += 1
			}
		}
	}
}

// reachable says whether a scan can start at a directory: not through an
// unreadable one the scan is denied.
reachable :: proc(spec: Spec, id: int, denies: bool) -> bool {
	at := id
	for at != NONE {
		n, ok := find(spec, at)
		if !ok {
			return false
		}
		if n.kind == .Unreadable && denies {
			return false
		}
		at = n.parent
	}
	return true
}

// starts are the directories scans begin at: the root, and every tmpfs the scan
// can reach, so a mount is also walked from inside, as the card 668 walk was.
starts :: proc(spec: Spec, denies: bool, limit: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	append(&out, 0)
	for n in spec.nodes {
		if len(out) >= limit {
			break
		}
		if n.kind == .Mount && n.mount == .Tmpfs && reachable(spec, n.id, denies) {
			append(&out, n.id)
		}
	}
	return out[:]
}

/*
expected_flat is the same tally worked out another way, node by node and
looking up the chain of parents, not by descending. The model check compares
the two, so a mistake in the rules has to be made twice.
*/
expected_flat :: proc(spec: Spec, start: int, denies: bool, allocator := context.temp_allocator) -> Tally {
	t: Tally
	t.dirs = 1
	seen := make(map[int]int, allocator) // group -> names seen
	count_below(spec, start, start, denies, false, &t, &seen)
	for b in spec.nodes {
		if b.kind == .Mount && b.id != start && below(spec, b.id, start, denies) && walks_bind(spec, b, start, denies) {
			t.dirs += 1
			count_below(spec, start, b.target, denies, true, &t, &seen)
		}
	}

	for group, names in seen {
		file, _ := find(spec, group)
		t.files += 1
		t.extras += names - 1
		t.apparent += file.size
	}
	return t
}

// count_below adds what the nodes below `place` come to, for a scan from `start`.
@(private)
count_below :: proc(spec: Spec, start, place: int, denies, view: bool, t: ^Tally, seen: ^map[int]int) {
	for n in spec.nodes {
		if n.id == place || !below(spec, n.id, place, denies) {
			continue
		}
		switch n.kind {
		case .Dir:
			t.dirs += 1
		case .Unreadable:
			t.dirs += 1
			if denies {
				t.unread += 1
			}
		case .Symlink, .Dangling:
			t.symlinks += 1
		case .Mount:
			switch {
			case JUNCTION_BINDS && n.mount == .Bind:
				t.symlinks += 1
			case view:
				t.dirs += 1
			case !walks_bind(spec, n, start, denies):
				t.mounts += 1
			}
		case .File, .Sparse, .Scatter:
			seen[n.id] += 1
		case .Link:
			seen[n.target] += 1
		}
	}
}

// below says whether the scan from `start` reads the node: start is above it
// and no mount, nor an unreadable directory the scan is denied, lies between.
@(private)
below :: proc(spec: Spec, id, start: int, denies: bool) -> bool {
	at, _ := find(spec, id)
	for at.parent != NONE {
		if at.parent == start {
			return true
		}
		p, _ := find(spec, at.parent)
		if p.kind == .Mount || (p.kind == .Unreadable && denies) {
			return false
		}
		at = p
	}
	return false
}

/*
walks_bind says whether a scan from `start` walks the mount node `b` as the
directory it appears to be: it is a bind of a directory below an unreadable one
that the scan is denied, on the filesystem the bind is on (another one is a
mount by its device), and no other bind shows its tree in a place the scan can
open (`hidden_peer`).
*/
walks_bind :: proc(spec: Spec, b: Node, start: int, denies: bool) -> bool {
	if JUNCTION_BINDS || !hidden(spec, b, denies) || domain(spec, b.target) != domain(spec, b.parent) {
		return false
	}
	return !hidden_peer(spec, b, start, denies)
}

// hidden says whether a bind shows a tree the scan cannot open by its own path.
@(private)
hidden :: proc(spec: Spec, b: Node, denies: bool) -> bool {
	return denies && b.mount == .Bind && under_unreadable(spec, b.target)
}

// hidden_peer says whether another bind shows the tree of `b` at a path the
// scan can open, so that `b` is a mount: the other bind is of the same
// directory and was made first, or of a directory above it with no unreadable
// one between, and lies at or under the start with none between.
@(private)
hidden_peer :: proc(spec: Spec, b: Node, start: int, denies: bool) -> bool {
	for p, i in spec.nodes {
		if p.id == b.id || p.kind != .Mount || !hidden(spec, p, denies) || domain(spec, p.target) != domain(spec, b.target) {
			continue
		}
		if p.target == b.target && i > index_of(spec, b.id) {
			continue
		}
		if !opens_to(spec, b.target, p.target) || !visible_from(spec, p.id, start, denies) {
			continue
		}
		return true
	}
	return false
}

@(private)
index_of :: proc(spec: Spec, id: int) -> int {
	for n, i in spec.nodes {
		if n.id == id {
			return i
		}
	}
	return -1
}

// opens_to says whether `from` is `above` or lies below it, with no unreadable
// directory on the way, so a path from `above` down to `from` can be opened.
@(private)
opens_to :: proc(spec: Spec, from, above: int) -> bool {
	at := from
	for at != NONE {
		if at == above {
			return true
		}
		n, ok := find(spec, at)
		if !ok || n.kind == .Unreadable || n.kind == .Mount {
			return false
		}
		at = n.parent
	}
	return false
}

// visible_from says whether the node lies at or under `start` by its path, with
// no directory the scan is denied between: a mount does not hide it.
@(private)
visible_from :: proc(spec: Spec, id, start: int, denies: bool) -> bool {
	at, ok := find(spec, id)
	for ok && at.parent != NONE {
		if at.parent == start {
			return true
		}
		at, ok = find(spec, at.parent)
		if ok && at.kind == .Unreadable && denies {
			return false
		}
	}
	return false
}

// differ lists what two tallies disagree on, "" where they do not.
differ :: proc(want, got: Tally, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	check :: proc(b: ^strings.Builder, what: string, want, got: $T) {
		if want != got {
			if strings.builder_len(b^) > 0 {
				strings.write_string(b, "; ")
			}
			fmt.sbprintf(b, "%s want %v got %v", what, want, got)
		}
	}
	check(&b, "files", want.files, got.files)
	check(&b, "extra names", want.extras, got.extras)
	check(&b, "dirs", want.dirs, got.dirs)
	check(&b, "symlinks", want.symlinks, got.symlinks)
	check(&b, "mounts", want.mounts, got.mounts)
	check(&b, "unread", want.unread, got.unread)
	return strings.to_string(b)
}
