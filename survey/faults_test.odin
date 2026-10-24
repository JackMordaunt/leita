package survey

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../faults"
import "../scan"

// The temporary files a save of the baseline at file has left beside it.
@(private = "file")
stages :: proc(file: string) -> int {
	entries, _ := os.read_all_directory_by_path(filepath.dir(file), context.temp_allocator)
	prefix := fmt.tprintf("%s.", filepath.base(file))
	n := 0
	for e in entries {
		if strings.has_prefix(e.name, prefix) && strings.has_suffix(e.name, ".new") {
			n += 1
		}
	}
	return n
}

// Each way the disk can refuse a step of a baseline save: the save says it did not
// keep the tree, the baseline before still reads back whole, and no temporary file
// is left.
@(test)
test_a_disk_fault_in_a_baseline_save_keeps_the_one_before :: proc(t: ^testing.T) {
	dir, _ := os.temp_directory(context.temp_allocator)
	root := filepath.join(
		{dir, fmt.tprintf("leita_survey_faults_%d", os.get_pid())},
		context.temp_allocator,
	) or_else ""
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil)
	defer os.remove_all(root)

	put(t, filepath.join({root, "a.txt"}, context.temp_allocator) or_else "", 100)
	file := fmt.tprintf("%s.tree", root)
	defer os.remove(file)

	first := read_tree(t, root)
	defer scan.tree_destroy(&first)

	testing.expect(t, baseline_save(file, root, &first, {}), "the first baseline was not kept")
	put(t, filepath.join({root, "b.txt"}, context.temp_allocator) or_else "", 5000)
	second := read_tree(t, root)
	defer scan.tree_destroy(&second)
	defer faults.disarm()

	for op in ([]faults.Op{.Open, .Write, .Rename}) {
		for fault in faults.Fault {
			if fault == .None || fault == .Kill || (fault == .Short && op != .Write) {
				continue
			}
			faults.arm({op = op, fault = fault, nth = 1})
			kept := baseline_save(file, root, &second, {})
			hits := faults.hits()
			faults.disarm()
			testing.expectf(t, !kept, "%v on %v: the save said it held", fault, op)
			testing.expectf(t, hits == 1, "%v on %v was never met", fault, op)
			back: scan.Tree
			_, why, ok := baseline_load(file, root, &back)
			testing.expectf(t, ok, "%v on %v: the baseline before is lost: %s", fault, op, why)
			if ok {
				expect_same(t, &back, &first)
			}
			scan.tree_destroy(&back)
			testing.expectf(t, stages(file) == 0, "%v on %v left a temporary file", fault, op)
		}
	}
	testing.expect(t, baseline_save(file, root, &second, {}), "the second baseline was not kept")
	back: scan.Tree
	defer scan.tree_destroy(&back)

	_, why, ok := baseline_load(file, root, &back)
	testing.expectf(t, ok, "not read back: %s", why)
	expect_same(t, &back, &second)
}
