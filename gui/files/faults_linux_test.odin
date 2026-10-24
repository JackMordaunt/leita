#+build linux
package leita_files

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../../faults"

/*
A move to the Trash the disk refuses at any step, the info file made, written, or the
entry renamed: it says it failed, the entry is where it was, and the Trash holds
neither it nor an info file naming it.
*/
@(test)
a_trash_the_disk_refuses_leaves_the_entry_and_no_info :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/leita_files_trash_faults_%d", temp_root(), os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	defer faults.disarm()

	source := strings.concatenate({root, "/place/note"}, context.temp_allocator)
	trash_dir := strings.concatenate({root, "/Trash"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(strings.concatenate({root, "/place"}, context.temp_allocator)) == nil)
	testing.expect(t, os.write_entire_file(source, "kept") == nil)

	for op in ([]faults.Op{.Open, .Write, .Rename}) {
		for fault in ([]faults.Fault{.No_Space, .IO, .Read_Only, .Denied}) {
			faults.arm({op = op, fault = fault, nth = 1})
			err := trash_into(source, trash_dir)
			hits := faults.hits()
			faults.disarm()

			testing.expectf(t, hits == 1, "%v on %v was never met", fault, op)
			testing.expectf(t, err != .None, "%v on %v: the trash said it held", fault, op)
			got, _ := os.read_entire_file(source, context.temp_allocator)
			testing.expectf(t, string(got) == "kept", "%v on %v: the entry is not where it was", fault, op)
			for sub in ([]string{"/files", "/info"}) {
				entries, _ := os.read_all_directory_by_path(
					strings.concatenate({trash_dir, sub}, context.temp_allocator),
					context.temp_allocator,
				)
				testing.expectf(t, len(entries) == 0, "%v on %v left %d in %s", fault, op, len(entries), sub)
			}
		}
	}

	testing.expect_value(t, trash_into(source, trash_dir), Error.None)
	testing.expect(t, !os.exists(source), "the entry stayed")
	testing.expect(t, os.exists(strings.concatenate({trash_dir, "/files/note"}, context.temp_allocator)))
}
