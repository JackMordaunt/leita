/*
Package testtmp makes the temporary folders tests work in, with a name no other
test in any process shares. core:testing resets each test's random state to
the one seed it logs at the start (runner.odin, rand.reset(data.t.seed)), so
os.make_directory_temp draws the same first name in every parallel test, and
redraws only on .Exist (temp_file.odin). On Windows a folder another test is
still removing is delete pending, and making it again is access denied, not
.Exist, so the redraw never happens. Tests import this package, never the
product code.
*/
package testtmp

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

@(private)
made: int

// make_dir is os.make_directory_temp with the process id and a count of the
// folders made so far put before the pattern's last "*" (at the end when it has
// none), so two tests never draw the same name and two test processes never do.
make_dir :: proc(
	parent: string,
	pattern: string,
	allocator := context.allocator,
) -> (
	dir: string,
	err: os.Error,
) {
	n := sync.atomic_add(&made, 1)
	tag := fmt.tprintf("%d-%d-", os.get_pid(), n)
	at := strings.last_index_byte(pattern, '*')
	if at < 0 {
		at = len(pattern)
	}
	unique := strings.concatenate({pattern[:at], tag, pattern[at:]}, context.temp_allocator)
	return os.make_directory_temp(parent, unique, allocator)
}
