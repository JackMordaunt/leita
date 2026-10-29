package leita_view

import "core:strings"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../query"

// The status strip in a probe, the host's progress made up by hand.

@(private = "file")
Status_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
status_open :: proc(s: ^Status_Rig) {
	model_init(&s.m, "/top")
	s.m.settings_read = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&s.h, view, &s.m, {1000, 700}, fonts)
}

@(private = "file")
status_close :: proc(s: ^Status_Rig) {
	render.headless_destroy(&s.h)
	model_destroy(&s.m)
}

// deliver delivers prog as the scan's progress and runs frames until it has
// laid out: a row lays out what it holds by the sizes they had the frame before.
@(private = "file")
deliver :: proc(s: ^Status_Rig, prog: query.Progress_Result) {
	ui.probe_deliver(&s.h.p, query.Progress{}, prog)
	ui.probe_advance(&s.h.p, 3, 1.0 / 60)
}

// The chart's switch is as far down the window whatever the status says: a scan
// with nothing to say, one finished with how it read its place, one refused a
// folder mid-scan, and one with two warnings at once.
@(test)
the_chart_holds_still_as_the_status_changes :: proc(t: ^testing.T) {
	s: Status_Rig
	status_open(&s)
	defer status_close(&s)
	p := &s.h.p
	base := query.Progress_Result{generation = 1, target = "/top", nodes = 10, bytes = 1024}

	scanning := base
	scanning.state = .Scanning
	deliver(&s, scanning)
	was := ui.probe_bounds(p, "Sunburst")
	testing.expect(t, was.h > 0, "the chart's switch is drawn")

	updated := base
	updated.state = .Done
	updated.kept, updated.updated, updated.reread, updated.since = true, true, 3, 1_700_000_000
	deliver(&s, updated)
	testing.expect(t, ui.probe_tagged(p, "\u00A0· read again where changed"), "how the scan read is on the counters line")
	// It follows the counters as one more of them, with no wider gap.
	counted, _ := last_tag(p, "10 items")
	read, _ := last_tag(p, "\u00A0· read again")
	testing.expect(t, counted.w > 0 && read.w > 0, "both are drawn")
	testing.expect_value(t, read.x, counted.x + counted.w)
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst"), was)

	refused := scanning
	refused.unread = 3
	deliver(&s, refused)
	testing.expect(t, ui.probe_tagged(p, "3 folders could not be read."), "the refused folders are counted")
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst"), was)

	both := updated
	both.updated, both.why = false, "too much has happened on the volume"
	both.unread, both.slow = 2, true
	deliver(&s, both)
	testing.expect(t, ui.probe_tagged(p, "2 folders could not be read."), "the most pressing message shows")
	testing.expect(t, ui.probe_tagged(p, "+2 more"), "the rest are counted")
	testing.expect(t, ui.probe_tagged(p, "\u00A0· read whole"), "a whole read is on the counters line")
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst"), was)

	deliver(&s, scanning)
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst"), was)
}

// A failed scan's banner stands where the chart was, not above it.
@(test)
a_failed_scan_shows_its_banner_in_the_charts_place :: proc(t: ^testing.T) {
	s: Status_Rig
	status_open(&s)
	defer status_close(&s)
	p := &s.h.p
	deliver(&s, {generation = 1, state = .Scanning, target = "/top"})
	testing.expect(t, ui.probe_bounds(p, "Sunburst").h > 0, "the chart's switch is drawn")
	deliver(&s, {generation = 1, state = .Failed, target = "/top", problem = "no such directory"})
	testing.expect(t, ui.probe_tagged(p, "no such directory"), "the banner says why")
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst").h, 0)
}

// partial_rings is /top with two folders, docs and cache, the second left short
// by the walk, as the host answers for a tree that did not finish.
@(private = "file")
partial_rings :: proc(incomplete: bool) -> query.Rings_Result {
	arcs := make([]query.Arc, 2, context.temp_allocator)
	arcs[0] = {
		node      = 2,
		name      = "docs",
		bytes     = 60,
		directory = true,
		depth     = 1,
		sweep     = 0.6,
		up        = -1,
		was       = -1,
	}
	arcs[1] = {
		node       = 3,
		name       = "cache",
		bytes      = 40,
		directory  = true,
		depth      = 1,
		start      = 0.6,
		sweep      = 0.4,
		up         = -1,
		was        = -1,
		incomplete = true,
	}
	crumbs := make([]query.Crumb, 1, context.temp_allocator)
	crumbs[0] = {1, "/top"}
	return {
		generation = 1,
		dir = 1,
		crumbs = crumbs,
		bytes = 100,
		was = -1,
		arcs = arcs,
		incomplete = incomplete,
	}
}

