#+build linux
package walk

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

import "../scan"

/*
A directory's entries are asked about in inode order, whatever order the
directory lists them in, so a cold read goes through the inode table once rather
than seeking for each. The tree records them in the order they are asked about.

The test only tells the orders apart where the filesystem lists entries in some
other order. tmpfs, where the temp directory usually is, lists the newest first.
*/
@(test)
test_entries_are_read_in_inode_order :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_walk_inodes_%d", dir, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	for i in 0 ..< 40 {
		path := fmt.tprintf("%s/f%02d", root, (i * 7) % 40)
		testing.expectf(
			t,
			os.write_entire_file(path, []byte{'x'}) == nil,
			"could not write %s",
			path,
		)
	}

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	last: u64
	count := 0
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i == tree.root || .Used not_in n.flags {
			continue
		}
		path := strings.clone_to_cstring(
			fmt.tprintf("%s/%s", root, scan.name_of(&tree, i)),
			context.temp_allocator,
		)
		st: linux.Statx
		testing.expect(t, linux.statx(linux.AT_FDCWD, path, {}, {.INO}, &st) == .NONE)
		testing.expectf(
			t,
			u64(st.ino) > last,
			"%s (inode %d) was read after inode %d",
			scan.name_of(&tree, i),
			st.ino,
			last,
		)
		last = u64(st.ino)
		count += 1
	}
	testing.expect_value(t, count, 40)
}

/*
A directory another filesystem is mounted on is recorded as a mount and not walked,
so a scan of / leaves /proc and /sys alone. Nothing unprivileged can mount a
filesystem for the test, so it reads /dev, where systemd mounts pts, shm and mqueue,
each its own device; this machine has those and hugepages (2026-10-15). It skips
where /proc/self/mounts names nothing directly beneath /dev.
*/
@(test)
test_a_directory_on_another_device_is_a_mount :: proc(t: ^testing.T) {
	ROOT :: "/dev"
	text, read_err := os.read_entire_file("/proc/self/mounts", context.temp_allocator)
	if read_err != nil {
		log.warnf("skipped: /proc/self/mounts would not open: %v", read_err)
		return
	}
	mounted: [dynamic]string
	mounted.allocator = context.temp_allocator
	lines := string(text)
	for line in strings.split_lines_iterator(&lines) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 {
			continue
		}
		// Only those directly beneath it, whose names the tree holds as they are;
		// mount points with escaped spaces are left out rather than unescaped.
		if !strings.has_prefix(fields[1], ROOT + "/") {
			continue
		}
		name := fields[1][len(ROOT) + 1:]
		if name != "" && !strings.contains_any(name, "/\\") {
			append(&mounted, name)
		}
	}
	if len(mounted) == 0 {
		log.warnf("skipped: nothing is mounted directly beneath %s", ROOT)
		return
	}

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(ROOT, &tree, Config{}), Error.None)

	children := make([]int, tree.count, context.temp_allocator)
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i != tree.root && .Used in n.flags {
			children[n.parent] += 1
		}
	}
	for name in mounted {
		found := false
		for i in 0 ..< tree.count {
			n := scan.node(&tree, i)
			if i == tree.root || .Used not_in n.flags || n.parent != tree.root {
				continue
			}
			if scan.name_of(&tree, i) != name {
				continue
			}
			found = true
			testing.expectf(t, .Mount in n.flags, "%s/%s is not marked a mount", ROOT, name)
			testing.expectf(
				t,
				children[i] == 0,
				"%s/%s was walked: %d entries beneath it",
				ROOT,
				name,
				children[i],
			)
		}
		testing.expectf(t, found, "%s/%s is not in the tree", ROOT, name)
	}
}

