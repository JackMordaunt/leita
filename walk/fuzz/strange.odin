package walk_fuzz

import "base:runtime"
import "core:strings"

import harness "jm:fuzz"

/*
Strange inputs are made after the plain tree is drawn, from the bytes the plain
draw left, and change a drawn tree without changing its shape: which node is a
mount, a directory or a file, and where each lies, stay what the draw said. So a
regression saved before this existed still draws the tree it was saved for, and
a zero byte is still a plain one.

What changes is what the tree is made of. A name may be awkward, a file may sit
on a boundary of size or be written in pieces, and a hard link storm or
a symlink that leads back to the directory it is in may be added at the end. Each
changed node keeps its id; its name, which the shrinker puts back to the plain
one when the failure does not need it.
*/

// Name_Style is the way a name is made strange. Plain is not drawn here.
Name_Style :: enum u8 {
	Unicode, // accents, CJK and an emoji, composed
	Long, // as long as a name may be: 255 bytes of ASCII or of two-byte letters
	Dot_Lead, // .f7, a hidden file
	Dot_Trail, // f7.
	Space_Lead, // " f7"
	Space_Trail, // "f7 "
	Newline, // a line break in the middle
	Dash_Lead, // -f7, which a command line would read as a flag
	Bad_Utf8, // bytes no encoding spells
	Reserved, // a Windows device name with an extension: aux.f7.txt
	Case_Twin, // the case-swapped name of the sibling before it
	Normal_Twin, // the sibling before it with é decomposed, if it has one
}

NAME_STYLES := []Name_Style {
	.Unicode,
	.Long,
	.Dot_Lead,
	.Dot_Trail,
	.Space_Lead,
	.Space_Trail,
	.Newline,
	.Dash_Lead,
	.Bad_Utf8,
	.Reserved,
	.Case_Twin,
	.Normal_Twin,
}

// A directory's long name is shorter, so a chain of 24 of them stays under
// PATH_MAX (4096 bytes on Linux).
HOLDER_NAME_LENGTH :: 100

// make_strange changes the nodes of a drawn tree, drawing from src, and adds a storm
// of links at the end.
make_strange :: proc(nodes: ^[dynamic]Node, src: ^harness.Source, allocator: runtime.Allocator) {
	count := len(nodes)
	for i in 1 ..< count {
		gate := harness.integer_in(src, 0, 8)
		if gate == 2 || gate == 3 {
			set_strange_size(&nodes[i], src)
			// The name says what the node is now.
			nodes[i].name = name_of(nodes[i], allocator)
		}
		if gate == 1 || gate == 3 {
			nodes[i].name = strange_name(nodes[:], i, harness.choice(src, NAME_STYLES), allocator)
		}
	}

	storm := harness.integer_in(src, 0, 6)
	if storm == 1 || storm == 3 {
		add_link_storm(nodes, src, allocator)
	}
	if storm == 2 || storm == 3 {
		add_loop_links(nodes, src, allocator)
	}
}

// strange_name is the name of node `at` made in a style, the plain name where
// the style cannot be had.
strange_name :: proc(nodes: []Node, at: int, style: Name_Style, allocator: runtime.Allocator) -> string {
	n := nodes[at]
	plain := name_of(n, allocator)
	name: string
	switch style {
	case .Unicode:
		name = strings.concatenate({plain, "-é日本語\U0001F642"}, allocator)
	case .Long:
		if can_hold(n) {
			name = pad(plain, "x", HOLDER_NAME_LENGTH, allocator)
		} else if at % 2 == 0 {
			name = pad(plain, "x", NAME_MAX, allocator)
		} else {
			name = pad(plain, "é", NAME_MAX, allocator)
		}
	case .Dot_Lead:
		name = strings.concatenate({".", plain}, allocator)
	case .Dot_Trail:
		name = strings.concatenate({plain, "."}, allocator)
	case .Space_Lead:
		name = strings.concatenate({" ", plain}, allocator)
	case .Space_Trail:
		name = strings.concatenate({plain, " "}, allocator)
	case .Newline:
		name = strings.concatenate({plain, "\nx"}, allocator)
	case .Dash_Lead:
		name = strings.concatenate({"-", plain}, allocator)
	case .Bad_Utf8:
		name = strings.concatenate({plain, "\xff\xfe"}, allocator)
	case .Reserved:
		name = strings.concatenate({"aux.", plain, ".txt"}, allocator)
	case .Case_Twin, .Normal_Twin:
		before := sibling_before(nodes, at)
		if before < 0 {
			return plain
		}
		name = nodes[before].name
		if style == .Normal_Twin && strings.contains(name, "é") {
			name, _ = strings.replace_all(name, "é", "é", allocator)
		} else {
			name = swap_case(name, allocator)
		}
	}

	if name_fault(name) != "" || name_taken(nodes, at, name) {
		return plain
	}
	return name
}

