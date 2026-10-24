#+build !windows
package report

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "../home"
import "../reclaim"

// Run as root, the report lists what the person sudo ran leita for could delete,
// as the window does: not another user's candidate, and not one outside the home.
// Run as anyone else, it lists what find found.
@(test)
the_report_run_as_root_lists_only_the_invokers_own :: proc(t: ^testing.T) {
	base := fmt.tprintf("/tmp/leita-report-root-%d", os.get_pid())
	os.remove_all(base)
	defer os.remove_all(base)

	home_dir := strings.concatenate({base, "/home/ann"}, context.temp_allocator)
	mine := strings.concatenate({home_dir, "/proj/node_modules"}, context.temp_allocator)
	bobs := strings.concatenate({base, "/home/bob/proj/node_modules"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(mine) == nil)
	testing.expect(t, os.make_directory_all(bobs) == nil)
	found := []reclaim.Candidate {
		{node = 1, path = mine, bytes = 10, category = .Dependencies},
		{node = 2, path = bobs, bytes = 20, category = .Dependencies},
		{
			node = 3,
			path = strings.concatenate({base, "/gone/node_modules"}, context.temp_allocator),
			bytes = 30,
			category = .Dependencies,
		},
	}

	// The files are the test user's, so ann is whoever runs the test.
	ann := home.User{home_dir, fmt.tprintf("%d", u32(posix.getuid()))}
	got := offered(found, ann, 0)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].path, mine)
	}

	// A user id that owns none of them is offered nothing.
	nobody := home.User{home_dir, fmt.tprintf("%d", u32(posix.getuid()) + 1)}
	testing.expect_value(t, len(offered(found, nobody, 0)), 0)

	// Not root: the system's permission checks decide, and the report lists all.
	testing.expect_value(t, len(offered(found, ann, u32(posix.getuid()) + 1)), 3)
}
