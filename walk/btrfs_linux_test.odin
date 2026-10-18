#+build linux
package walk

import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"

import "../btrfs"
import "../scan"

/*
What a walk charges a file depends on where it lies and who walks it, so the test
works out which case it is in and expects that one.

Off btrfs, every file is charged st_blocks and the tree says nothing. On btrfs
without root, or with NO_BTRFS_SEARCH_ENV set, the same, and the tree says its btrfs
sizes are logical. On btrfs as root, each extent is charged once across the walk,
so the walk totals what btrfs.measure, the reader checked against compsize, charges
for the same directory, and the tree does not call its sizes logical.

LEITA_BTRFS_DIR names a directory to walk, which is read and not changed; a small
one made in the temp directory otherwise. LEITA_BTRFS_DISK, when set, is the total
the walk must reach as root, which tools/btrfs-fixture works out from the image
itself; otherwise the walk must reach what measure charges. measure, as compsize
does (parse_file_extent_item in compsize.c at d79eacf adds an inline extent without
consulting its seen-set), charges an inline extent once for every name that reaches
it, where the walk charges a hard-linked file once, and it follows into every
subvolume, where the walk stops at a read-only one: without LEITA_BTRFS_DISK the
directory named should hold neither.
*/
@(test)
test_walk_charges_btrfs_extents_or_says_why :: proc(t: ^testing.T) {
	dir := os.get_env("LEITA_BTRFS_DIR", context.temp_allocator)
	if dir == "" {
		temp, temp_err := os.temp_directory(context.temp_allocator)
		testing.expect(t, temp_err == nil, "no temp directory")
		dir = fmt.tprintf("%s/leita_walk_btrfs", temp)
		os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil, "could not make the directory")
		data := make([]u8, 64 * 1024, context.temp_allocator)
		for i in 0 ..< 3 {
			path := fmt.tprintf("%s/f%d", dir, i)
			testing.expect(t, os.write_entire_file(path, data[:i * 20000]) == nil)
		}
	}
	defer if os.get_env("LEITA_BTRFS_DIR", context.temp_allocator) == "" {
		os.remove_all(dir)
	}

	fs: linux.Stat_FS
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	testing.expect_value(t, linux.statfs(cdir, &fs), linux.Errno.NONE)
	on_btrfs := fs.type == .BTRFS_SUPER_MAGIC
	searched :=
		on_btrfs &&
		linux.geteuid() == 0 &&
		os.get_env(NO_BTRFS_SEARCH_ENV, context.temp_allocator) == ""

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 4), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(dir, &tree, Config{workers = 4}), Error.None)

	walked, blocks: u64
	files, shared: int
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		flags := scan.node_flags(n)
		if .Used not_in flags || .Directory in flags || .Reparse in flags {
			continue
		}
		if .Shared in flags {
			shared += 1
		}
		if .Extra_Name in flags {
			continue
		}
		files += 1
		walked += n.disk
		path := strings.clone_to_cstring(scan.path(&tree, i, context.temp_allocator))
		defer delete(path)
		st: linux.Statx
		if linux.statx(linux.AT_FDCWD, path, {.SYMLINK_NOFOLLOW}, {.BLOCKS}, &st) == .NONE {
			blocks += st.blocks * 512
			if !searched {
				testing.expectf(
					t,
					n.disk == st.blocks * 512,
					"%s charged %d, not its st_blocks %d",
					path,
					n.disk,
					st.blocks * 512,
				)
			}
		}
	}
	log.infof(
		"%s: %d files, %d shared, walk charged %d against st_blocks %d (btrfs %v, searched %v)",
		dir,
		files,
		shared,
		walked,
		blocks,
		on_btrfs,
		searched,
	)
	testing.expect(t, files > 0, "the walk found no files")
	testing.expect_value(t, scan.is_logical(&tree), on_btrfs && !searched)

	// What the walk must total: st_blocks where it could not search, and otherwise
	// the total given, or what measure charges.
	want := blocks
	if searched {
		disk := os.get_env("LEITA_BTRFS_DISK", context.temp_allocator)
		given, ok := strconv.parse_u64(disk)
		if ok {
			want = given
		} else {
			u: btrfs.Usage
			defer btrfs.usage_destroy(&u)
			testing.expect_value(t, btrfs.measure(dir, &u), btrfs.Error.None)
			want = btrfs.total(u).disk
		}
	} else {
		testing.expect_value(t, shared, 0)
	}
	testing.expect_value(t, walked, want)
}

