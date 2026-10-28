package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../query"

// A Contents row that opens its folder is gone on the frame the new listing
// lands, and the keyboard must not stay on it. The route after that frame
// moves it (jm:ui recovers an area the frame did not draw). The check is that
// next frame: without the recovery the old row's area is still router.focus
// and no hit has it.

@(private = "file")
DOCS :: u32(2)

@(private = "file")
focus_drawn :: proc(p: ^ui.Probe) -> bool {
	if p.router.focus == 0 {
		return false
	}
	for h in ui.probe_current(p).hits {
		if h.area == p.router.focus {
			return true
		}
	}
	return false
}

@(test)
opening_a_contents_folder_leaves_the_keyboard_on_a_drawn_control :: proc(t: ^testing.T) {
	m: Model
	model_init(&m, "/top")
	m.settings_read = true
	defer model_destroy(&m)

	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, view, &m, {1000, 700}, fonts)
	defer render.headless_destroy(&h)
	p := &h.p

	ui.probe_deliver(
		p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = "/top"},
	)
	ui.probe_deliver(
		p,
		query.Rings{generation = 1, dir = query.ROOT},
		query.Rings_Result{generation = 1, dir = 1, crumbs = {{1, "/top"}}, bytes = 50, was = -1},
	)
	parent := []query.Entry {
		{node = DOCS, name = "docs", bytes = 40, directory = true, was = -1},
		{node = 3, name = "readme", bytes = 10, was = -1},
	}
	ui.probe_deliver(
		p,
		query.Listing{generation = 1, dir = query.ROOT},
		query.Listing_Result {
			generation = 1,
			dir = 1,
			crumbs = {{1, "/top"}},
			bytes = 50,
			was = -1,
			entries = parent,
		},
	)
	for _ in 0 ..< 4 {
		ui.probe_frame(p)
	}
	testing.expect(t, ui.probe_tagged(p, "docs"), "the folder row is drawn")

	testing.expect(t, ui.probe_click(p, "docs"), "the folder row takes the click")
	testing.expect_value(t, m.dir, DOCS)
	was := p.router.focus
	testing.expect(t, was != 0, "the click put the keyboard on the row")

	child := []query.Entry{{node = 4, name = "notes", bytes = 10, was = -1}}
	ui.probe_deliver(
		p,
		query.Listing{generation = 1, dir = DOCS},
		query.Listing_Result {
			generation = 1,
			dir = DOCS,
			crumbs = {{1, "/top"}, {DOCS, "docs"}},
			bytes = 10,
			was = -1,
			entries = child,
		},
	)
	// The frame the listing lands in still routed against the row. The next
	// route is the one that finds the row gone and moves the keyboard.
	ui.probe_frame(p)
	ui.probe_frame(p)

	testing.expect(t, !ui.probe_tagged(p, "docs"), "the folder row has gone")
	testing.expect(t, ui.probe_tagged(p, "notes"), "the folder's listing is drawn")
	testing.expectf(
		t,
		focus_drawn(p) && p.router.focus != was,
		"the keyboard stayed on %d %q, which opened the folder and is gone",
		p.router.focus,
		ui.probe_focus_name(p),
	)
}
