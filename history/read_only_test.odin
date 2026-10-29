package leita_history
import "core:fmt"
import "core:os"
import "core:testing"
import jm_path "jm:path"
import "jm:sqlite3"

@(test)
read_only_history_keeps_prior_snapshots_and_returns_no_new_id :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp("", "leita-history-readonly-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/history.db", dir)
	st: Store
	testing.expect(t, open(&st, path) == nil)
	id, saved := save(&st, "/kept", 10, 42, 1, {{"", 42}})
	testing.expect(t, saved == nil && id != 0)
	close(&st)
	testing.expect(t, open_read_only(&st, path, sqlite3.Fault{code = .Full}) == nil)
	defer close(&st)
	testing.expect(t, st.read_only && st.read_only_reason != "")
	next, failure := save(&st, "/kept", 20, 99, 1, {{"", 99}})
	testing.expect(t, next == 0 && failure != nil)
	if failure !=
	   nil {testing.expect_value(t, failure.?.code, sqlite3.Code.Read_Only); delete(failure.?.text, st.db.allocator)}
	audit_error := record(&st, {{taken = 20, kind = .Delete, path = "/kept"}})
	testing.expect(t, audit_error != nil)
	if audit_error != nil {delete(audit_error.?.text, st.db.allocator)}
	snaps, read_err := list(&st, "/kept")
	testing.expect(
		t,
		read_err == nil && len(snaps) == 1 && snaps[0].id == id && snaps[0].bytes == 42,
	)
	entries, load_err := load(&st, id, context.temp_allocator)
	testing.expect(t, load_err == nil && entries[""] == 42)
}

@(test)
an_old_read_only_history_store_is_not_stamped :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp(
		"",
		"leita-history-old-readonly-*",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	for name in ([]string{"h1", "h2"}) {
		path, _ := copy_fixture(t, dir, fmt.tprintf("history/%s.db", name), fmt.tprintf("%s.db", name))
		st: Store
		testing.expect(t, open_read_only(&st, path, sqlite3.Fault{code = .Full}) == nil)
		testing.expect_value(t, version_of(t, &st), i64(0))
		snaps, read_err := list(&st, "/compat/place")
		testing.expect(t, read_err == nil)
		testing.expect(t, len(snaps) > 0)
		close(&st)
	}
}

@(test)
read_only_history_refuses_newer_schema_without_rewriting :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp(
		"",
		"leita-history-future-readonly-*",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path, before := copy_fixture(t, dir, "history/h-future.db", "history.db")
	st: Store
	problem := open_read_only(&st, path, sqlite3.Fault{code = .Full})
	testing.expect(t, problem != nil && st.db.handle == nil)
	if problem != nil {delete(problem.?.text)}
	after, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, len(after), len(before))
	for byte, i in before {if byte != after[i] {testing.expect(t, false, "newer history store changed"); break}}
}
