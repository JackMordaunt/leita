package main

import "core:fmt"
import "core:time"

import "alert"
import "gui/files"
import "history"
import "human"
import "scan"
import "schedule"
import "survey"

/*
--keep keeps a scan in the history the window keeps its own in, the same way it
does (history.collect), with the disk it was on, then checks the alerts asked for
against that disk and against the forecast drawn from the scans of the same place
before it. A fired alert goes to the webhook when there is one, and otherwise
fails the run with schedule.EXIT_ALERT, so whatever ran it sees.

Each kept scan locks its place beside the history first; a run that finds it held
says so and succeeds, rather than scanning the place twice at once.
*/

// Keeper is a kept scan's hold on the history: the store open, and the lock on
// its place.
Keeper :: struct {
	path:   string,
	store:  history.Store,
	opened: bool,
	lock:   history.Lock,
}

// keep_problem says what is wrong with how opt asks to keep a scan, or "".
keep_problem :: proc(opt: Options) -> string {
	if !opt.keep &&
	   (opt.history != "" ||
			   opt.alert_free != 0 ||
			   opt.alert_full_days != 0 ||
			   opt.webhook != "") {
		return "--history, --alert-free, --alert-full-days and --webhook need --keep"
	}
	if opt.keep && opt.live {
		return "--keep keeps a scan read whole, not --live"
	}
	if opt.alert_free < 0 || opt.alert_free > 100 {
		return "--alert-free is a percent, from 0 to 100"
	}
	if opt.alert_full_days < 0 {
		return "--alert-full-days is a count of days"
	}
	return ""
}

// keeper_open opens the history and locks target's place in it. When it does
// not, the run ends with code: 0 when another run holds the place.
keeper_open :: proc(k: ^Keeper, opt: Options, target: scan.Target) -> (code: int, ok: bool) {
	k.path = opt.history if opt.history != "" else history.default_path(context.temp_allocator)
	if k.path == "" {
		fmt.eprintln("error: there is nowhere to keep the history: give it with --history")
		return schedule.EXIT_FAILED, false
	}
	if err := history.open(&k.store, k.path); err != nil {
		fmt.eprintfln("error: cannot open the history %s: %v", k.path, err)
		return schedule.EXIT_FAILED, false
	}
	k.opened = true
	place := scan.location(target, context.temp_allocator)
	taken: history.Lock_Result
	k.lock, taken = history.lock(history.lock_path(k.path, place, context.temp_allocator))
	switch taken {
	case .Taken:
	case .Held:
		fmt.printfln("sonar: a kept scan of %s is already running", place)
		return schedule.EXIT_OK, false
	case .Failed:
		fmt.eprintfln("error: cannot lock %s beside the history", place)
		return schedule.EXIT_FAILED, false
	}
	return 0, true
}

// keeper_close lets the lock go and closes the history.
keeper_close :: proc(k: ^Keeper) {
	history.unlock(&k.lock)
	if k.opened {
		history.close(&k.store)
	}
	k^ = {}
}

// keep keeps the scan read into t and folded into roll, checks the alerts, and
// returns the code to exit with.
keep :: proc(
	k: ^Keeper,
	opt: Options,
	target: scan.Target,
	t: ^scan.Tree,
	roll: ^survey.Rollup,
) -> int {
	top := t.root
	if top >= u32(len(roll.totals)) || .Used not_in scan.node_flags(scan.node(t, top)) {
		fmt.eprintln("error: the scan found nothing to keep")
		return schedule.EXIT_FAILED
	}
	place := scan.path(t, top, context.temp_allocator)
	disk := measure(target)
	now := time.now()
	id, err := history.save(
		&k.store,
		place,
		time.time_to_unix(now),
		roll.totals[top],
		t.nodes_done,
		history.collect(t, roll, top),
		disk,
	)
	if err != nil {
		fmt.eprintfln("error: cannot keep the scan in %s: %v", k.path, err)
		return schedule.EXIT_FAILED
	}
	snapshots, _ := history.list(&k.store, place)
	reading := alert.reading(disk, snapshots)

	fmt.println()
	fmt.printf(
		"kept       %s as snapshot %d: %s in %s items",
		place,
		id,
		human.bytes(roll.totals[top]),
		human.count(t.nodes_done),
	)
	if disk.total > 0 {
		fmt.printf(
			"; disk %.1f%% free, %s of %s",
			alert.free_percent(disk),
			human.bytes(disk.free),
			human.bytes(disk.total),
		)
	}
	if days, ok := reading.forecast.?; ok {
		fmt.printf("; full in %.0f days at this rate", days)
	}
	fmt.println()

	rules := alert.Rules{opt.alert_free, f64(opt.alert_full_days)}
	if rules.free_below > 0 && disk.total == 0 {
		fmt.eprintfln(
			"note: --alert-free goes unchecked: %s is not on a mounted disk to measure",
			place,
		)
	}
	fired := alert.evaluate(rules, reading)
	if fired == {} {
		return schedule.EXIT_OK
	}
	host := alert.host_name()
	r := alert.report(host, place, now, reading, fired)
	fmt.eprintfln("alert: %s", r.text)
	if opt.webhook == "" {
		return schedule.EXIT_ALERT
	}
	if msg := alert.deliver(opt.webhook, r); msg != "" {
		fmt.eprintfln("error: the webhook did not take the alert: %s", msg)
		return schedule.EXIT_FAILED
	}
	return schedule.EXIT_OK
}

// measure is the size of the filesystem target is on and what of it is free, as
// the window measures it: only a mounted target has one to ask about, since a raw
// device or an image would answer for whatever holds the device node or the file.
measure :: proc(target: scan.Target) -> history.Disk {
	if target.mount == "" {
		return {}
	}
	total, free, ok := files.space(scan.location(target, context.temp_allocator))
	if !ok {
		return {}
	}
	return {total, free}
}
