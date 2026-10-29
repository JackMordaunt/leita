#+build linux, darwin
package leita_settings

import "core:fmt"
import "core:os"
import "core:testing"
import "jm:debug"
import jm_path "jm:path"

// A writable main file in an unwritable directory reproduces the missing
// WAL-sidecar fallback, while a separate debug heap catches fault strings
// accidentally freed using the allocator for temporary statements.
@(test)
read_only_open_keeps_heap_and_temp_error_ownership_separate :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp(
		"",
		"leita-settings-allocator-*",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/settings.db", dir)
	st: Store
	testing.expect(t, open(&st, path) == nil)
	testing.expect(t, set(&st, LANGUAGE, "ja") == nil)
	close(&st)
	testing.expect(t, os.change_mode(dir, {.Read_User, .Execute_User}) == nil)
	defer os.change_mode(dir, {.Read_User, .Write_User, .Execute_User})
	heap: debug.Allocator
	original := context.allocator
	debug.init(&heap, original)
	defer debug.destroy(&heap)
	context.allocator = debug.allocator(&heap)
	defer {context.allocator = original}
	before := debug.snapshot(&heap)
	problem := open(&st, path)
	if testing.expectf(t, problem == nil, "readonly open: %v", problem) {
		testing.expect(t, st.read_only)
		value, found := get(&st, LANGUAGE, context.temp_allocator)
		testing.expect(t, found && value == "ja")
		close(&st)
	}
	testing.expect_value(t, debug.issue_count(&heap), 0)
	testing.expect(t, debug.expect_released(&heap, before))
}
