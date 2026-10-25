package leita_monitor

import "core:fmt"
import "core:os"
import "core:testing"

import "../settings"

@(test)
a_place_is_due_once_its_period_is_nearly_up :: proc(t: ^testing.T) {
	hour :: 60 * 60
	testing.expect(t, due(.Weekly, 0, 1000), "never scanned is due")
	testing.expect(t, due(.Hourly, 10 * hour, 11 * hour - 4 * 60), "a run five minutes early")
	testing.expect(t, !due(.Hourly, 10 * hour, 10 * hour + 30 * 60))
	testing.expect(t, !due(.Daily, 0 + 1, 20 * hour))
	testing.expect(t, due(.Daily, 1, 24 * hour - 5 * 60))
	testing.expect(t, !due(.Weekly, 1, 6 * 24 * hour))
	testing.expect(t, due(.Weekly, 1, 7 * 24 * hour))
}

/*
due takes Unix seconds and no zone, so a place's period is counted in elapsed time:
fed hourly runs for a year, which holds every change of the clock of both
hemispheres, a daily place is scanned every 24 hours of runs and a weekly one every
168, never twice and never skipped. The runs start a few minutes past the hour, as
the scheduler's delay makes them. (The days themselves are not modelled; a day of
23 or 25 hours only moves the time on the clock a scan falls at.)
*/
@(test)
a_daily_and_a_weekly_place_keep_their_period_in_elapsed_time :: proc(t: ^testing.T) {
	hour :: 60 * 60
	for every in ([?]struct {
			every: settings.Frequency,
			hours: i64,
		}{{.Daily, 24}, {.Weekly, 168}}) {
		last: i64
		scans := 0
		first_scan: i64
		// 53 weeks of hourly runs from 2026-03-01T00:00:00Z.
		start :: i64(1_772_323_200)
		for k in i64(0) ..< 53 * 7 * 24 {
			// The scheduler's delay: up to five minutes past the hour, the same
			// five each time the hour comes round.
			now := start + k * hour + (k * 7919) % 300
			if due(every.every, last, now) {
				if scans > 0 {
					gap := now - last
					testing.expectf(
						t,
						gap >= every.hours * hour - 5 * 60 && gap <= every.hours * hour + 5 * 60,
						"%v: scans %d s apart, not %d hours",
						every.every,
						gap,
						every.hours,
					)
				} else {
					first_scan = now
				}
				last = now
				scans += 1
			}
		}
		want := int(53 * 7 * 24 / every.hours)
		testing.expectf(t, scans == want, "%v: %d scans in 53 weeks, want %d (first at %d)", every.every, scans, want, first_scan)
	}
}

@(test)
a_run_holds_a_lock_another_run_stands_aside_for :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "leita-lock-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/%s", dir, LOCK_FILE)

	l, taken := lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	unlock(&l)
	l, taken = lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	// A second open of the file is refused while the first holds it.
	_, again := lock(path)
	testing.expect_value(t, again, Lock_Result.Held)
	unlock(&l)
	l, taken = lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	unlock(&l)
	_, taken = lock(fmt.tprintf("%s/missing/%s", dir, LOCK_FILE))
	testing.expect_value(t, taken, Lock_Result.Failed)
}
