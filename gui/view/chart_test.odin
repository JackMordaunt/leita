package leita_view

import "core:math"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../command"
import "../query"

// The whole window with a small directory in it, to click and key at the charts.

@(private = "file")
Chart_Rig :: struct {
	m: Model,
	h: render.Headless,
}

// Nodes of the directory /top: docs (2) holding a.txt (3) and b.txt (4), then
// movie.mkv (5) and notes.txt (6), laid out as the host lays them.
@(private = "file")
DOCS, A_TXT, B_TXT, MOVIE, NOTES :: u32(2), u32(3), u32(4), u32(5), u32(6)

@(private = "file")
top_rings :: proc() -> query.Rings_Result {
	arcs := make([]query.Arc, 5, context.temp_allocator)
	arcs[0] = {
		node      = DOCS,
		name      = "docs",
		bytes     = 50,
		directory = true,
		depth     = 1,
		start     = 0,
		sweep     = 0.5,
		up        = -1,
		was       = -1,
	}
	arcs[1] = {
		node  = A_TXT,
		name  = "a.txt",
		bytes = 30,
		depth = 2,
		start = 0,
		sweep = 0.3,
		up    = 0,
		was   = -1,
	}
	arcs[2] = {
		node  = B_TXT,
		name  = "b.txt",
		bytes = 20,
		depth = 2,
		start = 0.3,
		sweep = 0.2,
		up    = 0,
		was   = -1,
	}
	arcs[3] = {
		node  = MOVIE,
		name  = "movie.mkv",
		bytes = 30,
		depth = 1,
		start = 0.5,
		sweep = 0.3,
		up    = -1,
		was   = -1,
	}
	arcs[4] = {
		node  = NOTES,
		name  = "notes.txt",
		bytes = 20,
		depth = 1,
		start = 0.8,
		sweep = 0.2,
		up    = -1,
		was   = -1,
	}
	crumbs := make([]query.Crumb, 1, context.temp_allocator)
	crumbs[0] = {1, "/top"}
	return {generation = 1, dir = 1, crumbs = crumbs, bytes = 100, was = -1, arcs = arcs}
}

@(private = "file")
chart_open :: proc(r: ^Chart_Rig, mode := Mode.Sunburst) {
	model_init(&r.m, "/top")
	r.m.settings_read = true
	r.m.mode = mode
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&r.h, view, &r.m, {1000, 700}, fonts)
	p := &r.h.p
	ui.probe_deliver(
		p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = "/top"},
	)
	ui.probe_deliver(p, query.Rings{generation = 1, dir = query.ROOT}, top_rings())
	ui.probe_frame(p)
	// The arcs and boxes grow into place.
	ui.probe_advance(p, 60, 1.0 / 60)
}

@(private = "file")
chart_close :: proc(r: ^Chart_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

// ring_point is the middle of the first ring's arc at turn t, in device space.
@(private = "file")
ring_point :: proc(r: ^Chart_Rig, depth: int, t: f32) -> ops.Point {
	bounds := ui.probe_bounds(&r.h.p, "Sunburst chart")
	b := burst_of(bounds.w)
	dist := b.hub + b.ring * (f32(depth) - 0.5)
	return {
		bounds.x + b.center.x + dist * math.cos(angle(t)),
		bounds.y + b.center.y + dist * math.sin(angle(t)),
	}
}

// press presses the left button at pos, with the count of a double click for
// clicks 2, and runs the frame that sees it, leaving what it sent to be read.
@(private = "file")
press :: proc(p: ^ui.Probe, pos: ops.Point, clicks: u8 = 1) {
	ui.router_push(&p.router, {kind = .Move, pos = pos})
	ui.router_push(&p.router, {kind = .Press, pos = pos, button = .Left, clicks = clicks})
	ui.probe_frame(p)
}

@(private = "file")
release :: proc(p: ^ui.Probe, pos: ops.Point) {
	ui.router_push(&p.router, {kind = .Release, pos = pos, button = .Left})
	ui.probe_frame(p)
}

// The menu of a file offers Open file, which sends the system's opener; a
// directory's offers Open, which makes it the one shown, and no Open file.
@(test)
a_files_menu_opens_it_in_its_application :: proc(t: ^testing.T) {
	r: Chart_Rig
	chart_open(&r)
	defer chart_close(&r)
	p := &r.h.p

	ui.probe_click_at(p, ring_point(&r, 1, 0.65), .Right)
	ui.probe_advance(p, 3, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(p, "Open file"), "the menu offers Open file")
	testing.expect(t, !ui.probe_tagged(p, "Open"), "and not Open, which is for a directory")
	testing.expect(t, ui.probe_click(p, "Open file"))
	opened, ok := sent(p, command.Open).?
	testing.expect(t, ok, "Open file sends the opener")
	testing.expect_value(t, opened.entry, command.Entry{generation = 1, node = MOVIE})

	ui.probe_advance(p, 3, 1.0 / 60)
	ui.probe_click_at(p, ring_point(&r, 1, 0.25), .Right)
	ui.probe_advance(p, 3, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(p, "Open"), "a directory's menu offers Open")
	testing.expect(t, !ui.probe_tagged(p, "Open file"), "and not Open file")
	testing.expect(t, ui.probe_click(p, "Open"))
	testing.expect_value(t, r.m.dir, DOCS)
	testing.expect(t, sent(p, command.Open) == nil, "Open only navigates")
}

// A double click on a file's arc opens it in its application; on a directory's
// it opens the directory in the chart, as a click does.
@(test)
a_double_click_on_a_sunburst_file_opens_it :: proc(t: ^testing.T) {
	r: Chart_Rig
	chart_open(&r)
	defer chart_close(&r)
	p := &r.h.p

	at := ring_point(&r, 1, 0.9)
	press(p, at)
	testing.expect(t, sent(p, command.Open) == nil, "one click opens nothing")
	release(p, at)
	press(p, at, 2)
	opened, ok := sent(p, command.Open).?
	testing.expect(t, ok, "the double click opens the file")
	testing.expect_value(t, opened.entry.node, NOTES)
	release(p, at)
}

// In the treemap a click on a file takes the directory holding it once a second
// click is out of time, and a double click opens the file instead.
@(test)
a_double_click_on_a_treemap_file_opens_it :: proc(t: ^testing.T) {
	r: Chart_Rig
	chart_open(&r, .Treemap)
	defer chart_close(&r)
	p := &r.h.p

	// The middle of docs' box is on one of its two files.
	at, _ := ui.probe_center(p, "box docs")
	press(p, at)
	release(p, at)
	testing.expect_value(t, r.m.dir, query.ROOT)
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect_value(t, r.m.dir, query.ROOT) // still waiting for a second click
	ui.probe_advance(p, 40, 1.0 / 60)
	testing.expect_value(t, r.m.dir, DOCS)

	r.m.dir = query.ROOT
	ui.probe_advance(p, 3, 1.0 / 60)
	press(p, at)
	release(p, at)
	press(p, at, 2)
	opened, ok := sent(p, command.Open).?
	testing.expect(t, ok, "the double click opens the file")
	testing.expect(t, opened.entry.node == A_TXT || opened.entry.node == B_TXT, "a file of docs")
	release(p, at)
	ui.probe_advance(p, 60, 1.0 / 60)
	testing.expect_value(t, r.m.dir, query.ROOT)
}
