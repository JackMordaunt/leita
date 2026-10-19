#+build windows
package survey

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:testing"

/*
The race between two savers made certain: a handle still open on the baseline, as
the first saver's rename leaves one for a moment, does not stop the next saver
replacing it. What os.rename, through MoveFileExW, makes of the same is logged.
*/
@(test)
test_a_baseline_held_open_is_replaced :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf(`%s\leita_survey_replace_%d`, strings.trim_right(dir, `\/`), os.get_pid())
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the folder")
	defer os.remove_all(root)
	kept := fmt.tprintf(`%s\place.tree`, root)
	fresh := fmt.tprintf(`%s\place.tree.new`, root)
	moved := fmt.tprintf(`%s\place.tree.moved`, root)
	put(t, kept, 10)
	put(t, fresh, 20)
	put(t, moved, 15)

	held := win.CreateFileW(
		win.utf8_to_wstring(kept, context.temp_allocator),
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		0,
		nil,
	)
	testing.expect(t, held != win.INVALID_HANDLE_VALUE, "could not hold the baseline open")
	defer win.CloseHandle(held)

	log.infof("os.rename over a baseline held open: %v", os.rename(moved, kept))
	testing.expect(t, replace(fresh, kept), "a baseline held open was not replaced")
	info, err := os.stat(kept, context.temp_allocator)
	testing.expect(t, err == nil, "no baseline left")
	testing.expect_value(t, info.size, 20)
	testing.expect(t, !os.exists(fresh), "the new baseline was left beside it")
}
