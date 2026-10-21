#+build linux
package walk

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:thread"

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
	testing.expect(t, linked && .Reparse in scan.node_flags(link), "the link beside them was lost")
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
	// A name getdents called a directory and statx calls a symlink was replaced
	// between the two calls. It is a symlink, and must not be queued as a directory.
	testing.expect_value(t, kind_of(.DIR, .NONE, linux.S_IFLNK), Kind.Symlink)
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
	testing.expect_value(t, stat_entry(always_interrupted, 0, "f", {}, {}, &st), linux.Errno.EINTR)
	testing.expect_value(t, asked, STATX_TRIES)
}

// Where one walk replaces a listed directory: `at` is the directory path that
// walk has just finished listing, `dir` is the directory renamed aside, and
// `target` is what the symlink put in its place names.
@(private = "file")
Listed_Swap :: struct {
	at:     string,
	dir:    string,
	target: string,
	done:   bool,
}

@(private = "file")
swap_listed_directory :: proc(path: string, data: rawptr) {
	swap := cast(^Listed_Swap)data
	if swap == nil || swap.done || path != swap.at {
		return
	}
	swap.done = true
	real := fmt.tprintf("%s.real", swap.dir)
	if os.rename(swap.dir, real) != nil {
		return
	}
	_ = os.symlink(swap.target, swap.dir)
}

// `base` holds `root` and `outside` beside it. The caller removes `base`.
@(private = "file")
swap_fixture :: proc(t: ^testing.T, name: string) -> (base, root, outside: string) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	base = fmt.tprintf("%s/leita_walk_replace_%s_%d", dir, name, os.get_pid())
	os.remove_all(base)
	root = fmt.tprintf("%s/root", base)
	outside = fmt.tprintf("%s/outside", base)
	testing.expect(t, os.make_directory_all(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory_all(outside) == nil, "could not make the outside")
	return
}

// Walk `root` with `swap` aimed at one directory. `workers` is 1.
@(private = "file")
walk_swapped :: proc(t: ^testing.T, root: string, swap: ^Listed_Swap) -> scan.Tree {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	testing.expect_value(
		t,
		read(
			root,
			&tree,
			Config{workers = 1, after_list = swap_listed_directory, after_list_data = swap},
		),
		Error.None,
	)
	open, counted := count_fds_under(root)
	testing.expect(t, counted, "could not read /proc/self/fd")
	testing.expect_value(t, open, 0)
	return tree
}

// How many descriptors this process holds whose target is under `prefix`.
@(private = "file")
count_fds_under :: proc(prefix: string) -> (n: int, ok: bool) {
	fd, errno := linux.open("/proc/self/fd", {.DIRECTORY, .CLOEXEC})
	if errno != .NONE {
		return 0, false
	}
	defer linux.close(fd)
	buf: [8 * 1024]u8
	for {
		got, err := linux.getdents(fd, buf[:])
		if err != .NONE {
			return 0, false
		}
		if got == 0 {
			break
		}
		offset := 0
		for entry in linux.dirent_iterate_buf(buf[:got], &offset) {
			name := linux.dirent_name(entry)
			if name == "." || name == ".." {
				continue
			}
			target, rd_err := os.read_link(
				fmt.tprintf("/proc/self/fd/%s", name),
				context.temp_allocator,
			)
			if rd_err == nil && strings.has_prefix(target, prefix) {
				n += 1
			}
		}
	}
	return n, true
}

@(private = "file")
is_symlink :: proc(path: string) -> bool {
	buf: Path
	cpath, ok := terminate(path, &buf)
	if !ok {
		return false
	}
	st: linux.Statx
	if linux.statx(linux.AT_FDCWD, cpath, {.SYMLINK_NOFOLLOW}, {.TYPE}, &st) != .NONE {
		return false
	}
	return linux.S_ISLNK(st.mode)
}

