package leita_app

import "core:testing"

import "../query"

@(private)
moment :: proc(enabled: bool, startup_done: bool, last_wall, now_wall, last_mono, now_mono, opened: i64, has_mono: bool) -> Moment {
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
	off := moment(false, false, 0, T + 3 * DAY_SEC, 0, M, M, false)
	testing.expect_value(t, due(off), When.None)

	testing.expect_value(t, due(moment(true, false, 0, T, 0, M, M, false)), When.Startup)
	// Another window recorded a check 30s ago.
	testing.expect_value(t, due(moment(true, false, T, T + 30, 0, M, M, false)), When.Peer)
	// A clock a minute ahead of ours is the same startup, not a new one.
	testing.expect_value(t, due(moment(true, false, T + 60, T, 0, M, M, false)), When.Peer)
	// Opening Leita again after the coalesce is a new startup check.
	testing.expect_value(t, due(moment(true, false, T, T + 5 * 60, 0, M, M, false)), When.Startup)

	// A day of the window staying open.
	day := moment(true, true, T, T + DAY_SEC, M, M + DAY_NS, M, true)
	testing.expect_value(t, due(day), When.Daily)
	// Less than a day is not due.
	testing.expect_value(t, due(moment(true, true, T, T + DAY_SEC - 1, M, M + DAY_NS - 1, M, true)), When.None)

	// Sleep does not move the monotonic clock. One check, then the record
	// is the new wall time, so the same sleep does not check again.
	slept := moment(true, true, T, T + 3 * DAY_SEC, M, M, M, true)
	testing.expect_value(t, due(slept), When.Daily)
	slept.last_wall = T + 3 * DAY_SEC
	slept.now_wall = T + 3 * DAY_SEC
	testing.expect_value(t, due(slept), When.None)

	// A forward jump of three days is one check, not three.
	jumped := moment(true, true, T, T + 3 * DAY_SEC, M, M + int(1e9), M, true)
	testing.expect_value(t, due(jumped), When.Daily)
	jumped.last_wall = T + 3 * DAY_SEC
	jumped.last_mono = M + int(1e9)
	jumped.now_wall = T + 3 * DAY_SEC
	jumped.now_mono = M + int(1e9)
	testing.expect_value(t, due(jumped), When.None)

	// A clock set backward does not check until a monotonic day has passed.
	back := moment(true, true, T, T - 10 * 3600, M, M + int(3600e9), M, true)
	testing.expect_value(t, due(back), When.None)
	back.now_mono = M + DAY_NS
	testing.expect_value(t, due(back), When.Daily)
}

// The eligibility decision the notice words. A build that is not retained
// Pro is not refused. A retained one takes an instant at or before
// paid-through, and refuses a later or unstamped release.
@(test)
a_retained_release_after_paid_through_is_not_offered :: proc(t: ^testing.T) {
	paid :: "2026-10-19T00:00:00Z"
	testing.expect_value(t, coverage_of(false, paid, "2027-01-01T00:00:00Z", true, false), query.Update_Coverage.None)
	testing.expect_value(t, coverage_of(true, paid, paid, true, false), query.Update_Coverage.Covered)
	testing.expect_value(t, coverage_of(true, paid, "2026-10-18T00:00:00Z", true, false), query.Update_Coverage.Covered)
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
	testing.expect_value(t, coverage_of(false, paid, "2027-01-01T00:00:00Z", true, true), query.Update_Coverage.Later)
	testing.expect_value(t, coverage_of(false, paid, "", false, true), query.Update_Coverage.Unstamped)
}