// The extents the stand-in search hands back for each inode: where each lies on disk
// and what it occupies there. Written before the walk and only read during it.
@(private = "file")
stand_in_extents: map[u64][][2]u64
@(private = "file")
stand_in_refusals: int

// Charges each extent stand_in_extents names for ino, as the kernel's answer would.
@(private = "file")
charge_from_table :: proc(
	dir: linux.Fd,
	ino: u64,
	args: ^btrfs.Search_Args,
	e: ^btrfs.Extents,
	owner: u64,
) -> (
	btrfs.Charge,
	btrfs.Error,
) {
	return charge_listed(stand_in_extents[ino], e, owner)
}

// The file the hard-link test names from many directories, and its one extent. Its
// own, not stand_in_extents: Odin's test runner runs tests in parallel threads, and
// sharing that table failed test_walk_charges_each_extent_once (2026-10-18).
@(private = "file")
linked_inode: u64
@(private = "file")
linked_extent: [2]u64

// Charges linked_extent to linked_inode, and nothing to any other file.
@(private = "file")
charge_linked :: proc(
	dir: linux.Fd,
	ino: u64,
	args: ^btrfs.Search_Args,
	e: ^btrfs.Extents,
	owner: u64,
) -> (
	btrfs.Charge,
	btrfs.Error,
) {
	if ino != linked_inode {
		return {}, .None
	}
	return charge_listed({linked_extent}, e, owner)
}

// Charges each of `extents`, where it lies on disk and what it occupies there.
@(private = "file")
charge_listed :: proc(
	extents: [][2]u64,
	e: ^btrfs.Extents,
	owner: u64,
) -> (
	c: btrfs.Charge,
	err: btrfs.Error,
) {
	for x in extents {
		// struct btrfs_file_extent_item in linux/btrfs_tree.h, regular: type at 20,
		// disk_bytenr at 21, disk_num_bytes at 29, as btrfs/extent.odin reads it.
		item: [53]u8
		item[20] = 1
		endian.put_u64(item[21:29], .Little, x[0])
		endian.put_u64(item[29:37], .Little, x[1])
		if btrfs.charge_shared(item[:], e, owner, &c) != .None {
			return c, .Malformed
		}
	}
	return c, .None
}

@(private = "file")
refuse_search :: proc(
	dir: linux.Fd,
	ino: u64,
	args: ^btrfs.Search_Args,
	e: ^btrfs.Extents,
	owner: u64,
) -> (
	btrfs.Charge,
	btrfs.Error,
) {
	sync.atomic_add(&stand_in_refusals, 1)
	return {}, .Not_Permitted
}

/*
A directory in the temp directory holding a one-byte file for each name, and the
files' inodes. A stand-in search makes the walk treat it as btrfs wherever it is.
*/
@(private = "file")
stand_in_directory :: proc(
	t: ^testing.T,
	name: string,
	files: []string,
) -> (
	dir: string,
	inodes: []u64,
) {
	temp, temp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_err == nil, "no temp directory")
	dir = fmt.tprintf("%s/%s", temp, name)
	os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, "could not make the directory")
	inodes = make([]u64, len(files), context.temp_allocator)
	for f, i in files {
		path := fmt.tprintf("%s/%s", dir, f)
		testing.expect(t, os.write_entire_file(path, []byte{'x'}) == nil)
		st: linux.Statx
		testing.expect_value(
			t,
			linux.statx(
				linux.AT_FDCWD,
				strings.clone_to_cstring(path, context.temp_allocator),
				{},
				{.INO},
				&st,
			),
			linux.Errno.NONE,
		)
		inodes[i] = u64(st.ino)
	}
	return
}

/*
What the walk does with the search's answers, which it gets only as root on btrfs:
a search stands in for the kernel's, anywhere. Each file is charged only the
extents no file before it paid for, so the directory totals each extent once
whichever worker reaches which file first, and exactly one of a file and its
reflinked copy is marked Shared. The tree does not call its sizes logical.
*/
@(test)
test_walk_charges_each_extent_once :: proc(t: ^testing.T) {
	names := []string{"original", "reflink", "other", "inline_only"}
	dir, inodes := stand_in_directory(t, "leita_walk_btrfs_charges", names)
	defer os.remove_all(dir)
	stand_in_extents = make(map[u64][][2]u64, context.temp_allocator)
	stand_in_extents[inodes[0]] = {{1 << 20, 4096}, {2 << 20, 8192}}
	stand_in_extents[inodes[1]] = {{1 << 20, 4096}}
	stand_in_extents[inodes[2]] = {{3 << 20, 12288}, {3 << 20, 12288}}
	search_stand_in = charge_from_table
	defer search_stand_in = nil

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 4), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(dir, &tree, Config{workers = 4}), Error.None)

	walked: u64
	shared := 0
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		flags := scan.node_flags(n)
		if .Used not_in flags || .Directory in flags {
			continue
		}
		walked += n.disk
		if .Shared in flags {
			shared += 1
			testing.expect(
				t,
				scan.name_of(&tree, i) == "original" || scan.name_of(&tree, i) == "reflink",
				"a file that shares nothing is marked Shared",
			)
		}
	}
	testing.expect_value(t, walked, 4096 + 8192 + 12288)
	testing.expect_value(t, shared, 1)
	testing.expect(t, !scan.is_logical(&tree), "searched sizes are called logical")
}

