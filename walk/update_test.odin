package walk

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

import "../scan"

/*
A place to update.

	<root>/a.txt               100 bytes
	<root>/sub/b.txt           5000 bytes
	<root>/sub/deep/c.txt      1 byte
	<root>/still/k.txt         3000 bytes
*/
@(private = "file")
place :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_update_%s_%d", dir, name, os.get_pid())
	os.remove_all(root)
	for sub in ([]string{"", "/sub", "/sub/deep", "/still"}) {
		testing.expect(t, os.make_directory(fmt.tprintf("%s%s", root, sub)) == nil, "no directory")
	}
	put(t, fmt.tprintf("%s/a.txt", root), 100)
	put(t, fmt.tprintf("%s/sub/b.txt", root), 5000)
	put(t, fmt.tprintf("%s/sub/deep/c.txt", root), 1)
	put(t, fmt.tprintf("%s/still/k.txt", root), 3000)
	return root
}

// Write a file of `size` bytes, for any platform. read_windows_test.odin's
// write_file is Windows' alone.
@(private = "file")
put :: proc(t: ^testing.T, path: string, size: int) {
	body := make([]byte, size, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
}

// Grow still/k.txt where it is. No test here marks still, or updates with a restat
// small enough to catch it, so an update must keep the base's size for it.
@(private = "file")
grow_unseen :: proc(t: ^testing.T, root: string) {
	put(t, fmt.tprintf("%s/still/k.txt", root), 40_000)
}

@(private = "file")
read_tree :: proc(t: ^testing.T, root: string) -> scan.Tree {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
	testing.expect_value(t, read(root, &tree, Config{workers = 2}), Error.None)
	return tree
}

// Filesystems whose baseline lacks extent identities use a fresh walk. Tests
// still assert the copying path on filesystems where reuse remains supported.
@(private = "file")
update_rereads_fixture :: proc(root: string) -> bool {
	when ODIN_OS == .Linux {
		return btrfs_update_needs_read(root, false)
	}
	when ODIN_OS == .Darwin {
		st, ok := scan.stat_fs(root)
		return !ok || string(cstring(&st.fstypename[0])) == "apfs"
	}
	return false
}

// The node of `tree` at `path` under its root, or NO_NODE.
@(private = "file")
at :: proc(tree: ^scan.Tree, path: ..string) -> u32 {
	ix, _ := scan.index_make(tree, context.temp_allocator)
	cur := tree.root
	for name in path {
		cur = scan.child_named(tree, ix, cur, name)
		if cur == scan.NO_NODE {
			break
		}
	}
	return cur
}

// What a tree says is there: each node's path, and what it charges.
@(private = "file")
shape :: proc(tree: ^scan.Tree) -> map[string]u64 {
	out := make(map[string]u64, context.temp_allocator)
	for i in 0 ..< scan.slots(tree) {
		n := scan.node(tree, i)
		f := scan.node_flags(n)
		if .Used not_in f {
			continue
		}
		charged := n.disk if .Extra_Name not_in f && .Directory not_in f else 0
		out[scan.path(tree, i, context.temp_allocator)] = charged
	}
	return out
}

/*
Expect `got` to hold, path for path and byte for byte, what `want` does. Given the
base, still/k.txt is the exception: grow_unseen changed it where nothing looks, so
`got` must hold the base's size for it, which is what shows still was copied rather
than read again.
*/
@(private = "file")
expect_same_shape :: proc(t: ^testing.T, got, want: ^scan.Tree, base: ^scan.Tree = nil) {
	g, w := shape(got), shape(want)
	base := base
	if update_rereads_fixture(scan.name_of(got, got.root)) {
		base = nil
	}
	stale := scan.path(want, at(want, "still", "k.txt"), context.temp_allocator)
	if base != nil {
		was := shape(base)[stale]
		testing.expectf(t, g[stale] == was, "k.txt charged %d, the base %d", g[stale], was)
		testing.expectf(t, g[stale] != w[stale], "k.txt was read again: %d", g[stale])
	}
	testing.expectf(t, len(g) == len(w), "%d nodes, a walk has %d", len(g), len(w))
	for path, bytes in w {
		if base != nil && path == stale {
			continue
		}
		have, found := g[path]
		testing.expectf(t, found, "%s is missing", path)
		testing.expectf(t, !found || have == bytes, "%s charged %d, a walk %d", path, have, bytes)
	}
	for path in g {
		testing.expectf(t, path in w, "%s is not on disk", path)
	}
}

// Changes made to the directories marked are found, and the result is the tree a
// fresh walk reads, but for what was changed where nothing was marked.
@(test)
test_an_update_reads_what_changed :: proc(t: ^testing.T) {
	root := place(t, "changed")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	put(t, fmt.tprintf("%s/sub/new.txt", root), 7000)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/sub/fresh", root)) == nil, "no fresh")
	put(t, fmt.tprintf("%s/sub/fresh/f.txt", root), 9000)
	testing.expect(t, os.remove(fmt.tprintf("%s/sub/deep/c.txt", root)) == nil, "c.txt stayed")
	grow_unseen(t, root)

	u := Update {
		base = &base,
	}
	defer delete(u.marks)
	u.marks[at(&base, "sub")] = .List
	u.marks[at(&base, "sub", "deep")] = .List

	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got, Config{workers = 2}), Error.None)

	want := read_tree(t, root)
	defer scan.tree_destroy(&want)
	expect_same_shape(t, &got, &want, &base)
}

