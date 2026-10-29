package leita_settings

import "core:fmt"
import "core:os"
import "core:testing"
import jm_path "jm:path"
import "jm:sqlite3"

@(test)
read_only_settings_keep_preferences_and_reject_monitoring_changes :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp(
		"",
		"leita-settings-readonly-*",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/settings.db", dir)
	st: Store
	testing.expect(t, open(&st, path) == nil)
	testing.expect(t, set(&st, LANGUAGE, "ja") == nil)
	testing.expect(t, watch(&st, {place = "/kept", every = .Hourly, added = 10}) == nil)
	close(&st)
	testing.expect(t, open_read_only(&st, path, sqlite3.Fault{code = .Full}) == nil)
	defer close(&st)
	testing.expect(t, st.read_only && st.read_only_reason != "")
	value, found := get(&st, LANGUAGE, context.temp_allocator)
	testing.expect(t, found && value == "ja")
	for failure in ([]sqlite3.Error{set(&st, LANGUAGE, "en"), set_monitoring(&st, true), watch(&st, {place = "/new"}), raise(&st, {}), note_delivery(&st, 1, 20, "failed"), forget_delivery(&st, 1), retry(&st, 1, 3, 10, "retry")}) {
		testing.expect(t, failure != nil)
		if failure !=
		   nil {testing.expect_value(t, failure.?.code, sqlite3.Code.Read_Only); delete(failure.?.text, st.db.allocator)}
	}
	won, replaced := replace_if(&st, LANGUAGE, "ja", "en")
	testing.expect(t, !won && replaced != nil)
	removed, removal := unwatch(&st, "/kept")
	testing.expect(t, !removed && removal != nil)
	id, recorded := record(&st, {place = "/kept"})
	testing.expect(t, id == 0 && recorded != nil)
	hook, added := hook_add(&st, "https://example.invalid", "secret", false, 10)
	testing.expect(t, hook == 0 && added != nil)
	gone, removal_hook := hook_remove(&st, "https://example.invalid")
	testing.expect(t, !gone && removal_hook != nil)
	queued, enqueue_err := enqueue(&st, 1, "event", "body", 10)
	testing.expect(t, queued == 0 && enqueue_err != nil)
	for failure in ([]sqlite3.Error{replaced, removal, recorded, added, removal_hook, enqueue_err}) {
		if failure != nil {delete(failure.?.text, st.db.allocator)}
	}
	watches, read_err := watches(&st, context.temp_allocator)
	testing.expect(t, read_err == nil && len(watches) == 1 && watches[0].place == "/kept")
}

@(test)
an_old_read_only_settings_store_uses_old_monitor_defaults_without_migration :: proc(
	t: ^testing.T,
) {
	dir, err := jm_path.make_directory_temp(
		"",
		"leita-settings-old-readonly-*",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path, _ := copy_fixture(t, dir, "settings/s7.db", FILE)
	st: Store
	testing.expect(t, open_read_only(&st, path, sqlite3.Fault{code = .Full}) == nil)
	defer close(&st)
	testing.expect_value(t, version_of(t, &st), i64(0))
	ws, werr := watches(&st, context.temp_allocator)
	testing.expect(t, werr == nil)
	testing.expect(t, len(ws) > 0)
	if len(ws) > 0 {
		testing.expect_value(t, ws[0].limits, Limits{})
		rs, rerr := runs(&st, ws[0].place, allocator = context.temp_allocator)
		testing.expect(t, rerr == nil)
		for r in rs {testing.expect(t, !r.updated && r.why == "" && r.firing == "")}
	}
}

@(test)
read_only_settings_refuse_newer_schemas_without_rewriting :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp(
		"",
		"leita-settings-future-readonly-*",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path, before := copy_fixture(t, dir, "settings/s-future.db", FILE)
	st: Store
	problem := open_read_only(&st, path, sqlite3.Fault{code = .Full})
	testing.expect(t, problem != nil && st.db.handle == nil)
	if problem != nil {delete(problem.?.text)}
	after, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, len(after), len(before))
	for byte, i in before {if byte != after[i] {testing.expect(t, false, "newer settings store changed"); break}}
}

@(test)
every_historical_settings_fixture_remains_readable_without_migration :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp(
		"",
		"leita-settings-legacy-readonly-*",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	for i in 1 ..= 7 {
		path, _ := copy_fixture(
			t,
			dir,
			fmt.tprintf("settings/s%d.db", i),
			fmt.tprintf("s%d.db", i),
		)
		st: Store
		problem := open_read_only(&st, path, sqlite3.Fault{code = .Full})
		if !testing.expectf(t, problem == nil, "s%d readonly: %v", i, problem) {continue}
		testing.expect_value(t, version_of(t, &st), i64(0))
		_, watch_err := watches(&st, context.temp_allocator)
		testing.expectf(t, watch_err == nil, "s%d watches: %v", i, watch_err)
		_, hook_err := hooks(&st, context.temp_allocator)
		testing.expectf(t, hook_err == nil, "s%d hooks: %v", i, hook_err)
		close(&st)
	}
}
