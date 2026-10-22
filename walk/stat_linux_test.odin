#+build linux
package walk

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/linux"
import "core:testing"

import "../scan"

// The tests that set statx_missing, which is the whole process's, take turns.
@(private = "file")
flag_turn: sync.Mutex

@(private = "file")
no_statx :: proc "contextless" (
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
	mask: linux.Statx_Mask,
	st: ^linux.Statx,
) -> linux.Errno {
	return .ENOSYS
}

@(private = "file")
refused :: proc "contextless" (
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
	mask: linux.Statx_Mask,
	st: ^linux.Statx,
) -> linux.Errno {
	return .EACCES
}

@(private = "file")
fixture :: proc(t: ^testing.T, name: string, size: int) -> (root: string, ok: bool) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root = fmt.tprintf("%s/leita_walk_%s_%d", dir, name, os.get_pid())
	os.remove_all(root)
	if os.make_directory(root) != nil || os.make_directory(fmt.tprintf("%s/sub", root)) != nil {
		testing.expect(t, false, "could not make the fixture")
		return "", false
	}
	body := make([]byte, size, context.temp_allocator)
	for &b in body {
		b = 'x'
	}
	for p in ([]string{"a.bin", "sub/b.bin"}) {
		if os.write_entire_file(fmt.tprintf("%s/%s", root, p), body) != nil {
			testing.expect(t, false, "could not write the fixture")
			return "", false
		}
	}
	return root, true
}

// What the walk needs of an entry, fstatat's answer equals statx's.
@(test)
test_the_fstatat_fallback_answers_as_statx_does :: proc(t: ^testing.T) {
	root, ok := fixture(t, "fallback_same", 100_000)
	if !ok {
		return
	}
	defer os.remove_all(root)
	for p in ([]string{"a.bin", "sub", "."}) {
		path := fmt.ctprintf("%s/%s", root, p)
		want, got: linux.Statx
		testing.expect_value(
			t,
			linux.statx(linux.AT_FDCWD, path, {.SYMLINK_NOFOLLOW}, {.TYPE, .MODE, .NLINK, .INO, .SIZE, .BLOCKS}, &want),
			linux.Errno.NONE,
		)
		testing.expect_value(
			t,
			stat_fallback(linux.AT_FDCWD, path, {.SYMLINK_NOFOLLOW}, &got),
			linux.Errno.NONE,
		)
		testing.expect_value(t, got.mode, want.mode)
		testing.expect_value(t, got.ino, want.ino)
		testing.expect_value(t, got.nlink, want.nlink)
		testing.expect_value(t, got.size, want.size)
		testing.expect_value(t, got.blocks, want.blocks)
		testing.expect_value(t, got.dev_major, want.dev_major)
		testing.expect_value(t, got.dev_minor, want.dev_minor)
		testing.expect(t, .MNT_ID not_in got.mask, "the fallback claimed a mount id")
		testing.expect(t, got.attributes == {}, "the fallback claimed attributes")
	}
	// A directory asked through its open descriptor, as the walk asks the root.
	fd, errno := linux.open(fmt.ctprintf("%s/sub", root), {.DIRECTORY, .CLOEXEC})
	testing.expect_value(t, errno, linux.Errno.NONE)
	defer linux.close(fd)
	via, direct: linux.Statx
	testing.expect_value(t, stat_fallback(fd, "", {.EMPTY_PATH}, &via), linux.Errno.NONE)
	testing.expect_value(t, linux.statx(fd, "", {.EMPTY_PATH}, {.INO}, &direct), linux.Errno.NONE)
	testing.expect_value(t, via.ino, direct.ino)
}

// Only ENOSYS is the missing call. Any other answer stands, and the fallback is not
// taken, so a refusal is never answered around.
@(test)
test_only_enosys_falls_back :: proc(t: ^testing.T) {
	sync.guard(&flag_turn)
	root, ok := fixture(t, "fallback_only", 4096)
	if !ok {
		return
	}
	defer os.remove_all(root)
	path := fmt.ctprintf("%s/a.bin", root)
	was := sync.atomic_exchange(&statx_missing, false)
	defer sync.atomic_store(&statx_missing, was)

	st: linux.Statx
	testing.expect_value(t, stat_with(refused, linux.AT_FDCWD, path, {}, {.BLOCKS}, &st), linux.Errno.EACCES)
	testing.expect(t, !bool(sync.atomic_load(&statx_missing)), "a refusal was taken for a missing call")
	testing.expect_value(t, st.blocks, 0)

	testing.expect_value(t, stat_with(no_statx, linux.AT_FDCWD, path, {}, {.BLOCKS}, &st), linux.Errno.NONE)
	testing.expect(t, bool(sync.atomic_load(&statx_missing)), "ENOSYS was not remembered")
	testing.expect(t, st.blocks > 0, "the fallback gave a size of 0 for a file of 4096 bytes")
	testing.expect_value(t, st.size, 4096)

	// Remembered: the kernel's call is not asked again, even one that would answer.
	asked = 0
	testing.expect_value(t, stat_with(counting, linux.AT_FDCWD, path, {}, {.BLOCKS}, &st), linux.Errno.NONE)
	testing.expect_value(t, asked, 0)

	// A refusal of the fallback itself is still the refusal.
	missing := fmt.ctprintf("%s/none", root)
	testing.expect_value(t, stat_with(no_statx, linux.AT_FDCWD, missing, {}, {.BLOCKS}, &st), linux.Errno.ENOENT)
}

