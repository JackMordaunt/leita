#+build linux
package scan

import "core:fmt"
import "core:io"
import "core:os"
import "core:testing"

// A directory is a directory at an absolute path, and a name that is not there is an
// error and not a type: the answers resolve builds a target from.
@(test)
test_stat_target_reads_a_directory_and_refuses_a_missing_name :: proc(t: ^testing.T) {
	base, base_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, base_err == nil, "no temp directory")
	dir := fmt.tprintf("%s/leita_scan_stat_target_%d", base, os.get_pid())
	os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil, "could not make the directory")
	defer os.remove_all(dir)

	kind, full, err := stat_target(dir, context.temp_allocator)
	testing.expect_value(t, err, io.Error.None)
	testing.expect_value(t, kind, os.File_Type.Directory)
	testing.expect_value(t, full, dir)

	file := fmt.tprintf("%s/f", dir)
	testing.expect(t, os.write_entire_file(file, []byte{'x'}) == nil, "could not write the file")
	kind, _, err = stat_target(file, context.temp_allocator)
	testing.expect_value(t, err, io.Error.None)
	testing.expect_value(t, kind, os.File_Type.Regular)

	_, _, err = stat_target(fmt.tprintf("%s/absent", dir), context.temp_allocator)
	testing.expect(t, err != .None, "a name that is not there was found")
}