/*
A refused search costs at most one call for each worker, then the pool's files are
charged st_blocks, as off btrfs, and the tree says its sizes are logical.
*/
@(test)
test_a_refused_search_falls_back_to_st_blocks :: proc(t: ^testing.T) {
	names := []string{"a", "b", "c", "d", "e", "f", "g", "h"}
	dir, _ := stand_in_directory(t, "leita_walk_btrfs_refused", names)
	defer os.remove_all(dir)
	for name in names {
		testing.expect(t, os.make_directory(fmt.tprintf("%s/d%s", dir, name)) == nil)
		path := fmt.tprintf("%s/d%s/f", dir, name)
		testing.expect(
			t,
			os.write_entire_file(path, make([]byte, 9000, context.temp_allocator)) == nil,
		)
	}
	search_stand_in = refuse_search
	defer search_stand_in = nil
	sync.atomic_store(&stand_in_refusals, 0)

	WORKERS :: 4
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, WORKERS), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(dir, &tree, Config{workers = WORKERS}), Error.None)

	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		flags := scan.node_flags(n)
		if .Used not_in flags || .Directory in flags {
			continue
		}
		path := strings.clone_to_cstring(
			scan.path(&tree, i, context.temp_allocator),
			context.temp_allocator,
		)
		st: linux.Statx
		testing.expect_value(
			t,
			linux.statx(linux.AT_FDCWD, path, {}, {.BLOCKS}, &st),
			linux.Errno.NONE,
		)
		testing.expectf(t, n.disk == st.blocks * 512, "%s charged %d, not st_blocks", path, n.disk)
		testing.expect(t, .Shared not_in flags, "a file nothing was searched for is Shared")
	}
	refusals := sync.atomic_load(&stand_in_refusals)
	testing.expectf(
		t,
		refusals >= 1 && refusals <= WORKERS,
		"%d refusals for %d workers",
		refusals,
		WORKERS,
	)
	testing.expect(t, scan.is_logical(&tree), "st_blocks on btrfs is not called logical")
}

/*
`root` made afresh holding `dirs` directories, d00 onwards, each with a name for one
file of `size` bytes, written and synced in d00, and that file's inode and
st_blocks. No name lies in the root, so no one worker reads a name before the others
are queued.
*/
@(private = "file")
make_linked_directories :: proc(
	t: ^testing.T,
	root: string,
	dirs, size: int,
) -> (
	inode: u64,
	blocks: u64,
) {
	os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil, "could not make the root")
	for i in 0 ..< dirs {
		testing.expect(t, os.make_directory(fmt.tprintf("%s/d%02d", root, i)) == nil)
	}
	first := fmt.tprintf("%s/d00/name", root)
	data := make([]u8, size, context.temp_allocator)
	for &b, i in data {
		b = u8(i * 7919 >> 3)
	}
	f, open_err := os.open(first, {.Write, .Create, .Trunc})
	testing.expect(t, open_err == nil, "could not create the file")
	_, write_err := os.write(f, data)
	testing.expect(t, write_err == nil, "could not write the file")
	// Synced, so its extents have been written when the walk searches for them.
	testing.expect(t, os.sync(f) == nil, "could not sync the file")
	os.close(f)
	for i in 1 ..< dirs {
		testing.expect(
			t,
			os.link(first, fmt.tprintf("%s/d%02d/name", root, i)) == nil,
			"could not link",
		)
	}
	st: linux.Statx
	testing.expect_value(
		t,
		linux.statx(
			linux.AT_FDCWD,
			strings.clone_to_cstring(first, context.temp_allocator),
			{},
			{.INO, .BLOCKS},
			&st,
		),
		linux.Errno.NONE,
	)
	return u64(st.ino), st.blocks * 512
}

