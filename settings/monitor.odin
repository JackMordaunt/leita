package leita_settings

import "core:fmt"
import "core:mem"
import "core:strings"

import "jm:sqlite3"

/*
What monitoring keeps (a paid feature): the places watched and how often each
is scanned, whether monitoring is on at all, and how each scan the monitor ran
went. The window and the command line share these through settings.db, so a
place added in one is watched by the other's next run.

Each place watched carries the limits its scans are checked against (Limits),
each run what was wrong after it (firing), and the alerts raised, each the
first run something went wrong, are kept in a log of their own (Raised).

Monitoring is off until the person turns it on: MONITOR unset reads as off, and
no place is watched until one is added.
*/

// MONITOR is the key of the off switch: ON while the system's scheduler runs
// the monitor, anything else or absent for off.
MONITOR :: "monitor"
ON      :: "on"
OFF     :: "off"

// Frequency is how often a watched place is scanned.
Frequency :: enum u8 {
	Hourly,
	Daily,
	Weekly,
}

// FREQUENCY_NAMES name each Frequency as the store and the command line write it.
FREQUENCY_NAMES := [Frequency]string {
	.Hourly = "hourly",
	.Daily  = "daily",
	.Weekly = "weekly",
}

// frequency_named is the Frequency name names, and whether there is one.
// The Frequency is meaningless when the bool is false.
frequency_named :: proc(name: string) -> (Frequency, bool) {
	for n, e in FREQUENCY_NAMES {
		if strings.equal_fold(n, name) {
			return e, true
		}
	}
	return .Daily, false
}

// Watch is one place the monitor scans, and the limits each scan is checked
// against.
Watch :: struct {
	place:  string, // as the person gave it
	every:  Frequency,
	added:  i64, // Unix seconds
	limits: Limits,
}

// Limits are what a scan of a watched place is checked against, each off at
// zero (or false): report.threshold_of's three, then how many days ahead the
// disk may be forecast to fill, and whether to say when the place grows much
// faster than it has been.
Limits :: struct {
	warn_used:   int, // percent used
	fail_used:   int, // percent used
	min_free:    u64, // bytes
	full_within: int, // days
	growth:      bool,
}

// Run is one scan of a watched place the monitor ran: when it started, how
// long it took, what the place held and the disk it was on then, whether it
// was updated from the place's last tree, how many directories that read and
// when that tree was kept, or read whole and why, and why it failed, "" when it
// did not.
Run :: struct {
	id:         i64,
	place:      string,
	started:    i64, // Unix seconds
	seconds:    f64,
	bytes:      u64,
	disk_total: u64,
	disk_free:  u64,
	updated:    bool,
	reread:     u64, // updated: how many directories were read rather than copied
	taken:      i64, // updated: Unix seconds the tree updated from was kept, 0 when not known
	why:        string, // why it was read whole, "" for no reason given
	problem:    string,
	firing:     string, // what was wrong after it, alert.Condition keys joined by ","
}

// Raised is an alert, kept the run it first fired: on which place and when,
// its alert.Condition key, and what it measured, each 0 where it does not apply:
// the percent used, the disk's free and total bytes, the days a forecast says
// are left, the bytes grown since the last scan, and the limit crossed.
Raised :: struct {
	id:           i64,
	place:        string,
	raised:       i64, // Unix seconds
	kind:         string,
	used_percent: f64,
	free:         u64,
	total:        u64,
	days:         f64,
	grew:         u64,
	limit:        f64,
	problem:      string, // why a scan failed
}

// RAISED_KEPT is how many alerts are kept, newest first, of every place.
RAISED_KEPT :: 200

// RUNS_KEPT is how many runs of each place are kept, newest first.
RUNS_KEPT :: 50

