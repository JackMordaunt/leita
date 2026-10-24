#+build darwin
package leita_files

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// trash goes through the Finder's Trash for real, so the entry is taken back out of
// it at once: the test leaves the user's Trash as it found it.
@(test)
trash_moves_an_entry_into_the_finders_trash :: proc(t: ^testing.T) {
	base := temp_root()
	path := strings.concatenate(
		{base, fmt.tprintf("/leita_files_trash_%d.txt", os.get_pid())},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(path, "x") == nil)
	defer os.remove(path)

	to, err := trash_to(path, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	defer os.remove(to)
	testing.expect(t, !os.exists(path), "gone from where it was")
	testing.expect(t, strings.contains(to, "/.Trash"), "in a Trash")
	testing.expect(t, os.exists(to), "and there")

	_, missing := trash_to(path, context.temp_allocator)
	testing.expect_value(t, missing, Error.Missing)
}

@(test)
rename_noreplace_refuses_a_name_already_taken :: proc(t: ^testing.T) {
	base := temp_root()
	from := strings.concatenate(
		{base, fmt.tprintf("/leita_files_from_%d.txt", os.get_pid())},
		context.temp_allocator,
	)
	to := strings.concatenate(
		{base, fmt.tprintf("/leita_files_to_%d.txt", os.get_pid())},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(from, "from") == nil)
	testing.expect(t, os.write_entire_file(to, "to") == nil)
	defer os.remove(from)
	defer os.remove(to)

	testing.expect_value(t, rename_noreplace(from, to), Error.Exists)
	kept, _ := os.read_entire_file(to, context.temp_allocator)
	testing.expect_value(t, string(kept), "to")

	os.remove(to)
	testing.expect_value(t, rename_noreplace(from, to), Error.None)
	testing.expect(t, !os.exists(from), "moved")
}