@(private = "file")
@(thread_local)
asked: int

@(private = "file")
counting :: proc "contextless" (
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
	mask: linux.Statx_Mask,
	st: ^linux.Statx,
) -> linux.Errno {
	asked += 1
	return .NONE
}

// The kernel's dev_t packing, checked against the device statx reports for /.
@(test)
test_dev_split_matches_statx :: proc(t: ^testing.T) {
	st: linux.Statx
	old: linux.Stat
	testing.expect_value(t, linux.statx(linux.AT_FDCWD, "/", {}, {.INO}, &st), linux.Errno.NONE)
	testing.expect_value(t, linux.fstatat(linux.AT_FDCWD, "/", &old, {}), linux.Errno.NONE)
	major, minor := dev_split(u64(old.dev))
	testing.expect_value(t, major, st.dev_major)
	testing.expect_value(t, minor, st.dev_minor)
	// 259:3 (an nvme partition) packs as 0x103_03 | ..., and a minor above 255 spreads.
	major, minor = dev_split(u64(259) << 8 | 3 | u64(1) << 20)
	testing.expect_value(t, major, 259)
	testing.expect_value(t, minor, 3 | 1 << 8)
}

/*
A walk on a kernel without statx records every file at the size it has, no file
at 0 bytes, the same totals as with statx, and says what it could not give: the
gap, never a wrong figure.
*/
@(test)
test_a_walk_without_statx_sizes_every_file :: proc(t: ^testing.T) {
	sync.guard(&flag_turn)
	root, ok := fixture(t, "walk_no_statx", 200_000)
	if !ok {
		return
	}
	defer os.remove_all(root)

	normal: scan.Tree
	testing.expect_value(t, scan.tree_init(&normal, 1), scan.Error.None)
	defer scan.tree_destroy(&normal)
	was := sync.atomic_exchange(&statx_missing, false)
	defer sync.atomic_store(&statx_missing, was)
	testing.expect_value(t, read(root, &normal, Config{}), Error.None)

	sync.atomic_store(&statx_missing, true)
	old: scan.Tree
	testing.expect_value(t, scan.tree_init(&old, 1), scan.Error.None)
	defer scan.tree_destroy(&old)
	testing.expect_value(t, read(root, &old, Config{}), Error.None)

	testing.expect_value(t, normal.bytes_done, old.bytes_done)
	testing.expect_value(t, normal.nodes_done, old.nodes_done)
	testing.expect(t, old.bytes_done >= 400_000, "the files were not charged their sizes")
	files := 0
	for i in 0 ..< old.count {
		n := scan.node(&old, i)
		if .Used in n.flags && .Directory not_in n.flags && i != old.root {
			files += 1
			testing.expectf(t, n.disk >= 200_000, "%s recorded at %d bytes", scan.name_of(&old, i), n.disk)
		}
	}
	testing.expect_value(t, files, 2)
	count, _ := scan.unread(&old)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, scan.gaps(&old), scan.Gaps{.Statx, .Mount_Id})
	testing.expect(t, .Statx not_in scan.gaps(&normal), "a kernel with statx was said to lack it")
}

// Under the fallback a directory that lists but refuses each entry is still not read
// as empty files (card 523): fstatat's EACCES is Unknown as statx's was.
@(test)
test_a_refusal_under_the_fallback_is_still_unknown :: proc(t: ^testing.T) {
	sync.guard(&flag_turn)
	root, ok := listing_place(t, "listing_no_statx")
	if !ok {
		return
	}
	defer os.remove_all(root)
	defer let_search(root)
	was := sync.atomic_exchange(&statx_missing, true)
	defer sync.atomic_store(&statx_missing, was)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)
	count, denied := scan.unread(&tree)
	testing.expect_value(t, count, 1)
	testing.expect(t, denied, "the refusal was not called one")
	_, big := node_named(&tree, "big.bin")
	testing.expect(t, !big, "a file fstatat could not size was recorded")
	a, sized := node_named(&tree, "a.txt")
	testing.expect(t, sized && a.disk > 0, "a sibling lost its size under the fallback")
	testing.expect(t, tree.bytes_done < 1 << 20, "charged bytes for a file never sized")
}
