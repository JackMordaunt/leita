package leita_view

import "core:fmt"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../query"

// The side column's rows on the frame their answer lands in: a flex jm:ui has
// not laid out before shares its weighted children out from the previous
// frame's totals, so a row whose weighted child comes before an unweighted one
// would lay out wider than the column for that one frame, and the window's
// column, which fills to its widest child, would widen every banner with it.

@(private = "file")
SIDE_SIZES := [?]ops.Size{{640, 420}, {1280, 820}}

// wider_than reports the first semantic node of the frame drawn last that
// reaches past the window's sides, or "" when every node fits.
@(private = "file")
wider_than :: proc(p: ^ui.Probe, window: ops.Size) -> string {
	for n in ui.probe_current(p).nodes {
		r := n.rect
		if r.x < -ui.OVERFLOW_SLOP || r.x + r.w > window.x + ui.OVERFLOW_SLOP {
			return fmt.tprintf("%v %q at x %.0f..%.0f in a window %.0f wide", n.semantics.role, n.semantics.label, r.x, r.x + r.w, window.x)
		}
	}
	return ""
}

@(private = "file")
side_open :: proc(h: ^render.Headless, m: ^Model, size: ops.Size) {
	model_init(m, "/top")
	m.settings_read = true

	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(h, view, m, size, fonts)

	ui.probe_deliver(
		&h.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = "/top"},
	)

	ui.probe_frame(&h.p)
	ui.probe_advance(&h.p, 30, 1.0 / 60)
}

// A listing's rows, and then the largest files', fit the window on the frame
// each lands in, at the smallest window and at the one the window opens at.
@(test)
the_side_rows_fit_the_window_on_the_frame_they_land :: proc(t: ^testing.T) {
	for size in SIDE_SIZES {
		h: render.Headless
		m: Model
		side_open(&h, &m, size)
		defer {
			render.headless_destroy(&h)
			model_destroy(&m)
		}

		p := &h.p

		entries := []query.Entry {
			{node = 2, name = "a directory with a rather long name indeed", bytes = 60_000_000_000, directory = true, was = -1},
			{node = 3, name = "movie.mkv", bytes = 30_000_000_000, was = -1, logical = 31_000_000_000, logical_known = true},
			{node = 4, name = "n", bytes = 12, was = -1},
		}
		ui.probe_deliver(
			p,
			query.Listing{generation = 1, dir = query.ROOT},
			query.Listing_Result {
				generation = 1,
				dir = 1,
				crumbs = []query.Crumb{{1, "/top"}},
				bytes = 90_000_000_012,
				was = -1,
				entries = entries,
			},
		)
		ui.probe_frame(p)
		testing.expect(t, ui.probe_tagged(p, "movie.mkv"), "the listing landed")
		w := wider_than(p, size)
		testing.expectf(t, w == "", "the frame a listing lands in: %s", w)

		files := []query.File {
			{
				node = 3,
				parent = 1,
				path = "/top/a directory with a rather long name indeed/and deeper still/movie.mkv",
				bytes = 30_000_000_000,
				was = -1,
				logical = 31_000_000_000,
				logical_known = true,
			},
			{node = 4, parent = 1, path = "/top/n", bytes = 12, was = -1},
		}
		ui.probe_deliver(p, query.Largest{generation = 1}, query.Largest_Result{files = files})
		ui.probe_frame(p)
		testing.expect(t, ui.probe_tagged(p, "/top/n"), "the largest files landed")
		w = wider_than(p, size)
		testing.expectf(t, w == "", "the frame the largest files land in: %s", w)
		ui.probe_advance(p, 5, 1.0 / 60)
		w = wider_than(p, size)
		testing.expectf(t, w == "", "the frames after: %s", w)
	}
}
