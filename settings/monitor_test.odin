package leita_settings

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "jm:sqlite3"

@(test)
monitoring_is_off_until_turned_on :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	testing.expect(t, !monitoring(&st), "nothing chosen is off")
	testing.expect(t, set_monitoring(&st, true) == nil)
	testing.expect(t, monitoring(&st))
	testing.expect(t, set_monitoring(&st, false) == nil)
	testing.expect(t, !monitoring(&st))
}

@(test)
a_place_watched_again_takes_its_new_schedule :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	testing.expect(t, watch(&st, {place = "/srv", every = .Daily, added = 10}) == nil)
	testing.expect(t, watch(&st, {place = "/home", every = .Hourly, added = 20}) == nil)
	testing.expect(t, watch(&st, {place = "/srv", every = .Weekly, added = 30}) == nil)

	ws, err := watches(&st, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(ws), 2)
	testing.expect_value(t, ws[0].place, "/srv")
	testing.expect_value(t, ws[0].every, Frequency.Weekly)
	testing.expect_value(t, ws[0].added, 10)
	testing.expect_value(t, ws[1].place, "/home")

	found, uerr := unwatch(&st, "/srv")
	testing.expect(t, uerr == nil && found)
	found, _ = unwatch(&st, "/srv")
	testing.expect(t, !found, "already gone")
	ws, _ = watches(&st, context.temp_allocator)
	testing.expect_value(t, len(ws), 1)
}

@(test)
runs_are_kept_newest_first_up_to_a_limit :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	for i in 0 ..< RUNS_KEPT + 5 {
		_, err := record(
			&st,
			{place = "/srv", started = i64(100 + i), seconds = 1.5, bytes = u64(i)},
		)
		testing.expect(t, err == nil)
	}
	_, _ = record(&st, {place = "/home", started = 1, problem = "gone"})

	rs, err := runs(&st, "/srv", allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(rs), RUNS_KEPT)
	testing.expect_value(t, rs[0].started, i64(100 + RUNS_KEPT + 4))
	testing.expect_value(t, rs[0].seconds, 1.5)

	last, ok := last_run(&st, "/home", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, last.problem, "gone")
	_, ok = last_run(&st, "/nowhere", context.temp_allocator)
	testing.expect(t, !ok)

	// Unwatching a place forgets its runs.
	_, _ = unwatch(&st, "/srv")
	rs, _ = runs(&st, "/srv", allocator = context.temp_allocator)
	testing.expect_value(t, len(rs), 0)
}

@(test)
a_store_opened_again_keeps_its_watches :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "leita-settings-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, FILE}, context.temp_allocator)

	for i in 0 ..< 3 {
		st: Store
		testing.expectf(t, open(&st, path) == nil, "open %d", i)
		testing.expect(t, watch(&st, {place = fmt.tprintf("/p%d", i), every = .Hourly}) == nil)
		close(&st)
	}
	st: Store
	testing.expect(t, open(&st, path) == nil)
	defer close(&st)
	ws, _ := watches(&st, context.temp_allocator)
	testing.expect_value(t, len(ws), 3)
	for w, i in ws {
		testing.expect_value(t, w.place, fmt.tprintf("/p%d", i))
		testing.expect_value(t, w.every, Frequency.Hourly)
	}
}