/*
A directory listed as a directory and replaced with a symlink before it is
opened must not be followed. The symlink names a directory outside the walk.
*/
@(test)
test_replacing_a_directory_with_a_symlink_is_not_followed :: proc(t: ^testing.T) {
	base, root, outside := swap_fixture(t, "final")
	defer os.remove_all(base)

	sub := fmt.tprintf("%s/sub", root)
	testing.expect(t, os.make_directory(sub) == nil, "could not make sub")
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/inside.txt", sub), []byte{'i'}) == nil,
		"could not write inside",
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/secret.txt", outside), []byte{'s'}) == nil,
		"could not write secret",
	)

	swap := Listed_Swap {
		at     = root,
		dir    = sub,
		target = outside,
	}
	tree := walk_swapped(t, root, &swap)
	defer scan.tree_destroy(&tree)

	testing.expect(t, swap.done, "the directory was not replaced")
	testing.expect(t, is_symlink(sub), "sub is not a symlink after the walk")
	_, secret := node_named(&tree, "secret.txt")
	_, inside := node_named(&tree, "inside.txt")
	testing.expect(t, !secret, "the symlink target was walked")
	testing.expect(t, !inside, "the replaced directory was still walked")
	got, found := node_named(&tree, "sub")
	testing.expect(t, found, "sub was not recorded")
	if found {
		flags := scan.node_flags(got)
		testing.expect(t, .Directory in flags, "sub is not a directory")
		testing.expect(t, .Unread in flags, "sub was not left unread")
	}
}

/*
The component above the one being opened is replaced with a symlink. Refusing
only the final component would still follow this one and read `outside`.
*/
@(test)
test_replacing_an_intermediate_directory_is_not_followed :: proc(t: ^testing.T) {
	base, root, outside := swap_fixture(t, "middle")
	defer os.remove_all(base)

	a := fmt.tprintf("%s/a", root)
	b := fmt.tprintf("%s/b", a)
	testing.expect(t, os.make_directory_all(b) == nil, "could not make a/b")
	testing.expect(
		t,
		os.make_directory(fmt.tprintf("%s/b", outside)) == nil,
		"could not make outside/b",
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/inside.txt", b), []byte{'i'}) == nil,
		"could not write inside",
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/b/secret.txt", outside), []byte{'s'}) == nil,
		"could not write secret",
	)

	swap := Listed_Swap {
		at     = a,
		dir    = a,
		target = outside,
	}
	tree := walk_swapped(t, root, &swap)
	defer scan.tree_destroy(&tree)

	testing.expect(t, swap.done, "the directory was not replaced")
	testing.expect(t, is_symlink(a), "a is not a symlink after the walk")
	_, secret := node_named(&tree, "secret.txt")
	_, inside := node_named(&tree, "inside.txt")
	testing.expect(t, !secret, "the symlink target was walked")
	testing.expect(t, !inside, "the directory below the symlink was walked")
	got, found := node_named(&tree, "b")
	testing.expect(t, found, "b was not recorded")
	if found {
		testing.expect(t, .Unread in scan.node_flags(got), "b was not left unread")
	}
}