/*
A directory on the same filesystem is walked and one on another is not. A btrfs
subvolume has a device of its own but lies in the same pool, so it is walked,
while a read-only one, as snapper's snapshots are, is stopped at as a mount is.
btrfs lets the owner of a directory make a subvolume in it and mark it read-only, so
the test builds both in LEITA_BTRFS_SCRATCH, a btrfs directory it may write in,
which tools/btrfs-fixture names; it fails if that is not btrfs. Unset, it builds
them beside the working directory, under build/, and where that is not btrfs it
checks only that the same filesystem is walked and /proc is not.
*/
@(test)
test_the_walk_stays_on_one_filesystem_but_not_one_device :: proc(t: ^testing.T) {
	scratch := os.get_env("LEITA_BTRFS_SCRATCH", context.temp_allocator)
	if scratch == "" {
		cwd, cwd_err := os.get_working_directory(context.temp_allocator)
		testing.expect(t, cwd_err == nil, "no working directory")
		scratch = fmt.tprintf("%s/build", cwd)
	}
	root := fmt.tprintf("%s/leita_walk_subvolumes_%d", scratch, os.get_pid())
	defer remove_subvolumes(root)
	remove_subvolumes(root)
	testing.expect(t, os.make_directory_all(root) == nil, "could not make the root")

	// On any filesystem: a directory on the same one is walked, and /proc, which
	// is always its own, is not.
	testing.expect(t, os.make_directory(fmt.tprintf("%s/plain", root)) == nil)
	dir, dir_errno := linux.open(
		strings.clone_to_cstring(root, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	testing.expect_value(t, dir_errno, linux.Errno.NONE)
	defer linux.close(dir)
	here, here_btrfs := filesystem_of(dir)
	testing.expect(t, here != 0, "the root's filesystem is unknown")
	plain: linux.Statx
	testing.expect_value(
		t,
		linux.statx(dir, "plain", {.NO_AUTOMOUNT}, {}, &plain),
		linux.Errno.NONE,
	)
	stop, on, on_btrfs := stops_at(dir, raw_data(string("plain")), plain, here, here_btrfs)
	testing.expect(t, !stop, "a directory on the same filesystem is stopped at")
	testing.expect(t, on == here, "a directory on the same filesystem names another")
	testing.expect(t, on_btrfs == here_btrfs, "a directory on the same filesystem is another kind")
	slash, slash_errno := linux.open("/", {.DIRECTORY, .CLOEXEC})
	testing.expect_value(t, slash_errno, linux.Errno.NONE)
	defer linux.close(slash)
	procfs: linux.Statx
	testing.expect_value(
		t,
		linux.statx(slash, "proc", {.NO_AUTOMOUNT}, {}, &procfs),
		linux.Errno.NONE,
	)
	stop, on, on_btrfs = stops_at(slash, raw_data(string("proc")), procfs, here, here_btrfs)
	testing.expect(t, !on_btrfs, "/proc is called btrfs")
	testing.expect(t, stop, "/proc is not stopped at")
	testing.expect(t, on != here, "/proc is named the root's filesystem")

	// The subvolumes this makes are btrfs ones.
	fs: linux.Stat_FS
	testing.expect_value(t, linux.fstatfs(dir, &fs), linux.Errno.NONE)
	if fs.type != .BTRFS_SUPER_MAGIC {
		testing.expectf(
			t,
			os.get_env("LEITA_BTRFS_SCRATCH", context.temp_allocator) == "",
			"LEITA_BTRFS_SCRATCH is on %v, not btrfs",
			fs.type,
		)
		log.warnf("subvolumes not checked: %s is on %v, not btrfs", root, fs.type)
		return
	}
	testing.expect(t, make_subvolume(root, "sub"), "could not make a subvolume")
	testing.expect(t, make_subvolume(root, "ro"), "could not make a second subvolume")
	for name in ([]string{"plain/a", "sub/b", "ro/c"}) {
		path := fmt.tprintf("%s/%s", root, name)
		testing.expectf(
			t,
			os.write_entire_file(path, []byte{'x'}) == nil,
			"could not write %s",
			path,
		)
	}
	testing.expect(
		t,
		set_read_only(fmt.tprintf("%s/ro", root), true),
		"could not mark ro read-only",
	)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	children := make([]int, tree.count, context.temp_allocator)
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i != tree.root && .Used in n.flags {
			children[n.parent] += 1
		}
	}
	seen := 0
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i == tree.root || .Used not_in n.flags || n.parent != tree.root {
			continue
		}
		switch scan.name_of(&tree, i) {
		case "plain", "sub":
			seen += 1
			testing.expectf(
				t,
				.Mount not_in n.flags,
				"%s is marked a mount",
				scan.name_of(&tree, i),
			)
			testing.expectf(
				t,
				children[i] == 1,
				"%s holds %d entries, not 1",
				scan.name_of(&tree, i),
				children[i],
			)
		case "ro":
			seen += 1
			testing.expect(t, .Mount in n.flags, "the read-only subvolume is not marked a mount")
			testing.expectf(
				t,
				children[i] == 0,
				"the read-only subvolume was walked: %d entries",
				children[i],
			)
		}
	}
	testing.expect_value(t, seen, 3)
}