@(private)
MONITOR_SCHEMA :: `
	CREATE TABLE IF NOT EXISTS watch(
		place TEXT PRIMARY KEY,
		every TEXT NOT NULL,
		added INTEGER NOT NULL) WITHOUT ROWID;
	CREATE TABLE IF NOT EXISTS run(
		id INTEGER PRIMARY KEY,
		place TEXT NOT NULL,
		started INTEGER NOT NULL,
		seconds REAL NOT NULL,
		bytes INTEGER NOT NULL,
		disk_total INTEGER NOT NULL,
		disk_free INTEGER NOT NULL,
		problem TEXT NOT NULL);
	CREATE INDEX IF NOT EXISTS run_place ON run(place, started);
	CREATE TABLE IF NOT EXISTS raised(
		id INTEGER PRIMARY KEY,
		place TEXT NOT NULL,
		raised INTEGER NOT NULL,
		kind TEXT NOT NULL,
		used_percent REAL NOT NULL,
		free INTEGER NOT NULL,
		total INTEGER NOT NULL,
		days REAL NOT NULL,
		grew INTEGER NOT NULL,
		limit_crossed REAL NOT NULL,
		problem TEXT NOT NULL);`

// monitoring is whether the person turned monitoring on.
monitoring :: proc(st: ^Store) -> bool {
	v, _ := get(st, MONITOR, context.temp_allocator)
	return v == ON
}

// set_monitoring keeps whether monitoring is on.
set_monitoring :: proc(st: ^Store, on: bool) -> sqlite3.Error {
	return set(st, MONITOR, ON if on else OFF)
}

// watch keeps w, in place of any watch of the same place.
watch :: proc(st: ^Store, w: Watch) -> sqlite3.Error {
	return sqlite3.exec_args(
		st.db,
		`INSERT INTO watch(place, every, added, warn_used, fail_used, min_free, full_within, growth)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(place) DO UPDATE SET every = excluded.every,
				warn_used = excluded.warn_used, fail_used = excluded.fail_used,
				min_free = excluded.min_free, full_within = excluded.full_within,
				growth = excluded.growth`,
		w.place,
		FREQUENCY_NAMES[w.every],
		w.added,
		i64(w.limits.warn_used),
		i64(w.limits.fail_used),
		i64(w.limits.min_free),
		i64(w.limits.full_within),
		w.limits.growth,
	)
}

// unwatch stops watching place and forgets its runs and alerts, and says
// whether it was watched.
unwatch :: proc(st: ^Store, place: string) -> (found: bool, err: sqlite3.Error) {
	sqlite3.exec_args(st.db, "DELETE FROM watch WHERE place = ?", place) or_return
	found = sqlite3.changes(st.db) > 0
	sqlite3.exec_args(st.db, "DELETE FROM run WHERE place = ?", place) or_return
	sqlite3.exec_args(st.db, "DELETE FROM raised WHERE place = ?", place) or_return
	return
}

// watches is every place watched, in the order they were added, in allocator.
watches :: proc(st: ^Store, allocator := context.allocator) -> (out: []Watch, err: sqlite3.Error) {
	rows := sqlite3.query(
		st.db,
		`SELECT place, every, added, warn_used, fail_used, min_free, full_within, growth
			FROM watch ORDER BY added, place`,
		allocator = context.temp_allocator,
	) or_return
	found := make([dynamic]Watch, allocator)
	for sqlite3.next(&rows) {
		place := sqlite3.text(rows, 0)
		// min_free is an i64 in the file. A negative one was a size past 2^63
		// stored wrapped, and reading it back as a u64 makes every scan alert.
		if sqlite3.integer(rows, 5) < 0 {
			return watches_refused(&rows, found[:], allocator, place, "min_free is negative")
		}
		// An unknown every in a copied settings.db must not become daily.
		every_name := sqlite3.text(rows, 1)
		every, known := frequency_named(every_name)
		if !known {
			return watches_refused(
				&rows,
				found[:],
				allocator,
				place,
				fmt.tprintf("unknown frequency %q", every_name),
			)
		}
		append(
			&found,
			Watch {
				place = strings.clone(place, allocator),
				every = every,
				added = sqlite3.integer(rows, 2),
				limits = {
					warn_used = int(sqlite3.integer(rows, 3)),
					fail_used = int(sqlite3.integer(rows, 4)),
					min_free = u64(sqlite3.integer(rows, 5)),
					full_within = int(sqlite3.integer(rows, 6)),
					growth = sqlite3.boolean(rows, 7),
				},
			},
		)
	}
	if err = sqlite3.finish(&rows); err != nil {
		watches_destroy(found[:], allocator)
		return nil, err
	}
	return found[:], nil
}