// A real directory opens. A symlink component does not, and neither does "..".
@(test)
test_a_component_walk_does_not_follow_a_symlink :: proc(t: ^testing.T) {
	base, root, outside := swap_fixture(t, "components")
	defer os.remove_all(base)
	real := fmt.tprintf("%s/real", root)
	testing.expect(
		t,
		os.make_directory_all(fmt.tprintf("%s/nest", real)) == nil,
		"could not make real",
	)
	testing.expect(
		t,
		os.make_directory(fmt.tprintf("%s/nest", outside)) == nil,
		"could not make outside",
	)
	link := fmt.tprintf("%s/link", root)
	testing.expect(t, os.symlink(outside, link) == nil, "could not link outside")

	dir, errno := linux.open(
		strings.clone_to_cstring(root, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	testing.expect_value(t, errno, linux.Errno.NONE)
	defer linux.close(dir)

	got, got_err := open_nofollow(dir, "real/nest")
	testing.expect_value(t, got_err, linux.Errno.NONE)
	linux.close(got)

	// The helper treats ENOTDIR and ELOOP as a refused open.
	refused := proc(errno: linux.Errno) -> bool {
		return errno == .ENOTDIR || errno == .ELOOP
	}
	_, link_err := open_nofollow(dir, "link")
	testing.expectf(t, refused(link_err), "a symlink opened: %v", link_err)
	_, mid_err := open_nofollow(dir, "link/nest")
	testing.expectf(t, refused(mid_err), "a symlink in the middle opened: %v", mid_err)
	_, dot_err := open_nofollow(dir, "..")
	testing.expect_value(t, dot_err, linux.Errno.EXDEV)
	_, nested_dot := open_nofollow(dir, "real/..")
	testing.expect_value(t, nested_dot, linux.Errno.EXDEV)

	beneath, beneath_err := open_beneath(
		dir,
		strings.clone_to_cstring("real/nest", context.temp_allocator),
	)
	testing.expect_value(t, beneath_err, linux.Errno.NONE)
	linux.close(beneath)
	_, beneath_link := open_beneath(
		dir,
		strings.clone_to_cstring("link/nest", context.temp_allocator),
	)
	testing.expect_value(t, beneath_link, linux.Errno.ELOOP)
	_, beneath_dot := open_beneath(dir, strings.clone_to_cstring("..", context.temp_allocator))
	testing.expect_value(t, beneath_dot, linux.Errno.EXDEV)
}

// The path the caller names may itself be a symlink. The walk reads that
// directory.
@(test)
test_a_symlink_to_the_root_is_read :: proc(t: ^testing.T) {
	base, root, _ := swap_fixture(t, "rootlink")
	defer os.remove_all(base)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/sub", root)) == nil, "could not make sub")
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/sub/f.txt", root), []byte{'f'}) == nil,
		"could not write f.txt",
	)
	link := fmt.tprintf("%s/link", base)
	testing.expect(t, os.symlink(root, link) == nil, "could not link the root")

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(link, &tree, Config{workers = 1}), Error.None)
	_, found := node_named(&tree, "f.txt")
	testing.expect(t, found, "the directory named by the symlink root was not read")
	open, counted := count_fds_under(base)
	testing.expect(t, counted, "could not read /proc/self/fd")
	testing.expect_value(t, open, 0)
}

@(test)
test_rel_under_rejects_a_sibling_prefix :: proc(t: ^testing.T) {
	_, sibling := rel_under("/tmp/a", "/tmp/ab")
	testing.expect(t, !sibling, "a sibling prefix was accepted")
	child_rel, child := rel_under("/tmp/a", "/tmp/a/b")
	testing.expect(t, child && child_rel == "b", "a child was rejected")
	same_rel, same := rel_under("/tmp/a", "/tmp/a")
	testing.expect(t, same && same_rel == "", "the root was rejected")
	_, slash := rel_under("/tmp/a", "/tmp/a/")
	testing.expect(t, !slash, "a trailing slash was a child")
	rooted_rel, rooted := rel_under("/tmp/a/", "/tmp/a/b")
	testing.expect(t, rooted && rooted_rel == "b", "a slashed root rejected its child")
	top_rel, top := rel_under("/", "/tmp/a")
	testing.expect(t, top && top_rel == "tmp/a", "the filesystem root rejected a child")
}

@(test)
test_anchor_prepare_closes_its_fd_when_allocation_fails :: proc(t: ^testing.T) {
	base, root, _ := swap_fixture(t, "anchor-alloc")
	defer os.remove_all(base)
	before, before_ok := count_fds_under(root)
	testing.expect(t, before_ok && before == 0, "the fixture was already open")

	refuse :: proc(
		data: rawptr,
		mode: mem.Allocator_Mode,
		size, alignment: int,
		old_memory: rawptr,
		old_size: int,
		loc := #caller_location,
	) -> (
		[]byte,
		mem.Allocator_Error,
	) {
		_ = data
		_ = mode
		_ = size
		_ = alignment
		_ = old_memory
		_ = old_size
		_ = loc
		return nil, .Out_Of_Memory
	}
	held, err := anchor_prepare(root, false, mem.Allocator{procedure = refuse})
	testing.expect(t, err != nil, "allocation was reported as success")
	testing.expect(t, held.fd < 0, "the failed anchor kept a descriptor")
	after, after_ok := count_fds_under(root)
	testing.expect(t, after_ok && after == 0, "the descriptor was not closed")
}

