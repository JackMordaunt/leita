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
	base, _ := os.temp_directory(context.temp_allocator)
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

// blocks is what the file at path takes on disk, as held_alone counts it.
@(private = "file")
blocks :: proc(path: string) -> u64 {
	st: posix.stat_t
	posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st)
	return u64(st.st_blocks) * 512
}