// A directory not marked is copied rather than read: a change in it is not seen,
// which is what makes an update cheap, and why the marks must be right.
@(test)
test_an_update_copies_what_is_not_marked :: proc(t: ^testing.T) {
	root := place(t, "copied")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)
	put(t, fmt.tprintf("%s/still/unseen.txt", root), 4000)

	u := Update {
		base = &base,
	}
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 1), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got), Error.None)

	if update_rereads_fixture(root) {
		want := read_tree(t, root)
		defer scan.tree_destroy(&want)
		expect_same_shape(t, &got, &want)
		testing.expect(t, at(&got, "still", "unseen.txt") != scan.NO_NODE)
	} else {
		expect_same_shape(t, &got, &base)
		testing.expect_value(t, at(&got, "still", "unseen.txt"), scan.NO_NODE)
	}
	testing.expect(t, at(&got, "still", "k.txt") != scan.NO_NODE, "k.txt was not copied")
}

// Deep reads everything below it, base or no base, and nothing beside it.
@(test)
test_a_deep_mark_walks_the_whole_subtree :: proc(t: ^testing.T) {
	root := place(t, "deep")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)
	put(t, fmt.tprintf("%s/sub/deep/d.txt", root), 2000)
	grow_unseen(t, root)

	u := Update {
		base = &base,
	}
	defer delete(u.marks)
	u.marks[at(&base, "sub")] = .Deep
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 1), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got), Error.None)

	want := read_tree(t, root)
	defer scan.tree_destroy(&want)
	expect_same_shape(t, &got, &want, &base)
}

// A probe reads the directories changed since, and the large files of those it
// copies, and nothing else: a small file written in place is missed, as designed.
@(test)
test_a_probe_finds_changed_directories :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		return
	}
	root := place(t, "probe")
	defer os.remove_all(root)
	put(t, fmt.tprintf("%s/still/big.bin", root), 1 << 17)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	// Linux stamps a change with its coarse clock (current_time in fs/inode.c), a
	// jiffy at most behind time.now, so each change is kept 50 ms clear of `since`.
	time.sleep(50 * time.Millisecond)
	since := time.to_unix_nanoseconds(time.now())
	time.sleep(50 * time.Millisecond)
	put(t, fmt.tprintf("%s/sub/new.txt", root), 7000)
	put(t, fmt.tprintf("%s/still/big.bin", root), 1 << 18) // in place: still is unchanged
	grow_unseen(t, root)

	u := Update {
		base   = &base,
		probe  = true,
		since  = since,
		restat = 1 << 16,
	}
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got, Config{workers = 2}), Error.None)

	want := read_tree(t, root)
	defer scan.tree_destroy(&want)
	expect_same_shape(t, &got, &want, &base)
}