@(test)
test_a_walk_without_an_anchor_does_not_open_the_path :: proc(t: ^testing.T) {
	base, root, _ := swap_fixture(t, "unanchored")
	defer os.remove_all(base)
	before, before_ok := count_fds_under(root)
	testing.expect(t, before_ok && before == 0, "the fixture was already open")

	w: Worker
	w.follow = false
	w.held.fd = -1
	w.held.errno = .EACCES
	buf: Path
	fd, errno := open_listed(Dir{path = root}, &w, &buf)
	testing.expect_value(t, errno, linux.Errno.EACCES)
	testing.expect(t, int(i32(fd)) < 0 || errno != .NONE, "the path was opened")
	after, after_ok := count_fds_under(root)
	testing.expect(t, after_ok && after == 0, "a descriptor was left open")

	w.follow = true
	w.held.errno = .NONE
	opened, open_err := open_listed(Dir{path = root}, &w, &buf)
	testing.expect_value(t, open_err, linux.Errno.NONE)
	linux.close(opened)
}

Swap_Task :: struct {
	root:    string,
	swap:    Listed_Swap,
	err:     Error,
	secret:  bool,
	inside:  bool,
	unread:  bool,
	open:    int,
	counted: bool,
	is_link: bool,
}

run_swap_task :: proc(th: ^thread.Thread) {
	task := cast(^Swap_Task)th.data
	tree: scan.Tree
	if scan.tree_init(&tree, 1) != .None {
		task.err = .Out_Of_Memory
		return
	}
	defer scan.tree_destroy(&tree)
	task.err = read(
		task.root,
		&tree,
		Config{workers = 1, after_list = swap_listed_directory, after_list_data = &task.swap},
	)
	_, task.secret = node_named(&tree, "secret.txt")
	_, task.inside = node_named(&tree, "inside.txt")
	if got, found := node_named(&tree, "sub"); found {
		task.unread = .Unread in scan.node_flags(got)
	}
	task.open, task.counted = count_fds_under(task.root)
	task.is_link = is_symlink(task.swap.dir)
}

@(test)
test_replacement_state_stays_on_its_walk :: proc(t: ^testing.T) {
	base_a, root_a, outside_a := swap_fixture(t, "cross-a")
	defer os.remove_all(base_a)
	base_b, root_b, outside_b := swap_fixture(t, "cross-b")
	defer os.remove_all(base_b)
	sub_a := fmt.tprintf("%s/sub", root_a)
	sub_b := fmt.tprintf("%s/sub", root_b)
	testing.expect(t, os.make_directory(sub_a) == nil, "could not make sub a")
	testing.expect(t, os.make_directory(sub_b) == nil, "could not make sub b")
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/inside.txt", sub_a), []byte{'a'}) == nil,
		"could not write inside a",
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/inside.txt", sub_b), []byte{'b'}) == nil,
		"could not write inside b",
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/secret.txt", outside_a), []byte{'a'}) == nil,
		"could not write secret a",
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/secret.txt", outside_b), []byte{'b'}) == nil,
		"could not write secret b",
	)

	task_a := Swap_Task {
		root = root_a,
		swap = Listed_Swap{at = root_a, dir = sub_a, target = outside_a},
	}
	task_b := Swap_Task {
		root = root_b,
		swap = Listed_Swap{at = root_b, dir = sub_b, target = outside_b},
	}
	thread_a := thread.create(run_swap_task)
	thread_b := thread.create(run_swap_task)
	thread_a.data = &task_a
	thread_b.data = &task_b
	thread.start(thread_a)
	thread.start(thread_b)
	thread.join(thread_a)
	thread.join(thread_b)
	thread.destroy(thread_a)
	thread.destroy(thread_b)

	check_task :: proc(t: ^testing.T, task: Swap_Task, name: string) {
		testing.expectf(t, task.err == .None, "%s walk failed: %v", name, task.err)
		testing.expectf(t, task.swap.done, "%s was not replaced", name)
		testing.expectf(t, task.is_link, "%s is not a symlink", name)
		testing.expectf(t, !task.secret, "%s followed the symlink", name)
		testing.expectf(t, !task.inside, "%s walked the replaced directory", name)
		testing.expectf(t, task.unread, "%s left sub readable", name)
		testing.expectf(t, task.counted && task.open == 0, "%s leaked a descriptor", name)
	}
	check_task(t, task_a, "a")
	check_task(t, task_b, "b")
}
