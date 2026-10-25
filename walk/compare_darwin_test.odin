#+build darwin
package walk

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "../scan"

/*
leita's allocated total against BSD du -sk, on the trees compare_unix_test.odin
builds, one per case.

BSD du adds to a tree what leita does not charge: each directory's own st_blocks
and each symlink's, the same two terms
GNU du adds on Linux. The test takes both from lstat and holds du -sk to
leita + those, rounded up to the kibibyte du reports. Hard links are counted once by
both. A hole is charged by neither: st_blocks is what du reports and what leita
charges.

The apparent
total is printed and not compared here; Linux holds it to du -sb.
*/
@(test)
test_totals_agree_with_du_after_the_documented_differences_on_macos :: proc(t: ^testing.T) {
	temp, _ := os.temp_directory(context.temp_allocator)
	top := fmt.tprintf("%s/leita_walk_du_%d", strings.trim_right(temp, "/"), os.get_pid())
	os.remove_all(top)
	defer os.remove_all(top)

	testing.expect(t, os.make_directory(top) == nil)

	fmt.eprintfln("%-22s %12s | %12s %12s | %s", "case", "leita app.", "leita alloc", "du -sk", "directories + symlinks")
	for c in common_cases {
		root := fmt.tprintf("%s/%s", top, strings.replace_all(c.name, " ", "_", context.temp_allocator))
		testing.expect(t, os.make_directory(root) == nil)
		c.build(t, root)

		tree: scan.Tree
		testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
		defer scan.tree_destroy(&tree)

		testing.expect_value(t, read(root, &tree, Config{}), Error.None)
		sum := totals_of(&tree)

		held: u64 // st_blocks * 512 of the directories and symlinks
		for i in 0 ..< tree.count {
			n := scan.node(&tree, i)
			flags := scan.node_flags(n)
			if .Used not_in flags || flags & {.Directory, .Reparse} == {} {continue}
			path := strings.clone_to_cstring(scan.path(&tree, i, context.temp_allocator), context.temp_allocator)
			st: posix.stat_t
			testing.expect(t, posix.lstat(path, &st) == .OK)
			held += u64(st.st_blocks) * 512
		}
		kib, text, ok := run_tool({"du", "-sk", root})
		testing.expectf(t, ok, "%s: du -sk failed: %s", c.name, text)
		fmt.eprintfln("%-22s %12d | %12d %12d | %d", c.name, sum.apparent, sum.allocated, kib, held)
		testing.expect_value(t, tree.bytes_done, sum.allocated)
		testing.expect_value(t, tree.unread, 0)
		testing.expectf(
			t,
			kib == (sum.allocated + held + 1023) / 1024,
			"%s: du -sk says %d KiB; leita %d bytes + directories and symlinks %d",
			c.name,
			kib,
			sum.allocated,
			held,
		)
	}
}
