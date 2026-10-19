package survey

import "core:fmt"
import "core:os"
import "core:testing"

import "../scan"
import "../synth"
import "../walk"

/*
A folded walk must total a tree exactly as rollup_advance does when it charges
every node itself. The synthetic disk never goes through the walk, so it is
compared with a bottom-up fold of the finished tree. A real directory is walked
both ways.
*/

@(test)
a_folded_walk_matches_the_serial_rollup :: proc(t: ^testing.T) {
	root := make_sample(t, "wide")
	defer os.remove_all(root)
	defer reveal(root)
	for _ in 0 ..< 4 {
		tree := read_at(t, root, true, false)
		testing.expect(t, tree.folded != nil && tree.folded.complete, "the walk did not fold")
		match_serial(t, &tree, true)
		match_serial(t, &tree, false)
		scan.tree_destroy(&tree)
	}
}

@(test)
a_followed_link_folded_matches_the_serial_rollup :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	outside := fmt.tprintf("%s/leita_fold_outside_%d", dir, os.get_pid())
	root := fmt.tprintf("%s/leita_fold_follow_%d", dir, os.get_pid())
	os.remove_all(outside)
	os.remove_all(root)
	defer os.remove_all(outside)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(outside) == nil, "could not make outside")
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	write_file(t, fmt.tprintf("%s/f", outside), 40)
	testing.expect(t, os.symlink(outside, fmt.tprintf("%s/link", root)) == nil, "could not link")

	tree := read_at(t, root, true, true)
	defer scan.tree_destroy(&tree)
	testing.expect(t, tree.folded != nil && tree.folded.complete, "the walk did not fold")
	match_serial(t, &tree, true)
}

@(test)
a_folded_update_matches_the_serial_rollup :: proc(t: ^testing.T) {
	root := make_sample(t, "update")
	defer os.remove_all(root)
	defer reveal(root)
	base := read_at(t, root, false, false)
	defer scan.tree_destroy(&base)

	again: scan.Tree
	testing.expect_value(t, scan.tree_init(&again, 8), scan.Error.None)
	defer scan.tree_destroy(&again)
	u := walk.Update {
		base  = &base,
		marks = make(map[u32]walk.Mark),
	}
	defer delete(u.marks)
	// One directory is read again and the rest are copied, so both paths fold.
	w00 := find_named(&base, "w00")
	testing.expect(t, w00 != scan.NO_NODE, "w00 was not in the base")
	u.marks[w00] = .Deep
	err := walk.update(root, &u, &again, walk.Config{fold = true, workers = 8})
	testing.expect_value(t, err, walk.Error.None)
	testing.expect(t, again.folded != nil && again.folded.complete, "the update did not fold")
	match_serial(t, &again, true)
}

@(test)
a_walk_past_the_charge_cap_keeps_the_serial_rollup :: proc(t: ^testing.T) {
	// The file is 65 edges down. rollup_advance stops at 64 ancestors, so a
	// subtree total would disagree and the walk must not install one.
	root := make_chain(t, "deep", 65)
	defer os.remove_all(root)
	tree := read_at(t, root, true, false)
	defer scan.tree_destroy(&tree)
	testing.expect(t, tree.folded == nil, "a walk past the cap published totals")

	plain := read_at(t, root, false, false)
	defer scan.tree_destroy(&plain)
	fold_roll, plain_roll: Rollup
	defer rollup_destroy(&fold_roll)
	defer rollup_destroy(&plain_roll)
	rollup_advance(&fold_roll, &tree)
	rollup_advance(&plain_roll, &plain)
	testing.expect_value(t, scan.slots(&tree), scan.slots(&plain))
	for i in 0 ..< scan.slots(&tree) {
		if total(&fold_roll, i) != total(&plain_roll, i) {
			testing.expectf(
				t,
				false,
				"node %d: capped %d, plain %d",
				i,
				total(&fold_roll, i),
				total(&plain_roll, i),
			)
			return
		}
	}
}

@(test)
synthetic_totals_match_a_bottom_up_fold :: proc(t: ^testing.T) {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, synth.read("/Users/alex", &tree, {}), synth.Error.None)

	got, dirs, deep := bottom_up(&tree)
	defer delete(got)
	testing.expect(t, !deep, "the synthetic disk is deeper than the rollup's cap")

	roll: Rollup
	defer rollup_destroy(&roll)
	rollup_advance(&roll, &tree)
	testing.expect_value(t, roll.pending, 0)
	testing.expect_value(t, len(roll.dir_totals), dirs)
	for i in 0 ..< scan.slots(&tree) {
		if total(&roll, i) != got[i] {
			testing.expectf(t, false, "node %d: rollup %d, bottom-up %d", i, total(&roll, i), got[i])
			return
		}
	}
}