/*
Walk `root`, holding `dirs` names of one file, `rounds` times with `workers`
workers, and expect each walk to charge the file to exactly one name, `want`, and
every other name to be an Extra_Name charged nothing, which keeps `extra`, the
file's st_blocks, whichever worker reads it. Without that, the name a worker counted could be one whose extents
another worker had already claimed for the same owner, so charged nothing and not
Shared, while the name that claimed them was dropped as an extra.
*/
@(private = "file")
expect_charged_once :: proc(
	t: ^testing.T,
	root: string,
	dirs, workers, rounds: int,
	want, extra: u64,
) {
	for _ in 0 ..< rounds {
		tree: scan.Tree
		testing.expect_value(t, scan.tree_init(&tree, workers), scan.Error.None)
		defer scan.tree_destroy(&tree)
		testing.expect_value(t, read(root, &tree, Config{workers = workers}), Error.None)
		names, counted: int
		for i in 0 ..< tree.count {
			n := scan.node(&tree, i)
			flags := scan.node_flags(n)
			if .Used not_in flags || .Directory in flags {
				continue
			}
			names += 1
			testing.expect(t, .Shared not_in flags, "a name of one file is called Shared")
			if .Extra_Name in flags {
				testing.expectf(t, n.disk == extra, "an extra name has %d, not %d", n.disk, extra)
				continue
			}
			counted += 1
			testing.expectf(
				t,
				n.disk == want,
				"the counted name was charged %d, not %d",
				n.disk,
				want,
			)
		}
		testing.expect_value(t, names, dirs)
		testing.expect_value(t, counted, 1)
		testing.expect_value(t, tree.bytes_done, want)
	}
}

/*
One file named from 48 directories and read by 24 workers is charged its extents
once, under one name, however the workers interleave. A stand-in search answers for
it, anywhere; the walk is repeated since the race depends on scheduling.
*/
@(test)
test_a_hard_link_is_charged_its_extents_once_across_workers :: proc(t: ^testing.T) {
	DIRS   :: 48
	EXTENT :: 65536
	temp, temp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_walk_btrfs_links", temp)
	defer os.remove_all(root)
	inode, blocks := make_linked_directories(t, root, DIRS, 1)
	linked_inode, linked_extent = inode, {1 << 20, EXTENT}
	search_stand_in = charge_linked
	defer search_stand_in = nil
	expect_charged_once(t, root, DIRS, 24, 8, EXTENT, blocks)
}

/*
The same with the kernel answering, in LEITA_BTRFS_SCRATCH, the btrfs directory
tools/btrfs-fixture names, or under build/ when it is unset, as
test_the_walk_stays_on_one_filesystem_but_not_one_device does. Where measure can
search, as root on btrfs, the counted name is charged what measure charges the whole
directory; where it cannot, unprivileged or off btrfs, st_blocks, still once.
*/
@(test)
test_a_hard_link_read_from_disk_is_charged_once_across_workers :: proc(t: ^testing.T) {
	DIRS :: 48
	named := os.get_env("LEITA_BTRFS_SCRATCH", context.temp_allocator)
	scratch := named
	if scratch == "" {
		cwd, cwd_err := os.get_working_directory(context.temp_allocator)
		testing.expect(t, cwd_err == nil, "no working directory")
		scratch = fmt.tprintf("%s/build", cwd)
	}
	root := fmt.tprintf("%s/leita_walk_links", scratch)
	defer os.remove_all(root)
	_, blocks := make_linked_directories(t, root, DIRS, 256 * 1024)

	want := blocks
	searched: bool
	u: btrfs.Usage
	defer btrfs.usage_destroy(&u)
	switch btrfs.measure(root, &u) {
	case .None:
		if os.get_env(NO_BTRFS_SEARCH_ENV, context.temp_allocator) == "" {
			want, searched = btrfs.total(u).disk, true
		}
	case .Not_Permitted:
	case .Not_Btrfs, .Unsupported:
		testing.expectf(t, named == "", "LEITA_BTRFS_SCRATCH, %s, is not on btrfs", named)
	case .Not_Found, .Io, .Malformed, .Out_Of_Memory:
		testing.fail_now(t, "measure could not read the directory")
	}
	testing.expect(t, want > 0, "the file was charged nothing")
	log.infof(
		"%s: one file in %d directories, charged %d (searched %v)",
		root,
		DIRS,
		want,
		searched,
	)
	expect_charged_once(t, root, DIRS, 24, 8, want, blocks)
}