// watches_refused stops a read on a row the scan must not trust. place names
// the row, so a copied settings.db says which one. Callers already report a
// sqlite3.Error when a read fails; a row that would lie is that kind of
// failure. The text is in the temp allocator, for the caller to print with
// the error. Rows already read are dropped: returning them would scan the
// sound ones and hide the bad one.
@(private)
watches_refused :: proc(
	rows: ^sqlite3.Stmt,
	found: []Watch,
	allocator: mem.Allocator,
	place, why: string,
) -> (
	[]Watch,
	sqlite3.Error,
) {
	err := sqlite3.Fault {
		code = .Error,
		text = strings.concatenate({place, ": ", why}, context.temp_allocator),
	}
	sqlite3.finish(rows)
	watches_destroy(found, allocator)
	return nil, err
}

// watches_destroy frees what watches returned.
watches_destroy :: proc(ws: []Watch, allocator := context.allocator) {
	for w in ws {
		delete(w.place, allocator)
	}
	delete(ws, allocator)
}

// record keeps r as the newest run of its place and forgets the oldest past
// RUNS_KEPT, and returns its id.
record :: proc(st: ^Store, r: Run) -> (id: i64, err: sqlite3.Error) {
	sqlite3.exec_args(
		st.db,
		`INSERT INTO run(place, started, seconds, bytes, disk_total, disk_free, updated,
			reread, taken, why, problem, firing)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.place,
		r.started,
		r.seconds,
		i64(r.bytes),
		i64(r.disk_total),
		i64(r.disk_free),
		r.updated,
		i64(r.reread),
		r.taken,
		r.why,
		r.problem,
		r.firing,
	) or_return
	id = sqlite3.last_id(st.db)
	sqlite3.exec_args(
		st.db,
		`DELETE FROM run WHERE place = ? AND id NOT IN
			(SELECT id FROM run WHERE place = ? ORDER BY started DESC, id DESC LIMIT ?)`,
		r.place,
		r.place,
		i64(RUNS_KEPT),
	) or_return
	return
}

// runs is the runs of place, newest first, at most limit, in allocator.
runs :: proc(
	st: ^Store,
	place: string,
	limit := RUNS_KEPT,
	allocator := context.allocator,
) -> (
	out: []Run,
	err: sqlite3.Error,
) {
	rows := sqlite3.query(
		st.db,
		`SELECT id, place, started, seconds, bytes, disk_total, disk_free, updated, reread,
			taken, why, problem, firing
			FROM run WHERE place = ? ORDER BY started DESC, id DESC LIMIT ?`,
		place,
		i64(limit),
		allocator = context.temp_allocator,
	) or_return
	found := make([dynamic]Run, allocator)
	for sqlite3.next(&rows) {
		append(
			&found,
			Run {
				id = sqlite3.integer(rows, 0),
				place = strings.clone(sqlite3.text(rows, 1), allocator),
				started = sqlite3.integer(rows, 2),
				seconds = sqlite3.real(rows, 3),
				bytes = u64(sqlite3.integer(rows, 4)),
				disk_total = u64(sqlite3.integer(rows, 5)),
				disk_free = u64(sqlite3.integer(rows, 6)),
				updated = sqlite3.boolean(rows, 7),
				reread = u64(sqlite3.integer(rows, 8)),
				taken = sqlite3.integer(rows, 9),
				why = strings.clone(sqlite3.text(rows, 10), allocator),
				problem = strings.clone(sqlite3.text(rows, 11), allocator),
				firing = strings.clone(sqlite3.text(rows, 12), allocator),
			},
		)
	}
	if err = sqlite3.finish(&rows); err != nil {
		runs_destroy(found[:], allocator)
		return nil, err
	}
	return found[:], nil
}

// runs_destroy frees what runs returned.
runs_destroy :: proc(rs: []Run, allocator := context.allocator) {
	for r in rs {
		delete(r.place, allocator)
		delete(r.why, allocator)
		delete(r.problem, allocator)
		delete(r.firing, allocator)
	}
	delete(rs, allocator)
}

// last_run is the newest run of place, in allocator, and whether there is one.
last_run :: proc(st: ^Store, place: string, allocator := context.allocator) -> (Run, bool) {
	rs, err := runs(st, place, 1, context.temp_allocator)
	if err != nil || len(rs) == 0 {
		return {}, false
	}
	r := rs[0]
	r.place = strings.clone(r.place, allocator)
	r.why = strings.clone(r.why, allocator)
	r.problem = strings.clone(r.problem, allocator)
	r.firing = strings.clone(r.firing, allocator)
	return r, true
}

// raise keeps a as raised, and forgets the oldest past RAISED_KEPT.
raise :: proc(st: ^Store, a: Raised) -> sqlite3.Error {
	sqlite3.exec_args(
		st.db,
		`INSERT INTO raised(place, raised, kind, used_percent, free, total, days, grew,
				limit_crossed, problem)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.place,
		a.raised,
		a.kind,
		a.used_percent,
		i64(a.free),
		i64(a.total),
		a.days,
		i64(a.grew),
		a.limit,
		a.problem,
	) or_return
	return sqlite3.exec_args(
		st.db,
		`DELETE FROM raised WHERE id NOT IN
			(SELECT id FROM raised ORDER BY raised DESC, id DESC LIMIT ?)`,
		i64(RAISED_KEPT),
	)
}

