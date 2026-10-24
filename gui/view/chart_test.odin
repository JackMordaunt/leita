package leita_view

import "core:math"
import "core:strings"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import tok "jm:ui/primer/tokens"
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
top_rings :: proc(movie := "movie.mkv") -> query.Rings_Result {
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
		name  = movie,
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
chart_open :: proc(r: ^Chart_Rig, mode := Mode.Sunburst, movie := "movie.mkv") {
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
	ui.probe_deliver(p, query.Rings{generation = 1, dir = query.ROOT}, top_rings(movie))
	ui.probe_frame(p)
	// The arcs and boxes grow into place.
	ui.probe_advance(p, 60, 1.0 / 60)
}

@(private = "file")
chart_close :: proc(r: ^Chart_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

// A largest file's path starts under its name's icon, where the name's button
// starts its contents, rather than out at the button's edge.
@(test)
a_largest_files_path_lines_up_with_its_icon :: proc(t: ^testing.T) {
	r: Chart_Rig
	chart_open(&r)
	defer chart_close(&r)
	p := &r.h.p
	files := []query.File{{node = MOVIE, parent = 1, path = "/top/clips/take.mkv", bytes = 30, was = -1}}
	ui.probe_deliver(p, query.Largest{generation = 1}, query.Largest_Result{files = files})
	ui.probe_advance(p, 5, 1.0 / 60)
	name := ui.probe_bounds(p, "take.mkv")
	path := ui.probe_bounds(p, "/top/clips/take.mkv")
	testing.expect(t, name.w > 0 && path.w > 0, "the name and its path are drawn")
	testing.expect_value(t, path.x, name.x + tok.CONTROL_SMALL_PADDING_INLINE_CONDENSED)
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

// tab_to_chart tabs through the window until the area tagged name holds focus,
// which for the sunburst is the first tag its area was given.
@(private = "file")
tab_to_chart :: proc(r: ^Chart_Rig, name: string) -> bool {
	p := &r.h.p
	for _ in 0 ..< 40 {
		if ui.probe_focus_name(p) == name {
			return true
		}
		ui.probe_key(p, .Tab)
	}
	return false
}

// With the chart focused, the arrows pick one arc after another: Right and Left
// across a ring, largest first, Down into a directory and Up out of it, and each
// keeps the chart's tree for a screen reader in step.
@(test)
the_arrows_move_a_pick_through_the_sunburst :: proc(t: ^testing.T) {
	r: Chart_Rig
	chart_open(&r)
	defer chart_close(&r)
	p := &r.h.p
	testing.expect(t, tab_to_chart(&r, "arc docs"), "Tab reaches the chart")

	step :: proc(r: ^Chart_Rig, key: ui.Key, mods: ui.Mods = {}) -> u32 {
		ui.probe_key(&r.h.p, key, mods)
		ui.probe_frame(&r.h.p) // the one the key asked for
		return r.m.chart_pick
	}
	testing.expect_value(t, step(&r, .Right), DOCS) // from nothing, the largest
	testing.expect_value(t, step(&r, .Right), MOVIE)
	testing.expect_value(t, step(&r, .Right), NOTES)
	testing.expect_value(t, step(&r, .Right), NOTES) // the last stays
	testing.expect_value(t, step(&r, .Left), MOVIE)
	testing.expect_value(t, step(&r, .Down), MOVIE) // a file has nothing under it
	testing.expect_value(t, step(&r, .Left), DOCS)
	testing.expect_value(t, step(&r, .Left), DOCS)
	testing.expect_value(t, step(&r, .Down), A_TXT)
	testing.expect(t, r.m.said_open[DOCS], "going down opens the folder in the chart's tree")
	said := ui.probe_semantics(p, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(said, `tree item "a.txt, 30 B, 30.0% of top" level 2 selected at`),
		said,
	)
	testing.expect_value(t, step(&r, .Right), B_TXT)
	testing.expect_value(t, step(&r, .Right), B_TXT)
	testing.expect_value(t, step(&r, .Up), DOCS)
	testing.expect(t, !r.m.said_open[DOCS], "going up closes it")
	testing.expect_value(t, step(&r, .Up), 0)
	testing.expect_value(t, step(&r, .Right), DOCS)
	testing.expect_value(t, step(&r, .Escape), 0)

	// Alt with an arrow is the window's history, not the chart's.
	testing.expect_value(t, step(&r, .Right, {.Alt}), 0)
}

// Enter opens the pick: a directory becomes the one shown, a file opens in its
// application; and Up with nothing picked goes to the directory above.
@(test)
enter_opens_the_pick_and_up_without_one_leaves_the_directory :: proc(t: ^testing.T) {
	r: Chart_Rig
	chart_open(&r)
	defer chart_close(&r)
	p := &r.h.p
	testing.expect(t, tab_to_chart(&r, "arc docs"), "Tab reaches the chart")

	ui.probe_key(p, .Right)
	ui.probe_key(p, .Right)
	ui.probe_key(p, .Enter)
	opened, ok := sent(p, command.Open).?
	testing.expect(t, ok, "Enter on a file opens it")
	testing.expect_value(t, opened.entry.node, MOVIE)
	testing.expect_value(t, r.m.dir, query.ROOT)

	ui.probe_key(p, .Left)
	ui.probe_key(p, .Enter)
	testing.expect(
		t,
		sent(p, command.Open) == nil,
		"Enter on a directory only opens it in the chart",
	)
	testing.expect_value(t, r.m.dir, DOCS)
	testing.expect_value(t, r.m.chart_pick, 0)

	// Inside docs, with nothing picked, Up goes to the directory above.
	crumbs := []query.Crumb{{1, "/top"}, {DOCS, "docs"}}
	inside := query.Rings_Result {
		generation = 1,
		dir        = DOCS,
		crumbs     = crumbs,
		bytes      = 50,
		was        = -1,
	}
	ui.probe_deliver(p, query.Rings{generation = 1, dir = DOCS}, inside)
	ui.probe_advance(p, 3, 1.0 / 60)
	ui.probe_key(p, .Up)
	testing.expect_value(t, r.m.dir, u32(1))
}

// The treemap and the icicle take the same keys.
@(test)
the_treemap_and_the_icicle_take_the_same_keys :: proc(t: ^testing.T) {
	for mode in ([?]Mode{.Treemap, .Icicle}) {
		r: Chart_Rig
		chart_open(&r, mode)
		defer chart_close(&r)
		name := "Treemap chart" if mode == .Treemap else "Icicle chart"
		testing.expect(t, tab_to_chart(&r, name), "Tab reaches the chart")
		ui.probe_key(&r.h.p, .Right)
		ui.probe_key(&r.h.p, .Right)
		testing.expect_value(t, r.m.chart_pick, MOVIE)
		ui.probe_key(&r.h.p, .Escape)
		testing.expect_value(t, r.m.chart_pick, 0)
	}
}

// A name with a line break and a right-to-left override in it, as a disk allows,
// is drawn as pictures in menu and dialog prose. The bounded editor retains
// the real bytes, and accepting them unchanged renames nothing.
@(test)
a_name_with_a_newline_stays_on_one_line_in_the_dialogs :: proc(t: ^testing.T) {
	r: Chart_Rig
	chart_open(&r, movie = "evil\nname\u202e.txt")
	defer chart_close(&r)
	p := &r.h.p
	// A semantics report writes a control or an unprintable as an escape, so a
	// name that broke a line would show as \n.
	safe := `evil\u240aname\ufffd.txt`

	ui.probe_click_at(p, ring_point(&r, 1, 0.65), .Right)
	ui.probe_advance(p, 3, 1.0 / 60)
	said := ui.probe_semantics(p, context.temp_allocator)
	testing.expect(t, strings.contains(said, safe), said)
	testing.expect(t, !strings.contains(said, `menu "Actions for evil\nname`), "the menu name does not split a line")

	testing.expect(t, ui.probe_click(p, "Trash"))
	ui.probe_advance(p, 3, 1.0 / 60)
	said = ui.probe_semantics(p, context.temp_allocator)
	testing.expect(t, strings.contains(said, safe), said)
	testing.expect(t, !strings.contains(said, `\nname`), "the Trash question stays whole")
	testing.expect(t, !strings.contains(said, `\u202e`), "and has no override")
	r.m.trash_open = false
	ui.probe_advance(p, 3, 1.0 / 60)

	ui.probe_click_at(p, ring_point(&r, 1, 0.65), .Right)
	ui.probe_advance(p, 3, 1.0 / 60)
	testing.expect(t, ui.probe_click(p, "Rename"))
	ui.probe_advance(p, 3, 1.0 / 60)
	said = ui.probe_semantics(p, context.temp_allocator)
	testing.expect(t, strings.contains(said, safe), said)
	testing.expect_value(t, ui.text_string(&r.m.rename), "evil\nname\u202e.txt")
	ui.probe_key(p, .Enter)
	testing.expect(t, sent(p, command.Rename) == nil, "an unedited raw name renames nothing")
	r.m.rename_open = true
	ui.text_set(&r.m.rename, " evil\nname\u202e.md ")
	ui.probe_advance(p, 3, 1.0 / 60)
	ui.probe_key(p, .Enter)
	renamed, ok := sent(p, command.Rename).?
	testing.expect(t, ok, "the edited name sends a rename")
	if ok {
		testing.expect_value(t, command.text_of(&renamed.name), " evil\nname\u202e.md ")
	}
}

// The location bar's steps, the rows of the listing and the largest files, and
// the info line over the chart draw a name as pictures too.
@(test)
a_name_with_a_newline_is_safe_in_the_bar_the_lists_and_the_info_line :: proc(t: ^testing.T) {
	r: Chart_Rig
	chart_open(&r, movie = "evil\nname.txt")
	defer chart_close(&r)
	p := &r.h.p
	bad, safe := "evil\nname.txt", "evil\u240Aname.txt"

	crumbs := []query.Crumb{{1, "/top/odd\ndir"}}
	rings := top_rings("movie.mkv")
	rings.crumbs = crumbs
	ui.probe_deliver(p, query.Rings{generation = 1, dir = query.ROOT}, rings)
	entries := []query.Entry{{node = MOVIE, name = bad, bytes = 30, was = -1}}
	ui.probe_deliver(
		p,
		query.Listing{generation = 1, dir = query.ROOT},
		query.Listing_Result {
			generation = 1,
			dir = 1,
			crumbs = crumbs,
			bytes = 30,
			was = -1,
			entries = entries,
		},
	)
	files := []query.File {
		{node = MOVIE, parent = 1, path = "/top/odd\ndir/evil\nname.txt", bytes = 30, was = -1},
	}
	ui.probe_deliver(p, query.Largest{generation = 1}, query.Largest_Result{files = files})
	ui.probe_advance(p, 5, 1.0 / 60)

	testing.expect(t, ui.probe_tagged(p, "odd\u240Adir"), "the bar's step")
	said := ui.probe_semantics(p, context.temp_allocator)
	testing.expect(t, strings.contains(said, `button "evil\u240aname.txt"`), said)
	testing.expect(t, strings.contains(said, `evil\u240aname.txt`), "the lists")
	testing.expect(t, !strings.contains(said, `button "evil\nname`), "list buttons stay on one line")

	// Hover the list's safe name and then the largest file's safe path.
	for label, i in ([2]string{safe, "/top/odd\u240Adir/evil\u240Aname.txt"}) {
		b := ui.probe_bounds(p, label)
		testing.expect(t, b.w > 0, "the tooltip anchor is drawn")
		ui.probe_move(p, b.x + b.w / 2, b.y + b.h / 2)
		ui.probe_advance(p, 90, 1.0 / 60)
		raw := bad if i == 0 else files[0].path
		testing.expect(t, ui.probe_tagged(p, raw), "the tooltip exposes the raw name")
		ui.probe_move(p, 0, 0)
		ui.probe_advance(p, 3, 1.0 / 60)
	}

	// The info line over the chart, with the pointer on the arc.
	ui.probe_move(p, ring_point(&r, 1, 0.65).x, ring_point(&r, 1, 0.65).y)
	ui.probe_advance(p, 3, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(p, safe), "the info line")
}

// A slow frame can collect several keys. Each one starts at the pick left by the
// previous key, including Enter and Escape, rather than the frame's first pick.
@(test)
keys_in_one_frame_move_and_open_the_current_pick :: proc(t: ^testing.T) {
	for mode in ([?]Mode{.Sunburst, .Treemap, .Icicle}) {
		r: Chart_Rig
		chart_open(&r, mode)
		defer chart_close(&r)
		name := "arc docs" if mode == .Sunburst else "Treemap chart" if mode == .Treemap else "Icicle chart"
		testing.expect(t, tab_to_chart(&r, name), "Tab reaches the chart")
		p := &r.h.p

		ui.router_push(&p.router, {kind = .Key, key = .Right})
		ui.router_push(&p.router, {kind = .Key, key = .Right})
		ui.probe_frame(p)
		ui.probe_frame(p)
		testing.expect_value(t, r.m.chart_pick, MOVIE)

		ui.router_push(&p.router, {kind = .Key, key = .Right})
		ui.router_push(&p.router, {kind = .Key, key = .Enter})
		ui.probe_frame(p)
		opened, ok := sent(p, command.Open).?
		testing.expect(t, ok, "Enter opens the entry the preceding arrow picked")
		testing.expect_value(t, opened.entry.node, NOTES)
		ui.probe_frame(p)

		ui.router_push(&p.router, {kind = .Key, key = .Escape})
		ui.router_push(&p.router, {kind = .Key, key = .Right})
		ui.probe_frame(p)
		ui.probe_frame(p)
		testing.expect_value(t, r.m.chart_pick, DOCS)
	}
}

// Keyboard selection holds the info line steady while its raw-name tooltip is
// hovered, in each chart. Explicit lines and very long names have a finite preview.
@(test)
chart_info_tooltips_keep_the_raw_name_in_a_bounded_preview :: proc(t: ^testing.T) {
	for mode in ([?]Mode{.Sunburst, .Treemap, .Icicle}) {
		r: Chart_Rig
		chart_open(&r, mode, "evil\nname.txt")
		defer chart_close(&r)
		p := &r.h.p
		if mode == .Sunburst {
			at := ring_point(&r, 1, 0.65)
			ui.probe_move(p, at.x, at.y)
		} else {
			label := "box evil\u240Aname.txt" if mode == .Treemap else "bar evil\u240Aname.txt"
			b := ui.probe_bounds(p, label)
			testing.expect(t, b.w > 0, "the chart entry is drawn")
			ui.probe_move(p, b.x + b.w / 2, b.y + b.h / 2)
		}
		ui.probe_advance(p, 90, 1.0 / 60)
		testing.expect(t, ui.probe_tagged(p, "evil\nname.txt"), "hovering a chart entry exposes its raw name")
		ui.probe_move(p, 0, 0)
		ui.probe_advance(p, 3, 1.0 / 60)
		rings := top_rings("evil\nname.txt")
		set_chart_pick(&r.m, &rings, 3)
		ui.probe_advance(p, 3, 1.0 / 60)
		b := ui.probe_bounds(p, "evil\u240Aname.txt")
		ui.probe_move(p, b.x + b.w / 2, b.y + b.h / 2)
		ui.probe_advance(p, 90, 1.0 / 60)
		testing.expect(t, ui.probe_tagged(p, "evil\nname.txt"), ui.probe_semantics(p, context.temp_allocator))
		gtx := ui.Ctx{allocator = context.temp_allocator}
		testing.expect_value(t, raw_tip_text(&gtx, "a\nb\nc\nd\ne"), "a\nb\nc\nd…")
		testing.expect_value(t, raw_tip_text(&gtx, "a\rb\u0085c\u2028d\u2029e"), "a\rb\u0085c\u2028d…")
		long := strings.repeat("é", 129, context.temp_allocator)
		testing.expect_value(t, raw_tip_text(&gtx, long), strings.concatenate({long[:256], "…"}, context.temp_allocator))
	}
}
