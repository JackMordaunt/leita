#+build linux, darwin
package leita_files

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

/*
A tree that cannot all go is reported as such: delete_tree says Partly, counts the
one entry left, not the folders kept for holding it, and gives as freed only what
it unlinked. Here the entry left is the tree itself, whose folder is made read-only
after it was filled, as a scan would find it; everything in it goes, and the tree,
which was read-only as Go leaves its module cache, has that mode back. A file with
another name outside the tree is unlinked but frees nothing, since its blocks stay.
*/
@(test)
a_partial_delete_says_so_and_counts_only_what_went :: proc(t: ^testing.T) {
	if posix.geteuid() == 0 {
		// Root deletes from a read-only folder, so nothing would be left.
		log.warn("skipped: as root a read-only folder does not stop a delete")
		return
	}
	base := temp_root()
	root := strings.concatenate(
		{base, fmt.tprintf("/leita_files_partly_%d", os.get_pid())},
		context.temp_allocator,
	)
	tree := strings.concatenate({root, "/tree"}, context.temp_allocator)
	at :: proc(dir, name: string) -> string {
		return strings.concatenate({dir, name}, context.temp_allocator)
	}
	_ = os.change_mode(root, {.Read_User, .Write_User, .Execute_User})
	os.remove_all(root)
	defer os.remove_all(root)
	defer _ = os.change_mode(root, {.Read_User, .Write_User, .Execute_User})

	testing.expect(t, os.make_directory_all(at(tree, "/sub")) == nil)
	write :: proc(path: string, size: int) -> bool {
		return os.write_entire_file(path, make([]byte, size, context.temp_allocator)) == nil
	}
	testing.expect(t, write(at(tree, "/a"), 8192))
	testing.expect(t, write(at(tree, "/sub/b"), 4096))
	testing.expect(t, write(at(root, "/kept"), 4096))
	testing.expect(t, os.link(at(root, "/kept"), at(tree, "/shared")) == nil)
	want := blocks(at(tree, "/a")) + blocks(at(tree, "/sub/b"))
	testing.expect(t, want > 0, "the files take space")

	read_only := os.Permissions{.Read_User, .Execute_User}
	testing.expect(t, os.change_mode(tree, read_only) == nil)
	testing.expect(t, os.change_mode(root, read_only) == nil)

	failed, freed, err := delete_tree(tree)
	testing.expect_value(t, err, Error.Partly)
	testing.expect_value(t, failed, 1)
	testing.expect_value(t, freed, want)
	testing.expect(t, os.exists(tree), "the tree is still there")
	entries, _ := os.read_all_directory_by_path(tree, context.temp_allocator)
	testing.expect_value(t, len(entries), 0)
	testing.expect(t, os.exists(at(root, "/kept")), "the other name is not touched")
	info, _ := os.stat_do_not_follow_links(tree, context.temp_allocator)
	testing.expect_value(t, info.mode & os.Permissions_All, read_only)
}

// The directory delete_tree is given must not itself be reached through a link.
// macOS's temp directory is named under /var, and that component is one.
@(test)
the_temp_root_a_delete_uses_has_no_link_ancestor :: proc(t: ^testing.T) {
	root := temp_root()
	testing.expect(t, root != "", "a temp directory")
	path := root
	for len(path) > 1 {
		testing.expect(t, !is_link(path), path)
		i := strings.last_index(path, "/")
		if i <= 0 {
			break
		}
		path = path[:i]
	}
}

// blocks is what the file at path takes on disk, as held_alone counts it.
@(private = "file")
blocks :: proc(path: string) -> u64 {
	st: posix.stat_t
	posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st)
	return u64(st.st_blocks) * 512
}

// 60 folders of 100 bytes each below root, past PATH_MAX on Linux (4096) and macOS
// (1024), and a folder victim at the bottom holding one file. Made and removed with
// *at calls, since no path reaches the bottom. walk/unix_test.odin builds a tree as
// deep for the walk; either depth only has to pass PATH_MAX, so the two need not
// stay in step.
@(private)
DEEP_DEPTH :: 60

