package leita_app

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"

import "jm:sqlite3"
import "jm:stream"

import "../../settings"
import "../command"
import "../query"

@(private)
build_moment :: proc(
	enabled: bool,
	startup_done: bool,
	last_wall, now_wall, last_mono, now_mono, opened: i64,
	has_mono: bool,
) -> Moment {
	return {
		enabled = enabled,
		startup_done = startup_done,
		last_wall = last_wall,
		now_wall = now_wall,
		has_last_mono = has_mono,
		last_mono = last_mono,
		now_mono = now_mono,
		opened_mono = opened,
	}
}

// Off stays off, including across a clock jump. On checks once at startup,
// and a second window inside the coalesce does not.
@(test)
the_schedule_bounds_sleep_and_clock_changes :: proc(t: ^testing.T) {
	T :: i64(1_700_000_000)
	M :: i64(1_000_000_000)
	off := build_moment(false, false, 0, T + 3 * DAY_SEC, 0, M, M, false)
	testing.expect_value(t, due(off), Due_Check.None)

	testing.expect_value(
		t,
		due(build_moment(true, false, 0, T, 0, M, M, false)),
		Due_Check.Startup,
	)
	// Another window recorded a check 30s ago.
	testing.expect_value(
		t,
		due(build_moment(true, false, T, T + 30, 0, M, M, false)),
		Due_Check.Peer,
	)
	// A clock a minute ahead of ours is the same startup, not a new one.
	testing.expect_value(
		t,
		due(build_moment(true, false, T + 60, T, 0, M, M, false)),
		Due_Check.Peer,
	)
	// Opening Leita again after the coalesce is a new startup check.
	testing.expect_value(
		t,
		due(build_moment(true, false, T, T + 5 * 60, 0, M, M, false)),
		Due_Check.Startup,
	)

	// A day of the window staying open.
	day := build_moment(true, true, T, T + DAY_SEC, M, M + DAY_NS, M, true)
	testing.expect_value(t, due(day), Due_Check.Daily)
	// Less than a day is not due.
	testing.expect_value(
		t,
		due(build_moment(true, true, T, T + DAY_SEC - 1, M, M + DAY_NS - 1, M, true)),
		Due_Check.None,
	)

	// Wall time is three days later and the monotonic count is the same.
	// due reports one daily check. Once last_wall is that wall time, it
	// reports none.
	slept := build_moment(true, true, T, T + 3 * DAY_SEC, M, M, M, true)
	testing.expect_value(t, due(slept), Due_Check.Daily)
	slept.last_wall = T + 3 * DAY_SEC
	slept.now_wall = T + 3 * DAY_SEC
	testing.expect_value(t, due(slept), Due_Check.None)

	// A forward jump of three days is one check, not three.
	jumped := build_moment(true, true, T, T + 3 * DAY_SEC, M, M + i64(1_000_000_000), M, true)
	testing.expect_value(t, due(jumped), Due_Check.Daily)
	jumped.last_wall = T + 3 * DAY_SEC
	jumped.last_mono = M + i64(1_000_000_000)
	jumped.now_wall = T + 3 * DAY_SEC
	jumped.now_mono = M + i64(1_000_000_000)
	testing.expect_value(t, due(jumped), Due_Check.None)

	// A clock set backward does not check until a monotonic day has passed.
	back := build_moment(true, true, T, T - 10 * 3600, M, M + i64(3_600_000_000_000), M, true)
	testing.expect_value(t, due(back), Due_Check.None)
	back.now_mono = M + DAY_NS
	testing.expect_value(t, due(back), Due_Check.Daily)
}

// The eligibility decision the notice words. A build that is not retained
// Pro is not refused. A retained one takes an instant at or before
// paid-through, and refuses a later or unstamped release.
@(test)
a_retained_release_after_paid_through_is_not_offered :: proc(t: ^testing.T) {
	paid :: "2026-10-19T00:00:00Z"
	testing.expect_value(
		t,
		coverage_of(false, paid, "2027-01-01T00:00:00Z", true, false),
		query.Update_Coverage.None,
	)
	testing.expect_value(
		t,
		coverage_of(true, paid, paid, true, false),
		query.Update_Coverage.Covered,
	)
	testing.expect_value(
		t,
		coverage_of(true, paid, "2026-10-18T00:00:00Z", true, false),
		query.Update_Coverage.Covered,
	)
	later := coverage_of(true, paid, "2026-10-19T00:00:01Z", true, false)
	testing.expect_value(t, later, query.Update_Coverage.Later)
	testing.expect(t, !coverage_allows(later))
	unstamped := coverage_of(true, paid, "", false, false)
	testing.expect_value(t, unstamped, query.Update_Coverage.Unstamped)
	testing.expect(t, !coverage_allows(unstamped))
	testing.expect(t, coverage_allows(.Covered))
	testing.expect(t, coverage_allows(.None))
	// The updater's refusal is the same explanation, even if this build's
	// own stamp would not have called the copy retained.
	testing.expect_value(
		t,
		coverage_of(false, paid, "2027-01-01T00:00:00Z", true, true),
		query.Update_Coverage.Later,
	)
	testing.expect_value(
		t,
		coverage_of(false, paid, "", false, true),
		query.Update_Coverage.Unstamped,
	)
}

