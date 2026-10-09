package synth

import "core:fmt"
import "core:strings"
import "core:testing"

import "../scan"

// Made_Up_Disk is what a test reads off a made-up tree.
@(private = "file")
Made_Up_Disk :: struct {
	tree:  scan.Tree,
	nodes: u32,
	bytes: u64,
}

@(private = "file")
make_up :: proc(t: ^testing.T, m: ^Made_Up_Disk, day: int) -> bool {
	testing.expect(t, scan.tree_init(&m.tree) == nil) or_return
	err := read("/", &m.tree, {day = day})
	testing.expect_value(t, err, Error.None) or_return
	m.nodes = m.tree.count
	for i in 0 ..< m.nodes {
		m.bytes += scan.node(&m.tree, i).disk
	}
	return true
}

// child is the node named name directly under dir, or false.
@(private = "file")
child :: proc(tr: ^scan.Tree, dir: u32, name: string) -> (u32, bool) {
	for i in 0 ..< tr.count {
		if i != dir && scan.node(tr, i).parent == dir && scan.name_of(tr, i) == name {
			return i, true
		}
	}
	return 0, false
}

@(private = "file")
find :: proc(tr: ^scan.Tree, path: string) -> (node: u32, ok: bool) {
	node = tr.root
	for part in strings.split(path, "/", context.temp_allocator) {
		node = child(tr, node, part) or_return
	}
	return node, true
}

@(test)
a_disk_looks_like_a_mac :: proc(t: ^testing.T) {
	m: Made_Up_Disk
	defer scan.tree_destroy(&m.tree)
	if !make_up(t, &m, 30) {
		return
	}

	for top in ([]string{"Applications", "System", "Library", "Users", "opt", "private", "usr"}) {
		_, found := child(&m.tree, m.tree.root, top)
		testing.expectf(t, found, "/%s is there", top)
	}
	gib := f64(m.bytes) / GiB
	testing.expectf(t, gib > 200 && gib < 360, "%.1f GiB is a well-used disk", gib)
	testing.expectf(t, m.nodes > 300_000 && m.nodes < 3_000_000, "%d entries", m.nodes)
	total, free := space(30)
	testing.expect(t, free < total && m.bytes < total - free)
}

@(test)
the_same_day_makes_the_same_disk :: proc(t: ^testing.T) {
	a, b: Made_Up_Disk
	defer scan.tree_destroy(&a.tree)
	defer scan.tree_destroy(&b.tree)
	if !make_up(t, &a, 12) {
		return
	}
	if !make_up(t, &b, 12) {
		return
	}
	testing.expect_value(t, b.nodes, a.nodes)
	testing.expect_value(t, b.bytes, a.bytes)
}

// A week later the disk holds everything it held, and more: what grows has grown,
// and nothing that does not grow has changed.
@(test)
a_later_day_has_grown :: proc(t: ^testing.T) {
	before, after: Made_Up_Disk
	defer scan.tree_destroy(&before.tree)
	defer scan.tree_destroy(&after.tree)
	if !make_up(t, &before, 30) {
		return
	}
	if !make_up(t, &after, 37) {
		return
	}
	testing.expect(t, after.bytes > before.bytes)

	was, _ := find(&before.tree, "Users/alex/Downloads")
	now, _ := find(&after.tree, "Users/alex/Downloads")
	for i in 0 ..< before.tree.count {
		if scan.node(&before.tree, i).parent == was && i != was {
			_, kept := child(&after.tree, now, scan.name_of(&before.tree, i))
			testing.expectf(t, kept, "%s is still downloaded", scan.name_of(&before.tree, i))
		}
	}
	dock, _ := find(&before.tree, "Applications/Xcode.app/Contents/Info.plist")
	dock_later, _ := find(&after.tree, "Applications/Xcode.app/Contents/Info.plist")
	testing.expect_value(
		t,
		scan.node(&after.tree, dock_later).disk,
		scan.node(&before.tree, dock).disk,
	)
}

@(test)
no_directory_holds_a_name_twice :: proc(t: ^testing.T) {
	m: Made_Up_Disk
	defer scan.tree_destroy(&m.tree)
	if !make_up(t, &m, 0) {
		return
	}
	seen := make(map[string]bool, int(m.nodes))
	defer delete(seen)
	for i in 0 ..< m.nodes {
		key := fmt.tprintf("%d/%s", scan.node(&m.tree, i).parent, scan.name_of(&m.tree, i))
		if !testing.expectf(
			t,
			!seen[key],
			"%s twice",
			scan.path(&m.tree, i, context.temp_allocator),
		) {
			return
		}
		seen[strings.clone(key, context.temp_allocator)] = true
	}
}

// What Reclaim offers needs its proof beside it: a node_modules its package.json,
// a target its Cargo.toml, a .venv its pyproject.toml.
@(test)
build_output_sits_beside_its_manifest :: proc(t: ^testing.T) {
	m: Made_Up_Disk
	defer scan.tree_destroy(&m.tree)
	if !make_up(t, &m, 0) {
		return
	}
	pairs := [?][2]string {
		{"Users/alex/Source/atlas-web/node_modules", "Users/alex/Source/atlas-web/package.json"},
		{"Users/alex/Source/quill/target", "Users/alex/Source/quill/Cargo.toml"},
		{"Users/alex/Source/tidepool/.venv", "Users/alex/Source/tidepool/pyproject.toml"},
	}
	for p in pairs {
		_, made := find(&m.tree, p[0])
		_, proof := find(&m.tree, p[1])
		testing.expectf(t, made && proof, "%s beside %s", p[0], p[1])
	}
}

@(test)
a_cancelled_scan_stops :: proc(t: ^testing.T) {
	tr: scan.Tree
	if !testing.expect(t, scan.tree_init(&tr) == nil) {
		return
	}
	defer scan.tree_destroy(&tr)
	scan.cancel(&tr)
	testing.expect_value(t, read("/", &tr, {}), Error.Cancelled)
}
