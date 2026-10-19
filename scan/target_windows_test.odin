#+build windows
package scan

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "jm:debug"

/*
A path given with slashes, as typed or as a test builds one onto the temp folder,
is the same directory with backslashes: the target names it with `\` alone, which
the tree goes on to join under, and frees what it took whole.
*/
@(test)
a_slashed_path_resolves_with_backslashes :: proc(t: ^testing.T) {
	da: debug.Allocator
	debug.init(&da, context.allocator)
	defer debug.destroy(&da)
	defer testing.expect_value(t, debug.issue_count(&da), 0)

	dir, err := os.temp_directory(context.temp_allocator)
	testing.expect(t, err == nil, "no temp directory")
	dir = strings.trim_right(dir, `\/`)
	root := fmt.tprintf(`%s\leita_resolve_slashes_%d`, dir, os.get_pid())
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	defer os.remove_all(root)

	slashed, _ := strings.replace_all(root, `\`, "/", context.temp_allocator)
	target, _, rerr := resolve(slashed, debug.allocator(&da))
	testing.expect_value(t, rerr, Error.None)
	where_ := location(target, context.temp_allocator)
	testing.expect_value(t, where_, root)
	testing.expect_value(t, target.input, slashed)
	target_destroy(&target)
}