@(private)
set_schedule_clock :: proc(d: ^Desk, wall, mono: i64) {
	sync.atomic_store(&d.update_time.wall, wall)
	sync.atomic_store(&d.update_time.mono, mono)
}

@(private)
schedule_count :: proc(d: ^Desk) -> int {
	return sync.atomic_load(&d.update_auto_count)
}

@(private)
schedule_open :: proc(t: ^testing.T, path: string) -> ^Desk {
	d := new(Desk)
	d.update_time = new(Update_Time)
	st := new(settings.Store)
	testing.expect(t, settings.open(st, path) == nil, "the settings store opens")
	d.settings = st
	update_restore(d)
	return d
}

@(private)
schedule_close :: proc(d: ^Desk) {
	if d == nil {
		return
	}
	if d.settings != nil {
		settings.close(d.settings)
		free(d.settings)
	}
	delete(d.update_dismissed, context.allocator)
	free(d.update_time)
	free(d)
}

@(private)
set_schedule_latest :: proc(d: ^Desk, version: string) {
	d.update_result.latest_len = copy(d.update_result.latest_buf[:], version)
}

// Remove the fixture database and SQLite sidecars after schedule_close
// closes its connections, without the shell-recursive directory deletion.
@(private)
remove_schedule_dir :: proc(t: ^testing.T, dir: string) {
	if dir == "" {
		return
	}
	remove_one :: proc(path: string) -> os.Error {
		if !os.exists(path) {
			return nil
		}
		return os.remove(path)
	}
	db := fmt.tprintf("%s/%s", dir, settings.FILE)
	testing.expect(t, remove_one(db) == nil, "settings.db is removed")
	testing.expect(t, remove_one(fmt.tprintf("%s-wal", db)) == nil, "settings.db-wal is removed")
	testing.expect(t, remove_one(fmt.tprintf("%s-shm", db)) == nil, "settings.db-shm is removed")
	testing.expect(t, os.remove(dir) == nil, "the schedule directory is removed")
	testing.expect(t, !os.exists(dir), "the schedule directory is gone")
}

@(test)
schedule_fixture_removal_deletes_the_database_and_the_directory :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "leita-schedule-rm-*", context.temp_allocator)
	testing.expect(t, derr == nil, "a temp directory")
	db := fmt.tprintf("%s/%s", dir, settings.FILE)
	wal := fmt.tprintf("%s-wal", db)
	shm := fmt.tprintf("%s-shm", db)
	testing.expect(t, os.write_entire_file(db, "x") == nil)
	testing.expect(t, os.write_entire_file(wal, "w") == nil)
	testing.expect(t, os.write_entire_file(shm, "s") == nil)
	remove_schedule_dir(t, dir)
	testing.expect(t, !os.exists(db), "settings.db is gone")
	testing.expect(t, !os.exists(wal), "settings.db-wal is gone")
	testing.expect(t, !os.exists(shm), "settings.db-shm is gone")
	testing.expect(t, !os.exists(dir), "the schedule directory is gone")
}