// A store made before a column was added gains it when opened, keeping its
// rows, which read as the column's default; opening it again changes nothing.
@(test)
an_older_store_gains_the_columns_it_lacks :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "leita-settings-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, FILE}, context.temp_allocator)
	{
		db, err := sqlite3.open(path, {}, context.temp_allocator)
		testing.expect(t, err == nil)
		testing.expect(
			t,
			sqlite3.exec(
				db,
				`CREATE TABLE run(
					id INTEGER PRIMARY KEY, place TEXT NOT NULL, started INTEGER NOT NULL,
					seconds REAL NOT NULL, bytes INTEGER NOT NULL, disk_total INTEGER NOT NULL,
					disk_free INTEGER NOT NULL, problem TEXT NOT NULL);
				INSERT INTO run(place, started, seconds, bytes, disk_total, disk_free, problem)
					VALUES ('/srv', 5, 1.0, 7, 0, 0, '');
				CREATE TABLE watch(place TEXT PRIMARY KEY, every TEXT NOT NULL,
					added INTEGER NOT NULL) WITHOUT ROWID;
				INSERT INTO watch(place, every, added) VALUES ('/srv', 'weekly', 3);`,
			) ==
			nil,
		)
		sqlite3.close(&db)
	}
	for _ in 0 ..< 2 {
		st: Store
		testing.expect(t, open(&st, path) == nil)
		rs, err := runs(&st, "/srv", allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, len(rs), 1)
		testing.expect_value(t, rs[0].bytes, 7)
		testing.expect(t, !rs[0].updated)
		testing.expect_value(t, rs[0].reread, 0)
		testing.expect_value(t, rs[0].taken, 0)
		testing.expect_value(t, rs[0].why, "")
		testing.expect_value(t, rs[0].firing, "")
		ws, _ := watches(&st, context.temp_allocator)
		testing.expect_value(t, len(ws), 1)
		testing.expect_value(t, ws[0].every, Frequency.Weekly)
		testing.expect_value(t, ws[0].limits, Limits{})
		close(&st)
	}
	st: Store
	testing.expect(t, open(&st, path) == nil)
	defer close(&st)
	_, err := record(&st, {place = "/srv", started = 6, updated = true, reread = 4, taken = 5})
	testing.expect(t, err == nil)
	last, _ := last_run(&st, "/srv", context.temp_allocator)
	testing.expect(t, last.updated)
	testing.expect_value(t, last.reread, 4)
	testing.expect_value(t, last.taken, 5)
}

@(test)
a_watch_keeps_its_limits_and_a_run_what_was_firing :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	limits := Limits {
		warn_used   = 80,
		fail_used   = 95,
		min_free    = 20 << 30,
		full_within = 14,
		growth      = true,
	}
	// The largest size an i64 holds round-trips. One past it cannot be stored.
	testing.expect(
		t,
		watch(&st, {place = "/top", every = .Daily, limits = {min_free = u64(max(i64))}}) == nil,
	)
	top, terr := watches(&st, context.temp_allocator)
	testing.expect(t, terr == nil)
	testing.expect_value(t, top[0].limits.min_free, u64(max(i64)))

	testing.expect(t, watch(&st, {place = "/srv", every = .Daily, limits = limits}) == nil)
	ws, _ := watches(&st, context.temp_allocator)
	testing.expect_value(t, ws[0].limits, limits)
	testing.expect(t, watch(&st, {place = "/srv", every = .Daily}) == nil)
	ws, _ = watches(&st, context.temp_allocator)
	testing.expect_value(t, ws[0].limits, Limits{})

	_, err := record(&st, {place = "/srv", started = 1, firing = "warn_used,filling"})
	testing.expect(t, err == nil)
	last, _ := last_run(&st, "/srv", context.temp_allocator)
	testing.expect_value(t, last.firing, "warn_used,filling")
}

// A size past 2^63 is stored negative. Reading it back as a u64 would alert on
// every scan, so the row is refused and named.
@(test)
a_negative_min_free_is_refused :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)
	testing.expect(
		t,
		sqlite3.exec_args(
			st.db,
			`INSERT INTO watch(place, every, added, warn_used, fail_used, min_free, full_within, growth)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			"/data",
			"daily",
			i64(1),
			i64(0),
			i64(0),
			i64(-1),
			i64(0),
			false,
		) ==
		nil,
	)
	ws, err := watches(&st, context.temp_allocator)
	testing.expect_value(t, len(ws), 0)
	fault := err.(sqlite3.Fault) or_else sqlite3.Fault{}
	testing.expect(t, strings.contains(fault.text, "/data"), fault.text)
	testing.expect(t, strings.contains(fault.text, "min_free"), fault.text)
}

@(test)
alerts_are_kept_newest_first_up_to_a_limit :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	for i in 0 ..< RAISED_KEPT + 3 {
		place := "/srv" if i % 2 == 0 else "/home"
		a := Raised {
			place        = place,
			raised       = i64(i),
			kind         = "warn_used",
			used_percent = 81.5,
			free         = 3,
			total        = 10,
			limit        = 80,
		}
		testing.expect(t, raise(&st, a) == nil)
	}
	all, err := alerts(&st, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(all), RAISED_KEPT)
	testing.expect_value(t, all[0].raised, i64(RAISED_KEPT + 2))
	testing.expect_value(t, all[0].used_percent, 81.5)
	testing.expect_value(t, all[0].limit, 80)
	srv, _ := alerts(&st, "/srv", 5, context.temp_allocator)
	testing.expect_value(t, len(srv), 5)
	for a in srv {
		testing.expect_value(t, a.place, "/srv")
	}
}
