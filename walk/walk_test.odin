package walk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"

import "../scan"

/*
Build a known tree and return its root.

	<root>/a.txt          100 bytes
	<root>/sub/b.txt      5000 bytes
	<root>/sub/deep/c.txt 1 byte
	<root>/link           a symlink to sub

Six entries below the root, one of which leads back into the tree, which is what
makes following symlinks worth a decision rather than a default.
*/
@(private = "file")
fixture :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/sonar_walk_%s", dir, name)
	os.remove_all(root)

	write :: proc(t: ^testing.T, path: string, size: int) {
		body := make([]byte, size, context.temp_allocator)
		slice.fill(body, 'x')
		testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
	}
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory(fmt.tprintf("%s/sub", root)) == nil, "could not make sub")
	testing.expect(
		t,
		os.make_directory(fmt.tprintf("%s/sub/deep", root)) == nil,
		"could not make deep",
	)
	write(t, fmt.tprintf("%s/a.txt", root), 100)
	write(t, fmt.tprintf("%s/sub/b.txt", root), 5000)
	write(t, fmt.tprintf("%s/sub/deep/c.txt", root), 1)
	testing.expect(
		t,
		os.symlink("sub", fmt.tprintf("%s/link", root)) == nil,
		"could not make the symlink",
	)
	return root
}

// Every node the walk recorded, by name. Names repeat across directories in general;
// none of them do in the fixture.
@(private = "file")
named :: proc(tree: ^scan.Tree, name: string) -> (^scan.Node, int) {
	found: ^scan.Node
	count := 0
	for i in 0 ..< tree.count {
		n := scan.node(tree, i)
		if .Used in n.flags && n.name == name {
			found = n
			count += 1
		}
	}
	return found, count
}

@(private = "file")
walked :: proc(t: ^testing.T, root: string, cfg := Config{}) -> scan.Tree {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	testing.expect_value(t, read(root, &tree, cfg), Error.None)
	return tree
}

@(test)
test_walk_records_every_entry :: proc(t: ^testing.T) {
	root := fixture(t, "every")
	defer os.remove_all(root)
	tree := walked(t, root)
	defer scan.tree_destroy(&tree)

	// The root, plus the six entries below it.
	testing.expect_value(t, tree.count, u32(7))
	testing.expect_value(t, tree.nodes_done, u64(6))

	for name in ([]string{"a.txt", "sub", "deep", "b.txt", "c.txt", "link"}) {
		n, count := named(&tree, name)
		testing.expectf(t, count == 1, "expected one %s, found %d", name, count)
		if n != nil {
			testing.expectf(t, .Settled in n.flags, "%s was left unsettled", name)
		}
	}
}

@(test)
test_walk_marks_directories_and_sizes :: proc(t: ^testing.T) {
	root := fixture(t, "shapes")
	defer os.remove_all(root)
	tree := walked(t, root)
	defer scan.tree_destroy(&tree)

	sub, _ := named(&tree, "sub")
	testing.expect(t, .Directory in sub.flags, "sub is not marked a directory")
	testing.expect_value(t, sub.disk, u64(0)) // a directory is charged through what it holds

	a, _ := named(&tree, "a.txt")
	testing.expect(t, .Directory not_in a.flags, "a.txt is marked a directory")
	testing.expect_value(t, a.size, u64(100))
	// 100 bytes occupy a block, whether the reader knows the block or estimates it.
	testing.expectf(t, a.disk >= 512 && a.disk <= 8192, "a.txt charged %d bytes", a.disk)

	b, _ := named(&tree, "b.txt")
	testing.expect_value(t, b.size, u64(5000))
	testing.expectf(t, b.disk >= 5000, "b.txt charged %d for 5000 bytes", b.disk)
}

@(test)
test_walk_does_not_follow_a_symlink_by_default :: proc(t: ^testing.T) {
	root := fixture(t, "nofollow")
	defer os.remove_all(root)
	tree := walked(t, root)
	defer scan.tree_destroy(&tree)

	link, _ := named(&tree, "link")
	testing.expect(t, .Reparse in link.flags, "the symlink is not marked a reparse")
	testing.expect(t, .Directory not_in link.flags, "the symlink is counted as a directory")
	// Descending it would record sub's contents a second time.
	_, subs := named(&tree, "b.txt")
	testing.expect_value(t, subs, 1)
}

@(test)
test_walk_follows_a_symlink_when_asked :: proc(t: ^testing.T) {
	root := fixture(t, "follow")
	defer os.remove_all(root)
	tree := walked(t, root, Config{follow = true})
	defer scan.tree_destroy(&tree)

	// sub reached twice: once by name, once through the link. Its three entries
	// therefore appear twice over.
	_, b := named(&tree, "b.txt")
	testing.expect_value(t, b, 2)
	testing.expect_value(t, tree.count, u32(10))
}

@(test)
test_walk_stops_when_cancelled :: proc(t: ^testing.T) {
	root := fixture(t, "cancel")
	defer os.remove_all(root)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)

	// Called off before it starts, so the seed directory is the only work offered
	// and it declines it.
	scan.cancel(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.Cancelled)
}

/*
A count that was asked for is used as given; otherwise a spinning disk gets one reader
and anything else twice the logical cores, within the cap.
*/
@(test)
test_width_fits_the_media :: proc(t: ^testing.T) {
	fitted := clamp(2 * cpus(), 1, MAX_WORKERS)
	cases := []struct {
		cfg:  Config,
		want: int,
	} {
		{Config{workers = 3, media = .Rotational}, 3},
		{Config{workers = 64, media = .Solid}, 64},
		{Config{media = .Rotational}, 1},
		{Config{media = .Solid}, fitted},
		{Config{media = .Unknown}, fitted},
	}
	for c in cases {
		testing.expectf(t, width(c.cfg) == c.want, "%v: %d, want %d", c.cfg, width(c.cfg), c.want)
	}
}

// A quota caps the CPUs counted, rounded up; no quota, or text that is not one, says
// nothing.
@(test)
test_cpu_max_limit_reads_a_cgroup_quota :: proc(t: ^testing.T) {
	limited := []struct {
		text: string,
		want: int,
	}{{"150000 100000\n", 2}, {"100000 100000", 1}, {"50000 100000", 1}, {"800000 100000", 8}}
	for c in limited {
		got, ok := cpu_max_limit(c.text)
		testing.expectf(t, ok && got == c.want, "%q: %d %v, want %d", c.text, got, ok, c.want)
	}
	for text in ([]string{"max 100000\n", "", "100000", "a b", "0 100000", "100000 0"}) {
		_, ok := cpu_max_limit(text)
		testing.expectf(t, !ok, "%q read as a quota", text)
	}
}