// Opted-in checks are one at startup and one a day, through the desk's tick.
// Off stays off. A second window does not repeat the check. A wall-clock
// jump is one check. Nothing in this test installs or asks the network.
@(test)
automatic_checks_once_at_startup_and_once_a_day :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "leita-schedule-*", context.temp_allocator)
	testing.expect(t, derr == nil, "a temp directory")
	defer remove_schedule_dir(t, dir)
	path := fmt.tprintf("%s/%s", dir, settings.FILE)

	T :: i64(1_700_000_000)
	M :: i64(1_000_000_000)
	first := schedule_open(t, path)
	defer schedule_close(first)
	set_schedule_clock(first, T, M)

	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 0)
	testing.expect_value(t, first.update_state, query.Update_State.Idle)
	_, found := settings.get(first.settings, settings.UPDATES, context.temp_allocator)
	testing.expect(t, !found, "automatic checks are absent until chosen")

	desk_step(first, Sent_Command{c = command.Command(command.Check_Update{})})
	testing.expect_value(t, sync.atomic_load(&first.update_manual_count), 1)
	testing.expect_value(t, schedule_count(first), 0)
	testing.expect(t, first.update_thread == nil, "a manual check with no port does not install")

	desk_step(first, Sent_Command{c = command.Command(command.Automatic_Checks{on = true})})
	opted, opted_ok := settings.get(first.settings, settings.UPDATES, context.temp_allocator)
	testing.expect(t, opted_ok && opted == "on", "the choice is kept")
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 1)
	testing.expect(t, first.update_startup_done)
	got, ok := settings.get(first.settings, settings.UPDATE_CHECKED, context.temp_allocator)
	testing.expect(t, ok && got == fmt.tprintf("%d", T), "the startup check is the one recorded")
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 1)

	// Another window that has not yet seen the record tries the same startup.
	peer := new(Desk)
	defer schedule_close(peer)
	peer.update_time = new(Update_Time)
	peer_store := new(settings.Store)
	testing.expect(t, settings.open(peer_store, path) == nil)
	peer.settings = peer_store
	set_schedule_clock(peer, T + 30, M)
	desk_step(peer, Tick{})
	testing.expect_value(t, schedule_count(peer), 0)
	testing.expect(t, peer.update_startup_done, "the peer's startup is the check already recorded")
	testing.expect(t, peer.update_thread == nil)

	set_schedule_clock(first, T + DAY_SEC, M + DAY_NS)
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 2)
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 2)

	set_schedule_clock(first, T + 4 * DAY_SEC, M + DAY_NS + i64(1_000_000_000))
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 3)
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 3)

	// The monotonic count stays at the previous tick. The wall time is
	// several days later, and one tick records one check.
	set_schedule_clock(first, T + 7 * DAY_SEC, M + DAY_NS + i64(1_000_000_000))
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 4)
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 4)

	set_schedule_clock(
		first,
		T + 7 * DAY_SEC - 10 * 3600,
		M + DAY_NS + i64(1_000_000_000) + i64(3_600_000_000_000),
	)
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 4)
	set_schedule_clock(
		first,
		T + 7 * DAY_SEC - 10 * 3600,
		M + DAY_NS + i64(1_000_000_000) + DAY_NS,
	)
	desk_step(first, Tick{})
	testing.expect_value(t, schedule_count(first), 5)
	testing.expect_value(t, first.update_state, query.Update_State.Idle)

	desk_step(
		first,
		Sent_Command {
			c = command.Command(command.Dismiss_Update{version = command.text_make("v1")}),
		},
	)
	again := schedule_open(t, path)
	defer schedule_close(again)
	set_schedule_latest(again, "v1")
	again.update_state = .Available
	again.update_can_apply = true
	answered := update_answer(again)
	testing.expect(t, !answered.notice, "the dismissed version stays dismissed")
	set_schedule_latest(again, "v2")
	answered = update_answer(again)
	testing.expect(t, answered.notice, "a newer release shows")

	p := stream.make_pipeline(context.allocator, cap = 1)
	defer stream.destroy(p)
	_, port := stream.port(p, Updated, cap = 1)
	again.updates = &port
	// This AppImage fixture makes an allowed Apply job refuse locally,
	// before file access; the test checks dispatch, not installation.
	again.update_exe = "/tmp/.mount_leita/Leita"
	again.update_result.reason = .Ineligible
	again.licensed = true
	again.licence.paid_through = "2026-10-19T00:00:00Z"
	again.update_result.released_ok = false
	answered = update_answer(again)
	testing.expect_value(t, answered.coverage, query.Update_Coverage.Unstamped)
	testing.expect(t, !answered.can_apply, "an ineligible release is not installed")
	testing.expect_value(t, answered.problem, query.Update_Problem.None)
	update_apply(again)
	testing.expect(t, again.update_thread == nil)
	testing.expect_value(t, again.update_state, query.Update_State.Available)
	// The same wired desk must dispatch when coverage allows it. A no-op
	// update_apply would pass the refusal assertions but fail these.
	again.update_result.reason = .None
	again.licensed = false
	update_apply(again)
	testing.expect(t, again.update_thread != nil)
	testing.expect_value(t, again.update_state, query.Update_State.Applying)
	update_stop(again)

	kept, _ := settings.get(again.settings, settings.UPDATE_DISMISSED, context.temp_allocator)
	testing.expect_value(t, kept, "v1")
}

@(private)
set_query_only :: proc(t: ^testing.T, d: ^Desk, on: bool) {
	sql := "PRAGMA query_only = ON" if on else "PRAGMA query_only = OFF"
	testing.expect(t, sqlite3.exec(d.settings.db, sql) == nil, sql)
}