// pad makes `head` followed by as many `fill` as keep the name within `length` bytes.
@(private)
pad :: proc(head, fill: string, length: int, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, head)
	for strings.builder_len(b) + len(fill) <= length {
		strings.write_string(&b, fill)
	}
	return strings.to_string(b)
}

// swap_case swaps the case of the ASCII letters, so the name is another file
// on a filesystem that folds case and the same file on one that does not.
@(private)
swap_case :: proc(name: string, allocator: runtime.Allocator) -> string {
	out := make([]byte, len(name), allocator)
	for c, i in transmute([]byte)name {
		switch {
		case 'a' <= c && c <= 'z':
			out[i] = c - 32
		case 'A' <= c && c <= 'Z':
			out[i] = c + 32
		case:
			out[i] = c
		}
	}
	return string(out)
}

// sibling_before is the index of the nearest node before `at` in the same
// directory, -1 when there is none.
@(private)
sibling_before :: proc(nodes: []Node, at: int) -> int {
	for i := at - 1; i > 0; i -= 1 {
		if nodes[i].parent == nodes[at].parent {
			return i
		}
	}
	return -1
}

// name_taken says whether another node of the same directory has the name.
@(private)
name_taken :: proc(nodes: []Node, at: int, name: string) -> bool {
	for n, i in nodes {
		if i != at && i > 0 && n.parent == nodes[at].parent && n.name == name {
			return true
		}
	}
	return false
}

// name_fault is what keeps a name from being made on Linux, "" when nothing
// does: empty, a dot or two, a slash or NUL in it, or more than NAME_MAX bytes.
name_fault :: proc(name: string) -> string {
	switch {
	case name == "" || name == "." || name == "..":
		return "not a name"
	case strings.contains_any(name, "/\x00"):
		return "holds a slash or a NUL"
	case len(name) > NAME_MAX:
		return "longer than a name may be"
	}
	return ""
}

// set_strange_size puts a file on a boundary of size, or writes it in pieces.
@(private)
set_strange_size :: proc(n: ^Node, src: ^harness.Source) {
	switch n.kind {
	case .File:
		if harness.integer_in(src, 0, 4) == 3 {
			n.kind = .Scatter
			n.size = harness.choice(src, SCATTER_SIZES)
		} else {
			n.size = harness.choice(src, BOUNDARY_SIZES)
		}
	case .Sparse:
		n.size = harness.choice(src, SPARSE_EDGES)
	case .Scatter:
		n.size = harness.choice(src, SCATTER_SIZES)
	case .Dir, .Link, .Symlink, .Dangling, .Unreadable, .Mount:
	}
}

// add_link_storm adds up to 8 more names for one file, in directories on its filesystem.
@(private)
add_link_storm :: proc(nodes: ^[dynamic]Node, src: ^harness.Source, allocator: runtime.Allocator) {
	spec := Spec{nodes[:]}
	files := make([dynamic]int, context.temp_allocator)
	for n in nodes {
		if is_file(n) {
			append(&files, n.id)
		}
	}
	if len(files) == 0 {
		return
	}
	file := harness.choice(src, files[:])
	target, _ := find(spec, file)
	here := domain(spec, target.parent)
	holders := make([dynamic]int, context.temp_allocator)
	for n in nodes {
		if can_hold(n) && domain(spec, n.id) == here {
			append(&holders, n.id)
		}
	}

	for _ in 0 ..< harness.integer_in(src, 2, 9) {
		n := Node {
			id     = len(nodes),
			parent = harness.choice(src, holders[:]),
			kind   = .Link,
			target = file,
		}
		n.name = name_of(n, allocator)
		append(nodes, n)
	}
}

// add_loop_links adds up to 4 symbolic links that lead back to the directory they
// are in or one above it, so a walk that follows links meets a loop.
@(private)
add_loop_links :: proc(nodes: ^[dynamic]Node, src: ^harness.Source, allocator: runtime.Allocator) {
	spec := Spec{nodes[:]}
	holders := make([dynamic]int, context.temp_allocator)
	for n in nodes {
		if can_hold(n) {
			append(&holders, n.id)
		}
	}

	above := make([dynamic]int, context.temp_allocator)
	for _ in 0 ..< harness.integer_in(src, 1, 5) {
		parent := harness.choice(src, holders[:])
		clear(&above)
		for at := parent; at != NONE; {
			append(&above, at)
			up, _ := find(spec, at)
			at = up.parent
		}

		n := Node {
			id     = len(nodes),
			parent = parent,
			kind   = .Symlink,
			target = harness.choice(src, above[:]),
		}
		n.name = name_of(n, allocator)
		append(nodes, n)
	}
}
