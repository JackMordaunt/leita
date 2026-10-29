package leita_cli

import "core:fmt"
import "core:time"

import "jm:timefmt"

import "../history"
import "../human"
import "../report"
import "../scan"
import "../survey"

/*
The scans the command line keeps, in the store the window keeps its own in, so
each place has one timeline whichever binary scanned it. A finished scan is
compared with the last kept of the same place, then kept itself.

The store is shared with a window that may be writing to it at the same moment:
history opens it in WAL mode with a busy timeout, and a store that is still busy
past that, or cannot be opened at all, leaves this scan unkept rather than
failing it. A readable earlier scan remains available for comparison even
when the new scan cannot be saved.
*/

// Kept is what history did with one scan.
Kept :: struct {
	place:    string, // what the scan is kept under, "" when history is off
	previous: Maybe(report.Snapshot), // the last scan kept of the same place
	bytes:    u64, // what that scan's top held
	problem:  string, // why history is unavailable, "" when it is not
}

/*
keep_scan compares the finished scan in t with the last kept of the same place in
the store at path, and keeps it with the disk it was on, for "" doing neither. What it reads, and what
any error it meets says, is in the temp allocator.
*/
keep_scan :: proc(
	path: string,
	t: ^scan.Tree,
	roll: ^survey.Rollup,
	engine: scan.Engine,
	disk := history.Disk{},
) -> (
	k: Kept,
) {
	top := t.root
	if path == "" || top >= roll.seen || .Used not_in scan.node_flags(scan.node(t, top)) {
		return
	}
	// The store makes its errors in the allocator it was opened in.
	context.allocator = context.temp_allocator
	st: history.Store
	if err := history.open(&st, path); err != nil {
		k.problem = history.describe(err)
		return
	}
	defer history.close(&st)
	k.place = history.place_of(t, top, engine)

	if snap, found := history.latest(&st, k.place); found {
		if entries, err := history.load(&st, snap.id); err == nil {
			k.previous = report.Snapshot{time.unix(snap.taken, 0), entries}
			k.bytes = snap.bytes
		}
	}
	if _, err := history.keep(&st, k.place, t, roll, top, t.nodes_done, disk); err != nil {
		k.problem = history.describe(err)
	}
	return
}

/*
say_kept says what history did: on the terminal, unless quiet, the change since
the last scan kept of the same place, or that this was the first; and on standard
error, why history was unavailable, if it was. compare is whether Pro runs.
When it does not, an earlier scan is not described: the scan is still kept,
and a note says so.
*/
say_kept :: proc(k: Kept, now: u64, quiet: bool, compare: bool) {
	if k.problem != "" {
		say_note("this scan could not be saved in history: %s", k.problem)
	}
	prev, compared := k.previous.?
	if k.place == "" || (!compared && k.problem != "") {
		return
	}
	if compared && !compare {
		if k.problem == "" {
			say_note(
				"comparing with earlier scans needs a licence now the 30-day Pro evaluation has ended; this scan is still kept",
			)
		}
		return
	}
	if quiet {
		return
	}
	fmt.println()
	if !compared {
		label("history", "the first scan of this place kept")
		return
	}
	then := timefmt.local(prev.taken, "%Y-%m-%d %H:%M", context.temp_allocator)
	switch {
	case now == k.bytes:
		label("history", "unchanged since %s", then)
	case now > k.bytes:
		label(
			"history",
			"up %s since %s, from %s",
			human.bytes(now - k.bytes),
			then,
			human.bytes(k.bytes),
		)
	case:
		label(
			"history",
			"down %s since %s, from %s",
			human.bytes(k.bytes - now),
			then,
			human.bytes(k.bytes),
		)
	}
}