// From linux/btrfs.h: _IOW(0x94, 14, struct btrfs_ioctl_vol_args) and
// _IOW(0x94, 26, __u64).
@(private = "file")
BTRFS_IOC_SUBVOL_CREATE :: 0x5000940e
@(private = "file")
BTRFS_IOC_SUBVOL_SETFLAGS :: 0x4008941a

// Make a btrfs subvolume called `name` in `dir`; false where dir is not btrfs.
@(private = "file")
make_subvolume :: proc(dir: string, name: string) -> bool {
	fd, errno := linux.open(
		strings.clone_to_cstring(dir, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	if errno != .NONE {
		return false
	}
	defer linux.close(fd)
	// struct btrfs_ioctl_vol_args: an fd, then the name in the rest of 4096 bytes.
	args: struct {
		fd:   i64,
		name: [4088]u8,
	}
	copy(args.name[:len(args.name) - 1], name)
	return int(linux.ioctl(fd, BTRFS_IOC_SUBVOL_CREATE, uintptr(&args))) >= 0
}

@(private = "file")
set_read_only :: proc(path: string, on: bool) -> bool {
	fd, errno := linux.open(
		strings.clone_to_cstring(path, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	if errno != .NONE {
		return false
	}
	defer linux.close(fd)
	flags: u64 = on ? BTRFS_SUBVOL_RDONLY : 0
	return int(linux.ioctl(fd, BTRFS_IOC_SUBVOL_SETFLAGS, uintptr(&flags))) >= 0
}

// A read-only subvolume refuses to have its files removed, so it is made writable
// first; an empty subvolume is then removed as a directory is.
@(private = "file")
remove_subvolumes :: proc(root: string) {
	set_read_only(fmt.tprintf("%s/ro", root), false)
	os.remove_all(root)
}

/*
A directory whose mode lists its names but refuses to let them be asked about:

	<root>/a.txt                100 bytes
	<root>/listing/             mode 0644: read, but no search
	<root>/listing/big.bin      1 MiB
	<root>/listing/inner/       a directory
	<root>/listing/link         a symlink to big.bin

Root asks about anything, so the fixture means nothing there and the caller skips.
*/
@(private = "file")
listing_place :: proc(t: ^testing.T, name: string) -> (root: string, ok: bool) {
	if linux.geteuid() == 0 {
		log.info("skipped: root can ask about any entry")
		return "", false
	}
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root = fmt.tprintf("%s/leita_walk_%s_%d", dir, name, os.get_pid())
	let_search(root)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	listing := fmt.tprintf("%s/listing", root)
	testing.expect(t, os.make_directory(listing) == nil, "could not make listing")
	testing.expect(t, os.make_directory(fmt.tprintf("%s/inner", listing)) == nil, "no inner")
	body := make([]byte, 1 << 20, context.temp_allocator)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/big.bin", listing), body) == nil,
		"no big",
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/a.txt", root), body[:100]) == nil,
		"no a",
	)
	testing.expect(t, os.symlink("big.bin", fmt.tprintf("%s/link", listing)) == nil, "no link")
	testing.expect(
		t,
		os.chmod(listing, {.Read_User, .Write_User, .Read_Group, .Read_Other}) == nil,
		"could not take search off the directory",
	)
	return root, true
}

// Give the listing directory its search permission back, so it can be removed.
@(private = "file")
let_search :: proc(root: string) {
	os.chmod(fmt.tprintf("%s/listing", root), {.Read_User, .Write_User, .Execute_User})
}

@(private = "file")
node_named :: proc(tree: ^scan.Tree, name: string) -> (n: ^scan.Node, found: bool) {
	for i in 0 ..< tree.count {
		n = scan.node(tree, i)
		if .Used in scan.node_flags(n) && scan.name_of(tree, i) == name {
			return n, true
		}
	}
	return nil, false
}

/*
A directory that lists its names but refuses a statx of each is not read as a
directory of empty files: an entry whose size statx would not give is left out, a
directory it would not describe is not walked, and the directory is marked unread
and counted, refused for want of permission, while the scan succeeds. Its siblings
keep their sizes, and so does an entry in it that needed no asking (the link).
*/
@(test)
test_entries_that_cannot_be_asked_about_are_not_empty :: proc(t: ^testing.T) {
	root, ok := listing_place(t, "listing")
	if !ok {
		return
	}
	defer os.remove_all(root)
	defer let_search(root)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	count, denied := scan.unread(&tree)
	testing.expect_value(t, count, 1)
	testing.expect(t, denied, "a statx refused for permission was not called so")
	listing, found := node_named(&tree, "listing")
	testing.expect(t, found, "the listing directory is not in the tree")
	if found {
		flags := scan.node_flags(listing)
		testing.expect(t, .Unread in flags && .Directory in flags, "listing is not flagged")
	}
	_, big := node_named(&tree, "big.bin")
	testing.expect(t, !big, "a file statx could not size was recorded")
	_, inner := node_named(&tree, "inner")
	testing.expect(t, !inner, "a directory statx could not describe was recorded")
	link, linked := node_named(&tree, "link")
	testing.expect(
		t,
		linked && .Reparse in scan.node_flags(link),
		"the link beside them was lost",
	)
	a, sized := node_named(&tree, "a.txt")
	testing.expect(t, sized && a.disk > 0, "a sibling of the listing directory lost its size")
	testing.expectf(
		t,
		tree.bytes_done < 1 << 20,
		"charged %d bytes for a file never sized",
		tree.bytes_done,
	)
}

/*
What an entry is from its directory entry's type and statx's answer. The temp
directory these tests use gives every entry a type, and the only refusal it can be
made to give unprivileged is the whole directory's (above), so DT_UNKNOWN and one
entry refused among others are put to the decision directly: whatever the type, a failed statx is Unknown, which is never
recorded and so never walked, and only ENOENT, an entry gone since it was listed,
is left out without marking its directory.
*/
@(test)
test_an_entry_statx_could_not_answer_is_unknown :: proc(t: ^testing.T) {
	testing.expect_value(t, kind_of(.UNKNOWN, .EACCES, {}), Kind.Unknown)
	testing.expect_value(t, kind_of(.UNKNOWN, .EIO, linux.S_IFDIR), Kind.Unknown)
	testing.expect_value(t, kind_of(.DIR, .EACCES, {}), Kind.Unknown)
	testing.expect_value(t, kind_of(.REG, .EACCES, {}), Kind.Unknown)
	testing.expect_value(t, kind_of(.REG, .EINTR, {}), Kind.Unknown)
	testing.expect_value(t, kind_of(.REG, .ENOENT, {}), Kind.Gone)
	testing.expect_value(t, kind_of(.DIR, .ENOENT, {}), Kind.Gone)

	testing.expect_value(t, kind_of(.UNKNOWN, .NONE, linux.S_IFDIR), Kind.Directory)
	testing.expect_value(t, kind_of(.UNKNOWN, .NONE, linux.S_IFLNK), Kind.Symlink)
	testing.expect_value(t, kind_of(.UNKNOWN, .NONE, linux.S_IFREG), Kind.File)
	testing.expect_value(t, kind_of(.DIR, .NONE, linux.S_IFDIR), Kind.Directory)
	testing.expect_value(t, kind_of(.LNK, .NONE, {}), Kind.Symlink)
	testing.expect_value(t, kind_of(.REG, .NONE, linux.S_IFREG), Kind.File)
	testing.expect_value(t, kind_of(.FIFO, .NONE, {}), Kind.File)
}

// How many times a stand-in for statx has been asked, on this test's thread.
@(private = "file")
@(thread_local)
asked: int

@(private = "file")
interrupted_twice :: proc "contextless" (
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
	mask: linux.Statx_Mask,
	st: ^linux.Statx,
) -> linux.Errno {
	asked += 1
	if asked <= 2 {
		return .EINTR
	}
	st.blocks = 8
	return .NONE
}

@(private = "file")
always_interrupted :: proc "contextless" (
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
	mask: linux.Statx_Mask,
	st: ^linux.Statx,
) -> linux.Errno {
	asked += 1
	return .EINTR
}

// A statx a signal interrupts is asked again and its answer kept; one interrupted
// every time is given up after STATX_TRIES, as an entry not known.
@(test)
test_an_interrupted_statx_is_asked_again :: proc(t: ^testing.T) {
	st: linux.Statx
	asked = 0
	testing.expect_value(t, stat_entry(interrupted_twice, 0, "f", {}, {}, &st), linux.Errno.NONE)
	testing.expect_value(t, asked, 3)
	testing.expect_value(t, st.blocks, 8)

	asked = 0
	testing.expect_value(
		t,
		stat_entry(always_interrupted, 0, "f", {}, {}, &st),
		linux.Errno.EINTR,
	)
	testing.expect_value(t, asked, STATX_TRIES)
}
