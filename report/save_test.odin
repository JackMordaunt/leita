package report

import "core:fmt"
import jm_path "jm:path"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../faults"

// Each way the disk can refuse a step of a save: the report says it was not
// written, the file at the path before is what it holds after, byte for byte, and
// no partial file is left beside it.
@(test)
a_disk_fault_in_a_save_keeps_the_report_before :: proc(t: ^testing.T) {
	dir, derr := jm_path.make_directory_temp("", "leita-report-faults-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)

	path, _ := filepath.join({dir, "report.json"}, context.temp_allocator)
	before := "an earlier report"
	testing.expect(t, os.write_entire_file(path, before) == nil)
	r := Report{version = "test", target = "/home/someone"}
	defer faults.disarm()

	for op in ([]faults.Op{.Open, .Write, .Sync, .Rename}) {
		for fault in faults.Fault {
			if fault == .None || fault == .Kill || (fault == .Short && op != .Write) {
				continue
			}
			faults.arm({op = op, fault = fault, nth = 1})
			err, opened := save(path, &r, .Json)
			hits := faults.hits()
			faults.disarm()
			testing.expectf(t, err == .Write_Failed, "%v on %v: the save said %v", fault, op, err)
			testing.expectf(t, (opened != nil) == (op == .Open), "%v on %v: opened %v", fault, op, opened)
			testing.expectf(t, hits == 1, "%v on %v was never met", fault, op)
			after, _ := os.read_entire_file(path, context.temp_allocator)
			testing.expectf(t, string(after) == before, "%v on %v changed the report: %q", fault, op, string(after)[:min(len(after), 40)])
			testing.expectf(t, !os.exists(fmt.tprintf("%s.partial", path)), "%v on %v left the partial file", fault, op)
		}
	}

	err, opened := save(path, &r, .Json)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, opened, nil)
	after, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(after), "{"), "the report was not replaced")
	testing.expect(t, !os.exists(fmt.tprintf("%s.partial", path)), "a save that held left its partial file")
}
