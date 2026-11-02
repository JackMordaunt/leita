#+build freebsd
package leita_cli

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../changes"
import "../history"
import "../scan"

// FreeBSD deliberately has no change cursor. It keeps ordinary snapshots while
// explaining every complete read, and does not advertise a reusable baseline.
@(test)
freebsd_repeated_cli_scans_keep_snapshots_and_explain_the_full_read :: proc(t: ^testing.T) {
	root, store := fresh(t, "leita_freebsd_full_cli")
	defer os.remove_all(root)
	defer os.remove_all(filepath.dir(store))
	write_payload(t, fmt.tprintf("%s/value.bin", root), 2 << 20)
	cursor, have_cursor := changes.now(root)
	testing.expect(t, !have_cursor, "FreeBSD does not claim a change cursor")
	testing.expect_value(t, cursor.source, changes.Source.None)
	target, _, target_err := scan.resolve(root)
	if !testing.expect_value(t, target_err, scan.Error.None) {return}
	defer scan.target_destroy(&target)
	baseline := history.baseline_path(
		store,
		scan.location(target, context.temp_allocator),
		context.temp_allocator,
	)
	for pass in 1 ..= 2 {
		out, code := capture_stdout(t, {target = root}, store)
		testing.expect_value(t, code, EXIT_OK)
		testing.expect(
			t,
			strings.contains(out, "read whole: the system cannot say what changes in this place"),
			out,
		)
		delete(out)
		testing.expect_value(t, snapshot_count(t, store), i64(pass))
		testing.expect(
			t,
			!os.exists(baseline),
			"a cursorless scan must not save a reusable baseline",
		)
	}
}
