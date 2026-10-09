package main

import "core:fmt"
import "core:time"

import "jm:sqlite3"
import "jm:timefmt"

import "history"
import "human"
import "report"
import "scan"
import "survey"

/*
The scans the command line keeps, in the store the window keeps its own in, so
each place has one timeline whichever binary scanned it. A finished scan is
compared with the last kept of the same place, then kept itself.

The store is shared with a window that may be writing to it at the same moment:
history opens it in WAL mode with a busy timeout, and a store that is still busy
past that, or cannot be opened at all, leaves this scan unkept and uncompared
rather than failing it.
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
the store at path, and keeps it, for "" doing neither. What it reads, and what
any error it meets says, is in the temp allocator.
*/
keep_scan :: proc(
	path: string,
	t: ^scan.Tree,
	roll: ^survey.Rollup,
	engine: scan.Engine,
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
		k.problem = why(err)
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
	if _, err := history.keep(&st, k.place, t, roll, top, t.nodes_done); err != nil {
		k.problem = why(err)
	}
	return
}

// why is what err says went wrong.
@(private)
why :: proc(err: sqlite3.Error) -> string {
	f := err.? or_else {}
	return f.text if f.text != "" else fmt.tprint(f.code)
}

/*
say_kept says what history did: on the terminal, unless quiet, the change since
the last scan kept of the same place, or that this was the first; and on standard
error, why history was unavailable, if it was.
*/
say_kept :: proc(k: Kept, now: u64, quiet: bool) {
	if k.problem != "" {
		fmt.eprintfln("note: history unavailable, so this scan is not kept: %s", k.problem)
	}
	prev, compared := k.previous.?
	if quiet || k.place == "" || (!compared && k.problem != "") {
		return
	}
	fmt.println()
	if !compared {
		fmt.println("history    the first scan of this place kept")
		return
	}
	then := timefmt.local(prev.taken, "%Y-%m-%d %H:%M", context.temp_allocator)
	switch {
	case now == k.bytes:
		fmt.printfln("history    unchanged since %s", then)
	case now > k.bytes:
		fmt.printfln(
			"history    up %s since %s, from %s",
			human.bytes(now - k.bytes),
			then,
			human.bytes(k.bytes),
		)
	case:
		fmt.printfln(
			"history    down %s since %s, from %s",
			human.bytes(k.bytes - now),
			then,
			human.bytes(k.bytes),
		)
	}
}