// match_serial checks a folded tree against a rollup that charges every node,
// linked or not. Directory numbers are left clear and the fold stays in place,
// so it can be called again on the same tree.
@(private = "file")
match_serial :: proc(t: ^testing.T, tree: ^scan.Tree, linked: bool) {
	count := int(scan.slots(tree))
	for i in 0 ..< u32(count) {
		scan.node(tree, i).dir = 0
	}
	roll := Rollup {
		linked = linked,
	}
	defer rollup_destroy(&roll)
	rollup_advance(&roll, tree)
	testing.expect_value(t, roll.pending, 0)
	root := total(&roll, tree.root)
	testing.expect_value(t, root, charged_bytes(tree))
	rollup_advance(&roll, tree)
	testing.expect_value(t, total(&roll, tree.root), root)

	got := make([]u64, count)
	defer delete(got)
	lists: [][dynamic]u32
	if linked {
		lists = make([][dynamic]u32, count)
	}
	defer if linked {
		for &l in lists {
			delete(l)
		}
		delete(lists)
	}
	for i in 0 ..< u32(count) {
		got[i] = total(&roll, i)
		if !linked {
			continue
		}
		it := children(&roll, i)
		for c in next_child(&it) {
			append(&lists[i], c)
		}
	}
	numbered := len(roll.dir_totals)

	saved := tree.folded
	tree.folded = nil
	defer tree.folded = saved
	for i in 0 ..< u32(count) {
		scan.node(tree, i).dir = 0
	}
	plain := Rollup {
		linked = linked,
	}
	defer rollup_destroy(&plain)
	rollup_advance(&plain, tree)
	testing.expect_value(t, plain.pending, 0)
	testing.expect_value(t, len(plain.dir_totals), numbered)
	for i in 0 ..< u32(count) {
		if total(&plain, i) != got[i] {
			testing.expectf(t, false, "node %d total %d, serial %d", i, got[i], total(&plain, i))
			return
		}
		if !linked {
			continue
		}
		it := children(&plain, i)
		n := 0
		for c in next_child(&it) {
			if n >= len(lists[i]) || lists[i][n] != c {
				testing.expectf(
					t,
					false,
					"node %d child %d: folded %v, serial reached %d",
					i,
					n,
					lists[i][:],
					c,
				)
				return
			}
			n += 1
		}
		if n != len(lists[i]) {
			testing.expectf(t, false, "node %d lists %d children, serial %d", i, len(lists[i]), n)
			return
		}
	}
	for i in 0 ..< u32(count) {
		scan.node(tree, i).dir = 0
	}
}

// charged_bytes is what reaches the root of a tree no deeper than the cap:
// every settled node's allocation, once, skipping a second name and a link.
@(private = "file")
charged_bytes :: proc(tree: ^scan.Tree) -> u64 {
	sum: u64
	for i in 0 ..< scan.slots(tree) {
		n := scan.node(tree, i)
		flags := scan.node_flags(n)
		if .Used not_in flags || .Settled not_in flags || .Extra_Name in flags {
			continue
		}
		if .Directory in flags || .Reparse not_in flags {
			sum += n.disk
		}
	}
	return sum
}

@(private = "file")
read_at :: proc(t: ^testing.T, root: string, fold, follow: bool) -> scan.Tree {
	cfg := walk.Config {
		workers = 8,
		follow  = follow,
		fold    = fold,
	}
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, walk.width(cfg)), scan.Error.None)
	testing.expect_value(t, walk.read(root, &tree, cfg), walk.Error.None)
	return tree
}

@(private = "file")
make_sample :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_fold_%s_%d", dir, name, os.get_pid())
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")

	// The file at the bottom is 64 edges down: still inside the charge cap, so
	// the fold must install rather than fall back. The wide directories give
	// several workers a directory to settle at once.
	cur := root
	for _ in 1 ..< 64 {
		cur = fmt.tprintf("%s/n", cur)
		testing.expect(t, os.make_directory(cur) == nil, "could not make the chain")
	}
	write_file(t, fmt.tprintf("%s/f", cur), 3)

	for i in 0 ..< 40 {
		sub := fmt.tprintf("%s/w%02d", root, i)
		testing.expect(t, os.make_directory(sub) == nil, "could not make a wide directory")
		write_file(t, fmt.tprintf("%s/f", sub), 16 + i)
	}
	testing.expect(t, os.make_directory(fmt.tprintf("%s/empty", root)) == nil, "could not make empty")
	write_file(t, fmt.tprintf("%s/zero", root), 0)

	when ODIN_OS != .Windows {
		link_err := os.link(fmt.tprintf("%s/w00/f", root), fmt.tprintf("%s/w00/g", root))
		testing.expect(t, link_err == nil, "could not hard-link")
		testing.expect(t, os.symlink("w00", fmt.tprintf("%s/link", root)) == nil, "could not symlink")
		hidden := fmt.tprintf("%s/hidden", root)
		testing.expect(t, os.make_directory(hidden) == nil, "could not make hidden")
		write_file(t, fmt.tprintf("%s/secret", hidden), 8)
		testing.expect(t, os.change_mode(hidden, {}) == nil, "could not hide the directory")
	}
	return root
}