@(private = "file")
deliver_rings :: proc(s: ^Status_Rig, r: query.Rings_Result) {
	ui.probe_deliver(&s.h.p, query.Rings{generation = 1, dir = query.ROOT}, r)
	ui.probe_advance(&s.h.p, 60, 1.0 / 60)
}

// A scan that failed after it read something keeps the chart it grew, and says
// why in the status instead of a banner in the chart's place.
@(test)
a_failed_scan_that_grew_keeps_its_chart :: proc(t: ^testing.T) {
	s: Status_Rig
	status_open(&s)
	defer status_close(&s)
	p := &s.h.p
	deliver(
		&s,
		{
			generation = 1,
			state = .Failed,
			target = "/top",
			problem = "out of memory",
			nodes = 40,
			bytes = 100,
		},
	)
	deliver_rings(&s, partial_rings(true))
	testing.expect(t, ui.probe_bounds(p, "Sunburst").h > 0, "the chart's switch is drawn")
	testing.expect(t, ui.probe_bounds(p, "Sunburst chart").w > 0, "and the chart")
	testing.expect(
		t,
		ui.probe_tagged(p, "The scan failed, so the chart is incomplete: out of memory"),
		"the status says why",
	)
	testing.expect(t, !ui.probe_tagged(p, "The scan failed"), "and no banner stands in its place")
}

// A stopped scan's chart is marked as short: the hub, and the directory the walk
// left, are outlined and tagged; one that finished carries none; and the chart's
// tree and the status say so.
@(test)
a_stopped_scans_chart_is_marked_incomplete :: proc(t: ^testing.T) {
	s: Status_Rig
	status_open(&s)
	defer status_close(&s)
	p := &s.h.p

	deliver(&s, {generation = 1, state = .Stopped, target = "/top", nodes = 40, bytes = 100})
	deliver_rings(&s, partial_rings(true))
	testing.expect(t, ui.probe_tagged(p, "incomplete cache"), "the folder the walk left")
	testing.expect(t, ui.probe_tagged(p, "incomplete top"), "the hub")
	testing.expect(t, !ui.probe_tagged(p, "incomplete docs"), "and not the one it read")
	said := ui.probe_semantics(p, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(said, `tree item "cache, 40 B, 40.0% of top, incomplete"`),
		said,
	)
	testing.expect(t, strings.contains(said, "of top, 100 B, 2 items, incomplete"), said)
	testing.expect(
		t,
		ui.probe_tagged(
			p,
			"The scan was stopped, so the chart is incomplete. Outlined folders were not read in full.",
		),
		"the status says so",
	)

	s.m.mode = .Treemap
	ui.probe_advance(p, 60, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(p, "incomplete cache"), "the folder's box")
	testing.expect(t, ui.probe_tagged(p, "incomplete top"), "and the frame")

	// A finished scan with nothing short has no mark.
	deliver(&s, {generation = 1, state = .Done, target = "/top", nodes = 40, bytes = 100})
	clean := partial_rings(false)
	clean.arcs[1].incomplete = false
	deliver_rings(&s, clean)
	testing.expect(t, !ui.probe_tagged(p, "incomplete cache"), "nothing is outlined")
	testing.expect(t, !ui.probe_tagged(p, "incomplete top"), "the frame is not")
}

// A full data volume is a persistent storage problem, not a failed scan or
// an action toast. It is visible before the first scan and survives actions.
@(test)
a_storage_warning_survives_scans_and_action_notices :: proc(t: ^testing.T) {
	s: Status_Rig
	status_open(&s)
	defer status_close(&s)
	p := &s.h.p
	warning := "Settings: storage is full; existing values can be read."
	deliver(&s, {storage_problem = warning})
	testing.expect(t, ui.probe_tagged(p, "Settings or history cannot be saved"))
	testing.expect(t, ui.probe_tagged(p, warning))
	deliver(&s, {generation = 1, state = .Done, target = "/top", storage_problem = warning, notice = {id = 1, text = "Another action finished"}})
	testing.expect(t, ui.probe_tagged(p, warning), "an action does not hide the storage problem")
	testing.expect(t, ui.probe_tagged(p, "Done"), "the scan still completes")
	deliver(&s, {generation = 1, state = .Done, target = "/top"})
	testing.expect(t, !ui.probe_tagged(p, "Settings or history cannot be saved"), "the warning clears when persistence recovers")
}
