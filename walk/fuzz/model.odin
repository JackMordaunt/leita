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
*/

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
	read(spec, start, denies, &t, &reps, &seen)
	return t, reps[:]
}

@(private)
read :: proc(spec: Spec, dir: int, denies: bool, t: ^Tally, reps: ^[dynamic]int, seen: ^map[int]bool) {
	for id in children(spec, dir) {
		n, _ := find(spec, id)
		switch n.kind {
		case .File, .Sparse, .Link:
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
			read(spec, id, denies, t, reps, seen)
		case .Unreadable:
			t.dirs += 1
			if denies {
				t.unread += 1
			} else {
				read(spec, id, denies, t, reps, seen)
			}
		case .Symlink, .Dangling:
			t.symlinks += 1
		case .Mount:
			t.mounts += 1
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
	for n in spec.nodes {
		if n.id == start || !below(spec, n.id, start, denies) {
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
			t.mounts += 1
		case .File, .Sparse:
			seen[n.id] += 1
		case .Link:
			seen[n.target] += 1
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