// reveal puts back the permission make_sample cleared, so remove_all can delete
// the hidden directory. Root can search it with no bits set; the deferred call
// is then only undoing a mode that did not hide anything.
@(private = "file")
reveal :: proc(root: string) {
	when ODIN_OS != .Windows {
		os.change_mode(fmt.tprintf("%s/hidden", root), {.Read_User, .Write_User, .Execute_User})
	}
}

// depth is how many edges the file sits below the root.
@(private = "file")
make_chain :: proc(t: ^testing.T, name: string, depth: int) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_fold_%s_%d", dir, name, os.get_pid())
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	cur := root
	for _ in 1 ..< depth {
		cur = fmt.tprintf("%s/n", cur)
		testing.expect(t, os.make_directory(cur) == nil, "could not make the chain")
	}
	write_file(t, fmt.tprintf("%s/f", cur), 7)
	return root
}

@(private = "file")
write_file :: proc(t: ^testing.T, path: string, size: int) {
	body := make([]byte, size)
	defer delete(body)
	for &b in body {
		b = 'x'
	}
	testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
}

@(private = "file")
find_named :: proc(tree: ^scan.Tree, name: string) -> u32 {
	for i in 0 ..< scan.slots(tree) {
		n := scan.node(tree, i)
		if .Used in n.flags && scan.name_of(tree, i) == name {
			return i
		}
	}
	return scan.NO_NODE
}

// bottom_up totals each directory from its own bytes and its children. It is
// the check for a reader that never folds, and it stops agreeing with the
// rollup once a node has more than 64 ancestors.
@(private = "file")
bottom_up :: proc(tree: ^scan.Tree) -> (got: []u64, dirs: int, deep: bool) {
	count := int(scan.slots(tree))
	NONE :: max(u32)
	head := make([]u32, count)
	next := make([]u32, count)
	defer delete(head)
	defer delete(next)
	for i in 0 ..< count {
		head[i] = NONE
		next[i] = NONE
	}
	got = make([]u64, count)

	for i in 0 ..< u32(count) {
		node := scan.node(tree, i)
		flags := scan.node_flags(node)
		if .Used not_in flags || .Settled not_in flags || .Extra_Name in flags {
			continue
		}
		parent := node.parent
		if .Directory in flags {
			dirs += 1
			got[i] += node.disk
			if parent != i && int(parent) < count {
				next[i] = head[parent]
				head[parent] = i
			}
		} else if parent != i && int(parent) < count {
			got[parent] += node.disk
		}
		d := 0
		cur := i
		for _ in 0 ..< 65 {
			at := scan.node(tree, cur)
			if at.parent == cur || int(at.parent) >= count {
				break
			}
			d += 1
			cur = at.parent
		}
		if d > 64 {
			deep = true
		}
	}

	Item :: struct {
		id:    u32,
		enter: bool,
	}
	stack := make([dynamic]Item)
	defer delete(stack)
	seen := make([]bool, count)
	defer delete(seen)
	for i in 0 ..< u32(count) {
		flags := scan.node_flags(scan.node(tree, i))
		if .Directory not_in flags || .Used not_in flags || .Extra_Name in flags {
			continue
		}
		parent := scan.node(tree, i).parent
		held :=
			parent != i && int(parent) < count && .Directory in scan.node_flags(scan.node(tree, parent))
		if !held {
			append(&stack, Item{i, true})
		}
	}
	for len(stack) > 0 {
		item := pop(&stack)
		if item.enter {
			if seen[item.id] {
				continue
			}
			seen[item.id] = true
			append(&stack, Item{item.id, false})
			for c := head[item.id]; c != NONE; c = next[c] {
				append(&stack, Item{c, true})
			}
		} else {
			for c := head[item.id]; c != NONE; c = next[c] {
				got[item.id] += got[c]
			}
		}
	}
	return
}