// alerts is the alerts raised, newest first, at most limit, of place or of
// every place for "", in allocator.
alerts :: proc(
	st: ^Store,
	place := "",
	limit := RAISED_KEPT,
	allocator := context.allocator,
) -> (
	out: []Raised,
	err: sqlite3.Error,
) {
	rows := sqlite3.query(
		st.db,
		`SELECT id, place, raised, kind, used_percent, free, total, days, grew, limit_crossed,
				problem
			FROM raised WHERE ? = '' OR place = ? ORDER BY raised DESC, id DESC LIMIT ?`,
		place,
		place,
		i64(limit),
		allocator = context.temp_allocator,
	) or_return
	found := make([dynamic]Raised, allocator)
	for sqlite3.next(&rows) {
		append(
			&found,
			Raised {
				id = sqlite3.integer(rows, 0),
				place = strings.clone(sqlite3.text(rows, 1), allocator),
				raised = sqlite3.integer(rows, 2),
				kind = strings.clone(sqlite3.text(rows, 3), allocator),
				used_percent = sqlite3.real(rows, 4),
				free = u64(sqlite3.integer(rows, 5)),
				total = u64(sqlite3.integer(rows, 6)),
				days = sqlite3.real(rows, 7),
				grew = u64(sqlite3.integer(rows, 8)),
				limit = sqlite3.real(rows, 9),
				problem = strings.clone(sqlite3.text(rows, 10), allocator),
			},
		)
	}
	if err = sqlite3.finish(&rows); err != nil {
		alerts_destroy(found[:], allocator)
		return nil, err
	}
	return found[:], nil
}

// alerts_destroy frees what alerts returned.
alerts_destroy :: proc(rs: []Raised, allocator := context.allocator) {
	for r in rs {
		delete(r.place, allocator)
		delete(r.kind, allocator)
		delete(r.problem, allocator)
	}
	delete(rs, allocator)
}
