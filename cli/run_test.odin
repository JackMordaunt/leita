package leita_cli

import "core:strings"
import "core:testing"

import "../scan"
import "../survey"

@(private = "file")
place :: proc(tree: ^scan.Tree, i, parent: u32, disk: u64, dir: bool) {
	n := scan.node(tree, i)
	n.parent = parent
	n.disk = disk
	// One letter: the climb follows parents, and the name is only there so the
	// node is shaped as a scan leaves it.
	n.name = scan.name_copy(tree, "d" if dir else "f")
	scan.node_publish(n, {.Used, .Settled, .Directory} if dir else {.Used, .Settled})
}

/*
A file seventy directories under the scan root still ranks, and so does a
sibling of it. The climb used to keep sixty-four ancestors and, past that,
remember the chain as outside, which dropped the file and every later sibling
under those ancestors. The file is numbered before the directories, so the
climb is the long one: nothing above it has been classified yet.

	0        the scan root
	1        the file, 3000 bytes
	2        its sibling, in the same directory, 2000 bytes
	3 .. 72  the seventy directories, each the parent of the one before;
	         72's parent is the root, 3 holds the file
	73       a file under directory 33, which that capped climb marked outside
	74       a file under another root, 9000 bytes, which must not rank
	75       that other root
*/
@(test)
a_file_seventy_directories_deep_is_among_the_largest :: proc(t: ^testing.T) {
	DEPTH   :: 70
	FILE    :: u32(1)
	SIBLING :: u32(2)
	DEEPEST :: u32(3)
	LAST_DIR := DEEPEST + DEPTH - 1
	COUSIN := LAST_DIR + 1
	// Inside the sixty-four ancestors the old cap wrote down as outside.
	COUSIN_PARENT := DEEPEST + 30
	OUTSIDE := COUSIN + 1
	OTHER := OUTSIDE + 1

	tree: scan.Tree
	testing.expect(t, scan.tree_init(&tree) == nil)
	defer scan.tree_destroy(&tree)
	testing.expect(t, scan.reserve(&tree, OTHER + 1) == nil)

	place(&tree, 0, 0, 0, true)
	place(&tree, FILE, DEEPEST, 3000, false)
	place(&tree, SIBLING, DEEPEST, 2000, false)
	for i in DEEPEST ..= LAST_DIR {
		parent := i + 1 if i < LAST_DIR else 0
		place(&tree, i, parent, 0, true)
	}
	place(&tree, COUSIN, COUSIN_PARENT, 1000, false)
	place(&tree, OUTSIDE, OTHER, 9000, false)
	place(&tree, OTHER, OTHER, 0, true)
	tree.root = 0

	roll: survey.Rollup
	defer survey.rollup_destroy(&roll)
	survey.rollup_advance(&roll, &tree)

	top: [8]Sized
	n := rank(&tree, &roll, top[:], .files)
	testing.expect_value(t, n, 3)
	if n >= 1 {
		testing.expect_value(t, top[0].record, FILE)
		testing.expect_value(t, top[0].bytes, u64(3000))
	}
	if n >= 2 {
		testing.expect_value(t, top[1].record, SIBLING)
	}
	if n >= 3 {
		testing.expect_value(t, top[2].record, COUSIN)
	}

	// The directory the file sits in is seventy down as well.
	dirs: [80]Sized
	dn := rank(&tree, &roll, dirs[:])
	found := false
	for s in dirs[:dn] {
		if s.record == DEEPEST {
			found = true
		}
	}
	testing.expect(t, found, "the deep directory is among the largest")
}

// The summary's first line says when the disk is made up, and only then.
@(test)
the_first_line_says_when_the_disk_is_made_up :: proc(t: ^testing.T) {
	target := scan.Target {
		volume = "/dev/sda1",
		mount  = "/data",
	}
	line := head_line(target, .Walk, .Buffered)
	testing.expect(t, strings.contains(line, "Walk engine"), line)
	testing.expect(t, !strings.contains(line, "made-up"), line)

	line = head_line(target, .Synthetic, .Buffered)
	testing.expect(t, strings.has_suffix(line, "This is a made-up disk: LEITA_SYNTHETIC was set."), line)
	testing.expect(t, !strings.contains(line, "\n"), line)
}