@(private)
deep_step :: proc() -> cstring {
	return strings.clone_to_cstring(strings.repeat("p", 100, context.temp_allocator), context.temp_allocator)
}

@(private)
deep_make :: proc(t: ^testing.T, root: string) -> (victim: string, ok: bool) {
	at := posix.open(strings.clone_to_cstring(root, context.temp_allocator), {.DIRECTORY})
	if !testing.expect(t, at >= 0, "could not open the root") {
		return "", false
	}

	path := strings.builder_make(context.temp_allocator)
	strings.write_string(&path, root)
	for _ in 0 ..< DEEP_DEPTH {
		testing.expect(t, posix.mkdirat(at, deep_step(), {.IRUSR, .IWUSR, .IXUSR}) == .OK)
		next := posix.openat(at, deep_step(), {.DIRECTORY})
		posix.close(at)
		if !testing.expect(t, next >= 0, "could not open a step") {
			return "", false
		}
		at = next
		strings.write_byte(&path, '/')
		strings.write_string(&path, string(deep_step()))
	}
	defer posix.close(at)

	testing.expect(t, posix.mkdirat(at, "victim", {.IRUSR, .IWUSR, .IXUSR}) == .OK)

	file := posix.openat(at, "victim/file", {.WRONLY, .CREAT}, {.IRUSR, .IWUSR})
	if !testing.expect(t, file >= 0, "could not make the file") {
		return "", false
	}
	posix.close(file)

	strings.write_string(&path, "/victim")
	return strings.to_string(path), true
}

// Whether the file deep_make put at the bottom is still there, asked a folder at a
// time.
@(private)
deep_survives :: proc(victim: string) -> bool {
	fd, err := open_directory(victim)
	if err != .None {
		return false
	}
	defer posix.close(fd)

	st: posix.stat_t
	return posix.fstatat(fd, "file", &st, {.SYMLINK_NOFOLLOW}) == .OK
}

@(private)
deep_remove :: proc(root: string) {
	fds: [DEEP_DEPTH + 1]posix.FD
	fds[0] = posix.open(strings.clone_to_cstring(root, context.temp_allocator), {.DIRECTORY})
	if fds[0] < 0 {
		return
	}

	depth := 0
	for depth < DEEP_DEPTH {
		next := posix.openat(fds[depth], deep_step(), {.DIRECTORY})
		if next < 0 {
			break
		}
		depth += 1
		fds[depth] = next
	}

	posix.unlinkat(fds[depth], "victim/file", {})
	posix.unlinkat(fds[depth], "victim", {.REMOVEDIR})

	for depth > 0 {
		posix.close(fds[depth])
		depth -= 1
		posix.unlinkat(fds[depth], deep_step(), {.REMOVEDIR})
	}
	posix.close(fds[0])
	os.remove_all(root)
}

/*
A folder deeper than PATH_MAX, which the walk reads since card 771 and so can be
offered, is refused by delete_tree, which cannot stat it by its path, and nothing in
it is touched: a delete acts only on what it can open, never on a shorter path.
*/
@(test)
a_delete_past_path_max_is_refused_and_removes_nothing :: proc(t: ^testing.T) {
	root := strings.concatenate(
		{temp_root(), fmt.tprintf("/leita_files_deep_%d", os.get_pid())},
		context.temp_allocator,
	)
	deep_remove(root)
	testing.expect(t, os.make_directory(root) == nil)
	defer deep_remove(root)

	victim, ok := deep_make(t, root)
	if !ok {
		return
	}
	testing.expect(t, deep_survives(victim), "the fixture has no file at the bottom")

	_, freed, err := delete_tree(victim)
	testing.expectf(t, err != .None, "a delete past PATH_MAX said %v", err)
	testing.expect_value(t, freed, 0)
	testing.expect(t, deep_survives(victim), "a refused delete removed the file")
}