// A large file grown in place in a directory no journal named gets its new size
// with no probe, as a file FSEvents does not report while it is held open must.
@(test)
test_a_copied_large_file_is_asked_its_size :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return // Windows keeps a copied file's size (stamp_other.odin)
	}
	root := place(t, "restat")
	defer os.remove_all(root)
	put(t, fmt.tprintf("%s/still/big.bin", root), 1 << 17)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)
	put(t, fmt.tprintf("%s/still/big.bin", root), 1 << 19)

	u := Update {
		base   = &base,
		restat = 1 << 16,
	}
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got, Config{workers = 2}), Error.None)

	big := at(&got, "still", "big.bin")
	if big == scan.NO_NODE {
		testing.fail_now(t, "big.bin was not copied")
	}
	was := scan.node(&base, at(&base, "still", "big.bin")).disk
	now := scan.node(&got, big).disk
	testing.expectf(t, now > was, "big.bin charged %d, as the base did", now)
	testing.expect(t, now >= 1 << 19, "big.bin is short of what was written")
	want := read_tree(t, root)
	defer scan.tree_destroy(&want)
	expect_same_shape(t, &got, &want)
}

/*
A 200 KB file rewritten in place to 400 KB, in a directory no probe or journal names,
is under `restat` and so asked only in its slice's turn: of eight updates from the
same base, one turn to each slice, exactly one measures it again, and the rest keep
the size the base gave it.
*/
@(test)
test_a_copied_small_file_is_asked_in_its_turn :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return // Windows keeps a copied file's size (stamp_other.odin)
	}
	root := place(t, "turn")
	defer os.remove_all(root)
	put(t, fmt.tprintf("%s/still/db.sqlite", root), 200_000)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)
	put(t, fmt.tprintf("%s/still/db.sqlite", root), 400_000)
	was := scan.node(&base, at(&base, "still", "db.sqlite")).disk

	measured := 0
	for turn in u64(0) ..< 8 {
		u := Update {
			base   = &base,
			restat = 1 << 20,
			slices = 8,
			turn   = turn,
		}
		got: scan.Tree
		testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
		defer scan.tree_destroy(&got)
		testing.expect_value(t, update(root, &u, &got, Config{workers = 2}), Error.None)
		db := at(&got, "still", "db.sqlite")
		if db == scan.NO_NODE {
			testing.fail_now(t, "db.sqlite was not copied")
		}
		now := scan.node(&got, db).disk
		if now == was {
			continue
		}
		measured += 1
		testing.expectf(t, now >= 400_000, "turn %d charged db.sqlite %d", turn, now)
		want := read_tree(t, root)
		defer scan.tree_destroy(&want)
		expect_same_shape(t, &got, &want)
	}
	testing.expect_value(t, measured, 8 if update_rereads_fixture(root) else 1)
}

