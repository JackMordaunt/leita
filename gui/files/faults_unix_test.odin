#+build linux, darwin
package leita_files

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "../../faults"

// FAULT_TREE is what fault_tree makes under tree, each file's size beside it; the
// folders are tree and sub.
@(private = "file")
FAULT_TREE := [?]struct {
	name: string,
	size: int,
}{{"/a", 8192}, {"/b", 4096}, {"/sub/c", 4096}, {"/sub/d", 4096}}

@(private = "file")
fault_tree :: proc(t: ^testing.T, root: string) -> (tree, outside: string) {
	tree = strings.concatenate({root, "/tree"}, context.temp_allocator)
	outside = strings.concatenate({root, "/outside"}, context.temp_allocator)
	os.remove_all(root)
	testing.expect(t, os.make_directory_all(strings.concatenate({tree, "/sub"}, context.temp_allocator)) == nil)
	testing.expect(t, os.write_entire_file(outside, make([]byte, 4096, context.temp_allocator)) == nil)

	for f in FAULT_TREE {
		path := strings.concatenate({tree, f.name}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, make([]byte, f.size, context.temp_allocator)) == nil)
	}
	return
}

// on_disk is what the file at path takes on disk, as held_alone counts it; 0 when
// it is gone.
@(private = "file")
on_disk :: proc(path: string) -> u64 {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {
		return 0
	}
	return u64(st.st_blocks) * 512
}

/*
An entry the disk will not let go, at each place in a tree in turn, file or folder: the
delete says Partly and counts the one entry left, gives as freed exactly what went, and
nothing outside the tree is touched.
*/
@(test)
a_delete_the_disk_refuses_part_way_says_what_went :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/leita_files_faults_%d", temp_root(), os.get_pid())
	defer os.remove_all(root)
	defer faults.disarm()

	// Every file and both folders: each is one unlink.
	calls := len(FAULT_TREE) + 2
	for nth in 1 ..= calls {
		for fault in ([]faults.Fault{.IO, .Denied, .Read_Only}) {
			tree, outside := fault_tree(t, root)
			before: u64
			for f in FAULT_TREE {
				before += on_disk(strings.concatenate({tree, f.name}, context.temp_allocator))
			}

			faults.arm({op = .Remove, fault = fault, nth = nth})
			failed, freed, err := delete_tree(tree)
			hits := faults.hits()
			faults.disarm()

			left: u64
			for f in FAULT_TREE {
				left += on_disk(strings.concatenate({tree, f.name}, context.temp_allocator))
			}
			testing.expectf(t, hits == 1, "%v at unlink %d was never met", fault, nth)
			testing.expectf(t, err == .Partly, "%v at unlink %d: the delete said %v", fault, nth, err)
			testing.expectf(t, failed == 1, "%v at unlink %d: %d entries counted left", fault, nth, failed)
			testing.expectf(t, freed == before - left, "%v at unlink %d: freed %d, went %d", fault, nth, freed, before - left)
			testing.expectf(t, os.exists(tree), "%v at unlink %d: the tree that held it went", fault, nth)
			testing.expectf(t, on_disk(outside) > 0, "%v at unlink %d: a file outside the tree went", fault, nth)
		}
	}
}
