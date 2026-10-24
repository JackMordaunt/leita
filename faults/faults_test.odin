package leita_faults

import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
scratch :: proc(t: ^testing.T, name: string) -> (dir, path: string) {
	parent := os.temp_directory(context.temp_allocator) or_else "."
	made, err := os.make_directory_temp(parent, "leita-faults-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	path, _ = filepath.join({made, name}, context.temp_allocator)
	return made, path
}

@(test)
each_fault_is_the_error_its_rule_names :: proc(t: ^testing.T) {
	dir, path := scratch(t, "a")
	defer os.remove_all(dir)
	defer disarm()

	for fault in ([]Fault{.No_Space, .IO, .Read_Only, .Denied}) {
		arm({op = .Open, fault = fault})
		testing.expect_value(t, write_entire_file(path, {1, 2, 3}), error_of(fault))
		testing.expect(t, !os.exists(path), "a failed open made the file")
		testing.expect_value(t, hits(), 1)
	}
	disarm()
	testing.expect_value(t, write_entire_file(path, {1, 2, 3}), nil)
	testing.expect(t, os.exists(path))
}

@(test)
a_short_write_leaves_half_and_the_next_part_fails :: proc(t: ^testing.T) {
	dir, path := scratch(t, "short")
	defer os.remove_all(dir)
	defer disarm()

	arm({op = .Write, fault = .Short, nth = 1})
	testing.expect_value(t, write_entire_file(path, {1, 2, 3, 4}), error_of(.No_Space))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, len(data), 2)
}

@(test)
a_rule_counts_only_its_own_op_and_path :: proc(t: ^testing.T) {
	dir, path := scratch(t, "target")
	defer os.remove_all(dir)

	other, _ := filepath.join({dir, "other"}, context.temp_allocator)
	defer disarm()

	arm({op = .Rename, fault = .IO, nth = 2, path = "target"})
	testing.expect_value(t, write_entire_file(path, {1}), nil)
	testing.expect_value(t, write_entire_file(other, {1}), nil)
	moved, _ := filepath.join({dir, "moved"}, context.temp_allocator)
	testing.expect_value(t, rename(other, moved), nil) // not the path the rule names
	testing.expect_value(t, rename(path, moved), nil) // the first of its calls
	testing.expect_value(t, rename(moved, path), nil) // "moved" holds no "target"
	testing.expect_value(t, rename(path, moved), error_of(.IO))
	testing.expect_value(t, crossings(), 8) // two opens, two writes, four renames
}

@(test)
disarm_leaves_calls_alone_and_counts_them :: proc(t: ^testing.T) {
	dir, path := scratch(t, "thread")
	defer os.remove_all(dir)

	arm({op = .Open, fault = .Denied})
	disarm()
	testing.expect_value(t, write_entire_file(path, {1}), nil)
	testing.expect_value(t, crossings(), 2)
}