/*
A large file in a directory that can no longer be searched cannot be asked its size,
but it is still there: the update keeps the size the base gave it rather than
dropping it as gone. Skipped where the directory can still be searched, as root can.
*/
@(test)
test_a_copied_file_that_cannot_be_asked_keeps_its_size :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return // Windows keeps a copied file's size (stamp_other.odin)
	}
	root := place(t, "unaskable")
	defer os.remove_all(root)
	big := fmt.tprintf("%s/still/big.bin", root)
	put(t, big, 1 << 17)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	still := fmt.tprintf("%s/still", root)
	testing.expect(t, os.change_mode(still, {}) == nil, "could not chmod still")
	defer os.change_mode(still, {.Read_User, .Write_User, .Execute_User})
	if os.exists(big) {
		log.info("skipped: still can be searched with no permission, as root can")
		return
	}

	u := Update {
		base   = &base,
		restat = 1 << 16,
	}
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got, Config{workers = 2}), Error.None)

	// Not fail_now: tried here, it skipped the deferred chmod, and the next run could
	// not remove the place (2026-10-13).
	kept := at(&got, "still", "big.bin")
	if update_rereads_fixture(root) {
		testing.expect_value(t, kept, scan.NO_NODE)
		still_node := at(&got, "still")
		testing.expect(t, still_node != scan.NO_NODE)
		if still_node != scan.NO_NODE {
			testing.expect(t, .Unread in scan.node_flags(scan.node(&got, still_node)))
		}
		return
	}
	testing.expect(t, kept != scan.NO_NODE, "big.bin was dropped as gone")
	if kept != scan.NO_NODE {
		was := scan.node(&base, at(&base, "still", "big.bin")).disk
		testing.expect_value(t, scan.node(&got, kept).disk, was)
	}
}

// A hard-linked file keeps the name the base charged it under when the other
// name's directory is read again, so its bytes are charged once, not twice.
@(test)
test_a_relisted_link_is_charged_once :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux && ODIN_OS != .Darwin {
		return
	}
	root := place(t, "links")
	defer os.remove_all(root)
	testing.expect(
		t,
		os.link(fmt.tprintf("%s/sub/b.txt", root), fmt.tprintf("%s/still/b2.txt", root)) == nil,
		"could not link",
	)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	u := Update {
		base = &base,
	}
	defer delete(u.marks)
	u.marks[at(&base, "still")] = .List
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 1), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got), Error.None)

	if !update_rereads_fixture(root) {
		expect_same_shape(t, &got, &base)
	}
	total :: proc(tree: ^scan.Tree) -> (sum: u64) {
		for _, bytes in shape(tree) {
			sum += bytes
		}
		return
	}
	testing.expect_value(t, total(&got), total(&base))
}

// A hard-linked file whose charged name is renamed after the base is charged once by
// the update, under one of the names it now has, not left on the old name and missed.
@(test)
test_a_renamed_payer_is_charged_once :: proc(t: ^testing.T) {
	root := place(t, "renamed_payer")
	defer os.remove_all(root)

	testing.expect(
		t,
		os.link(fmt.tprintf("%s/sub/b.txt", root), fmt.tprintf("%s/still/b2.txt", root)) == nil,
		"could not link",
	)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	testing.expect_value(t, len(base.linked), 1)
	if len(base.linked) != 1 {
		return
	}
	paid := scan.node(&base, base.linked[0].node)
	from := fmt.tprintf("%s/%s/%s", root, scan.name_of(&base, paid.parent), scan.name_of(&base, base.linked[0].node))
	testing.expect(t, os.rename(from, fmt.tprintf("%s.moved", from)) == nil, "could not rename")

	u := Update {
		base = &base,
	}
	defer delete(u.marks)

	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 1), scan.Error.None)
	defer scan.tree_destroy(&got)

	testing.expect_value(t, update(root, &u, &got), Error.None)
	testing.expect_value(t, charged_total(&got), charged_total(&base))
}

// What a tree charges in all, as its nodes say.
@(private = "file")
charged_total :: proc(tree: ^scan.Tree) -> (sum: u64) {
	for _, bytes in shape(tree) {
		sum += bytes
	}
	return
}

