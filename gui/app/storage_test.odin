package leita_app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import jm_path "jm:path"

import "jm:sqlite3"

import "../../history"
import "../../scan"
import "../../survey"
import "../../walk"
import "../../schedule"
import "../../settings"
import "../command"
import "../msg"
import "../query"

@(private = "file")
Storage_Scheduler :: struct { calls: int }

@(private = "file")
storage_scheduler_run :: proc(_: []string, data: rawptr) -> schedule.Outcome {
	r := cast(^Storage_Scheduler)data
	r.calls += 1
	return {ok = true}
}

// Recovering readable saved settings must not reinstall a remembered monitor
// or change its schedule when the chosen state cannot be written back.
@(test)
a_read_only_configuration_restores_preferences_without_changing_the_scheduler :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp("", "leita-storage-ui-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	st: settings.Store
	testing.expect(t, settings.open(&st, ":memory:") == nil)
	defer settings.close(&st)
	testing.expect(t, settings.set(&st, settings.LANGUAGE, "es") == nil)
	testing.expect(t, settings.set(&st, settings.THEME, "dark") == nil)
	testing.expect(t, settings.set_monitoring(&st, true) == nil)
	testing.expect(t, sqlite3.exec(st.db, "PRAGMA query_only=ON") == nil)
	st.read_only, st.read_only_reason = true, "The data volume is read-only."
	words := new(msg.Strings)
	defer free(words)
	msg.init(words, .English)
	d := Desk{settings = &st, words = words}
	defer delete(d.settings_problem)
	rec: Storage_Scheduler
	host := schedule.Host{run = storage_scheduler_run, user = &rec, system = .Systemd, units = dir}
	problem, _ := schedule.install(host, {"/old/leita", "monitor", "run"})
	testing.expect_value(t, problem, "")
	rec.calls = 0
	unit := fmt.tprintf("%s/leita-monitor.service", dir)
	before, _ := os.read_entire_file(unit, context.temp_allocator)
	monitor_open(&d, "", &host, {"/new/leita", "monitor", "run"})
	defer monitor_close(&d)
	set_monitoring(&d, command.Monitoring{on = true})
	set_monitoring(&d, command.Monitoring{on = false})
	testing.expect_value(t, rec.calls, 0)
	after, _ := os.read_entire_file(unit, context.temp_allocator)
	testing.expect_value(t, string(after), string(before))
	testing.expect(t, settings.monitoring(&st), "the saved enabled flag is unchanged")
	remember_theme(&d, command.Theme{choice = u8(query.Theme_Choice.Light)})
	kept_theme, _ := settings.get(&st, settings.THEME, context.temp_allocator)
	testing.expect_value(t, kept_theme, "dark")
	r := settings_answer(&d)
	testing.expect_value(t, r.language, "es")
	testing.expect_value(t, r.theme, query.Theme_Choice.Dark)
	testing.expect(t, strings.contains(progress(&d).storage_problem, "read-only"))
}

// A finished scan still compares with readable history when its new result
// cannot be saved. It must not invent a new snapshot or change the old one.
@(test)
a_read_only_history_still_compares_the_current_scan :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp("", "leita-history-ui-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/file", dir), "current") == nil)
	s: Scan
	testing.expect_value(t, scan.tree_init(&s.tree, 1), scan.Error.None)
	defer scan.tree_destroy(&s.tree)
	testing.expect_value(t, walk.read(dir, &s.tree, {workers = 1}), walk.Error.None)
	s.engine, s.grown, s.roll.linked = .Walk, true, true
	survey.rollup_advance(&s.roll, &s.tree)
	defer survey.rollup_destroy(&s.roll)
	top, found := root(&s)
	testing.expect(t, found)
	st: history.Store
	testing.expect(t, history.open(&st, ":memory:") == nil)
	defer history.close(&st)
	place := history.place_of(&s.tree, top, s.engine)
	id, serr := history.save(&st, place, 1000, 123, 1, {{"", 123}})
	testing.expect(t, serr == nil && id > 0)
	testing.expect(t, sqlite3.exec(st.db, "PRAGMA query_only=ON") == nil)
	st.read_only, st.read_only_reason = true, "Saved history is read-only."
	words := new(msg.Strings)
	defer free(words)
	msg.init(words, .English)
	d := Desk{history = &st, scan = &s, words = words, was = make(map[u32]u64)}
	defer delete(d.was)
	keep(&d)
	testing.expect_value(t, d.snapshot, i64(0))
	testing.expect_value(t, d.compared.id, id)
	testing.expect_value(t, d.was[top], u64(123))
	snaps, lerr := history.list(&st, place)
	testing.expect(t, lerr == nil && len(snaps) == 1 && snaps[0].id == id)
	testing.expect(t, strings.contains(progress(&d).storage_problem, "read-only"))
}
