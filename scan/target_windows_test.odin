#+build windows
package scan

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
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
	testing.expect(t, strings.contains(where_, `\`), "the place uses backslashes")
	testing.expect(t, where_ != slashed, "the slashes did not remain")
	testing.expect_value(t, where_, long_of(root))
	testing.expect_value(t, target.input, slashed)
	target_destroy(&target)
}

/*
An 8.3 short path is stored as the long name GetLongPathNameW returns.
*/
@(test)
a_short_path_resolves_to_its_long_name :: proc(t: ^testing.T) {
	da: debug.Allocator
	debug.init(&da, context.allocator)
	defer debug.destroy(&da)
	defer testing.expect_value(t, debug.issue_count(&da), 0)

	dir, err := os.temp_directory(context.temp_allocator)
	testing.expect(t, err == nil, "no temp directory")
	dir = strings.trim_right(dir, `\/`)
	root := fmt.tprintf(`%s\leita_runner_workspace_long_name_%d`, dir, os.get_pid())
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	defer os.remove_all(root)

	short := short_of(root)
	long := long_of(root)
	has_short := short != long && strings.contains(short, "~")
	testing.expect(t, has_short, "the temp path has an 8.3 alias")
	if !has_short {
		return
	}
	target, _, rerr := resolve(short, debug.allocator(&da))
	testing.expect_value(t, rerr, Error.None)
	where_ := location(target, context.temp_allocator)
	testing.expect_value(t, where_, long)
	testing.expect_value(t, target.input, short)
	testing.expect(t, !strings.contains(where_, "~"), "the place is not an 8.3 alias")
	target_destroy(&target)
}

@(private = "file")
long_of :: proc(path: string) -> string {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	buf: [win.MAX_PATH]u16
	n := win.GetLongPathNameW(wpath, win.wstring(&buf[0]), len(buf))
	if n == 0 || int(n) >= len(buf) {
		return path
	}
	s, err := win.wstring_to_utf8(win.wstring(&buf[0]), int(n), context.temp_allocator)
	return s if err == nil else path
}

@(private = "file")
short_of :: proc(path: string) -> string {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	buf: [win.MAX_PATH]u16
	n := win.GetShortPathNameW(wpath, win.wstring(&buf[0]), len(buf))
	if n == 0 || int(n) >= len(buf) {
		return path
	}
	s, err := win.wstring_to_utf8(win.wstring(&buf[0]), int(n), context.temp_allocator)
	return s if err == nil else path
}