// A store that already says on cannot take the write. The persisted choice
// stays on, this session checks nothing, and a failed opt-in stays off.
// A later write that succeeds clears the flag and follows the choice.
@(test)
a_failed_update_choice_checks_nothing_until_it_is_saved :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "leita-schedule-ro-*", context.temp_allocator)
	testing.expect(t, derr == nil, "a temp directory")
	defer remove_schedule_dir(t, dir)
	path := fmt.tprintf("%s/%s", dir, settings.FILE)

	T :: i64(1_700_000_000)
	M :: i64(1_000_000_000)
	d := schedule_open(t, path)
	defer schedule_close(d)
	set_schedule_clock(d, T, M)
	testing.expect(
		t,
		settings.set(d.settings, settings.UPDATES, "on") == nil,
		"the store starts on",
	)
	testing.expect(t, settings.set(d.settings, settings.LANGUAGE, "de") == nil)
	testing.expect(t, update_enabled(d), "the saved choice would check")

	set_query_only(t, d, true)
	remember_updates(d, false)
	kept, kept_ok := settings.get(d.settings, settings.UPDATES, context.temp_allocator)
	testing.expect(t, kept_ok && kept == "on", "the failed opt-out leaves the stored choice")
	testing.expect(t, d.update_save_failed)
	testing.expect(t, !update_enabled(d))
	failed := settings_answer(d)
	testing.expect(t, !failed.automatic_checks, "effective checks are off")
	testing.expect(t, failed.automatic_checks_unsaved)
	testing.expect_value(t, failed.language, "de")
	desk_step(d, Tick{})
	testing.expect_value(t, schedule_count(d), 0)
	testing.expect_value(t, d.update_state, query.Update_State.Idle)
	testing.expect(t, d.update_thread == nil, "a failed opt-out starts no check")
	desk_step(d, Tick{})
	testing.expect_value(t, schedule_count(d), 0)

	// Asking to turn checks on cannot succeed while the write is refused.
	remember_updates(d, true)
	still_on, still_ok := settings.get(d.settings, settings.UPDATES, context.temp_allocator)
	testing.expect(t, still_ok && still_on == "on", "the failed opt-in changes nothing stored")
	testing.expect(t, d.update_save_failed)
	testing.expect(t, !update_enabled(d), "a failed opt-in stays off")
	desk_step(d, Tick{})
	testing.expect_value(t, schedule_count(d), 0)

	set_query_only(t, d, false)
	remember_updates(d, false)
	testing.expect(t, !d.update_save_failed, "a saved choice clears the flag")
	off, off_ok := settings.get(d.settings, settings.UPDATES, context.temp_allocator)
	testing.expect(t, off_ok && off == "off")
	testing.expect(t, !update_enabled(d))
	saved_off := settings_answer(d)
	testing.expect(t, !saved_off.automatic_checks)
	testing.expect(t, !saved_off.automatic_checks_unsaved)
	desk_step(d, Tick{})
	testing.expect_value(t, schedule_count(d), 0)

	set_query_only(t, d, true)
	remember_updates(d, true)
	stayed, stayed_ok := settings.get(d.settings, settings.UPDATES, context.temp_allocator)
	testing.expect(t, stayed_ok && stayed == "off", "a failed opt-in leaves off stored")
	testing.expect(t, d.update_save_failed)
	testing.expect(t, !update_enabled(d))
	failed_on := settings_answer(d)
	testing.expect(t, !failed_on.automatic_checks)
	testing.expect(t, failed_on.automatic_checks_unsaved)
	desk_step(d, Tick{})
	testing.expect_value(t, schedule_count(d), 0)

	set_query_only(t, d, false)
	remember_updates(d, true)
	testing.expect(t, !d.update_save_failed)
	on, on_ok := settings.get(d.settings, settings.UPDATES, context.temp_allocator)
	testing.expect(t, on_ok && on == "on")
	testing.expect(t, update_enabled(d))
	saved_on := settings_answer(d)
	testing.expect(t, saved_on.automatic_checks)
	testing.expect(t, !saved_on.automatic_checks_unsaved)
	desk_step(d, Tick{})
	testing.expect_value(t, schedule_count(d), 1)
	desk_step(d, Tick{})
	testing.expect_value(t, schedule_count(d), 1)

	bare: Desk
	remember_updates(&bare, true)
	testing.expect(t, bare.update_save_failed, "a missing store cannot save the choice")
	testing.expect(t, !update_enabled(&bare))
	missing := settings_answer(&bare)
	testing.expect(t, !missing.automatic_checks)
	testing.expect(t, missing.automatic_checks_unsaved)
	testing.expect_value(t, missing.language, "")
}
