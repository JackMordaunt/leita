#+build darwin
package leita_files

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
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

/*
The move by descriptor, for a volume /.vol does not reach: a name the Trash already
holds is kept, and the second entry takes "name 2.ext".
*/
@(test)
rename_to_trash_keeps_a_name_already_in_the_trash :: proc(t: ^testing.T) {
	base := temp_root()
	name := fmt.tprintf("leita_files_twice_%d.txt", os.get_pid())
	path := strings.concatenate({base, "/", name}, context.temp_allocator)
	parent, perr := open_directory(base)
	testing.expect_value(t, perr, Error.None)
	defer posix.close(parent)

	landed: [2]string
	for i in 0 ..< 2 {
		testing.expect(t, os.write_entire_file(path, fmt.tprintf("%d", i)) == nil)
		st: posix.stat_t
		testing.expect(t, posix.fstat(parent, &st) == .OK)
		to, err := rename_to_trash(parent, name, u64(st.st_dev), context.temp_allocator)
		testing.expect_value(t, err, Error.None)
		landed[i] = to
	}
	defer for to in landed {
		os.remove(to)
	}
	defer os.remove(path)

	first_name := strings.concatenate({"/", name}, context.temp_allocator)
	testing.expectf(t, strings.has_suffix(landed[0], first_name), "the first is %q", landed[0])
	second := fmt.tprintf("/leita_files_twice_%d 2.txt", os.get_pid())
	testing.expectf(t, strings.has_suffix(landed[1], second), "the second is %q", landed[1])
	first, _ := os.read_entire_file(landed[0], context.temp_allocator)
	testing.expect_value(t, string(first), "0")
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