/*
A file named from two directories is charged once when an update copies the
directory holding the name the base charged and reads the other, walked again
(Deep) or unread in the base, and reads a third name linked since in a directory
new since. The copied name's file is marked charged before anything is read, so
each name read is an extra. Before, the name a Deep or unread directory held was
charged again, and the total grew by the whole file.

	<root>/a/big     1 MiB, the first name
	<root>/b/big     a second, made before the base was read
	<root>/c/big     a third, made after
*/
@(test)
test_an_update_charges_a_link_once_beside_a_copied_name :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux && ODIN_OS != .Darwin {
		return
	}
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_update_copied_link_%d", dir, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	for sub in ([]string{"", "/a", "/b"}) {
		testing.expect(t, os.make_directory(fmt.tprintf("%s%s", root, sub)) == nil, "no directory")
	}
	big := fmt.tprintf("%s/a/big", root)
	put(t, big, 1 << 20)
	testing.expect(t, os.link(big, fmt.tprintf("%s/b/big", root)) == nil, "could not link")
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)
	paid, other := "a", "b"
	if .Extra_Name in scan.node_flags(scan.node(&base, at(&base, "a", "big"))) {
		paid, other = "b", "a"
	}
	testing.expect(t, os.make_directory(fmt.tprintf("%s/c", root)) == nil, "no c")
	testing.expect(t, os.link(big, fmt.tprintf("%s/c/big", root)) == nil, "could not link c")

	for unread in ([]bool{false, true}) {
		u := Update {
			base = &base,
		}
		defer delete(u.marks)
		u.marks[base.root] = .List
		if unread {
			scan.node_mark(scan.node(&base, at(&base, other)), {.Unread})
		} else {
			u.marks[at(&base, other)] = .Deep
		}
		got: scan.Tree
		testing.expect_value(t, scan.tree_init(&got, 4), scan.Error.None)
		defer scan.tree_destroy(&got)
		testing.expect_value(t, update(root, &u, &got, Config{workers = 4}), Error.None)

		if update_rereads_fixture(root) && len(got.linked) == 1 {
			paid = scan.name_of(&got, scan.node(&got, got.linked[0].node).parent)
		}
		for name in ([]string{"a", "b", "c"}) {
			n := at(&got, name, "big")
			if n == scan.NO_NODE {
				testing.expectf(t, false, "%s/big is missing", name)
				continue
			}
			extra := .Extra_Name in scan.node_flags(scan.node(&got, n))
			testing.expectf(
				t,
				extra == (name != paid),
				"%s/big extra %v, %s paid",
				name,
				extra,
				paid,
			)
		}
		testing.expectf(
			t,
			charged_total(&got) == charged_total(&base),
			"unread %v: charged %d, the base %d",
			unread,
			charged_total(&got),
			charged_total(&base),
		)
		testing.expect_value(t, len(got.linked), 1)
		if len(got.linked) == 1 {
			testing.expect_value(t, got.linked[0].node, at(&got, paid, "big"))
		}
	}
}

// A file the base marks Shared, as a btrfs walk as root marks a reflinked copy, is
// still Shared when an update copies it, with the size the base gave it. Before,
// the copy dropped the flag, and the file read as one that shares nothing.
@(test)
test_an_update_keeps_a_copied_file_shared :: proc(t: ^testing.T) {
	root := place(t, "shared")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)
	scan.node_mark(scan.node(&base, at(&base, "still", "k.txt")), {.Shared})

	u := Update {
		base = &base,
	}
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got, Config{workers = 2}), Error.None)

	k := at(&got, "still", "k.txt")
	testing.expect(t, k != scan.NO_NODE, "k.txt was not copied")
	if k != scan.NO_NODE {
		if update_rereads_fixture(root) {
			want := read_tree(t, root)
			defer scan.tree_destroy(&want)
			testing.expect_value(
				t,
				.Shared in scan.node_flags(scan.node(&got, k)),
				.Shared in scan.node_flags(scan.node(&want, at(&want, "still", "k.txt"))),
			)
		} else {
			testing.expect(
				t,
				.Shared in scan.node_flags(scan.node(&got, k)),
				"k.txt is no longer Shared",
			)
		}
	}
	expect_same_shape(t, &got, &base)
}
