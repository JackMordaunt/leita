package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../query"

@(private = "file")
Record_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
record_rig_open :: proc(r: ^Record_Rig) {
	model_init(&r.m, "/top")
	r.m.settings_read = true
	r.m.generation = 1
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&r.h, view, &r.m, {1000, 700}, fonts)
	ui.probe_deliver(
		&r.h.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = "/top"},
	)
	ui.probe_advance(&r.h.p, 10, 1.0 / 60)
}

@(private = "file")
record_rig_close :: proc(r: ^Record_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

// recorded is the host answering the dialog with record, newest first.
@(private = "file")
recorded :: proc(r: ^Record_Rig, record: query.Record_Result) {
	ui.probe_deliver(&r.h.p, query.Record{}, record)
	ui.probe_advance(&r.h.p, 10, 1.0 / 60)
}

// History in the settings menu opens the record: three deletions are three rows,
// the newest on top, each with how it went where it did not simply work.
@(test)
the_record_lists_three_deletions_newest_first :: proc(t: ^testing.T) {
	r: Record_Rig
	record_rig_open(&r)
	defer record_rig_close(&r)
	p := &r.h.p

	testing.expect(t, choose(p, &r.m, "History"), "the menu has History")
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, r.m.record_open, "the dialog opens")
	recorded(
		&r,
		{
			kept = true,
			actions = {
				{taken = 1_800_200_000, path = "/top/c/node_modules", bytes = 3_000_000},
				{
					taken = 1_800_100_000,
					path = "/top/b/target",
					bytes = 2_000_000,
					failed = true,
					why = "permission denied",
				},
				{taken = 1_800_000_000, path = "/top/a/.cache", bytes = 1_000_000},
			},
		},
	)

	newest, middle, oldest :=
		ui.probe_bounds(p, "/top/c/node_modules"),
		ui.probe_bounds(p, "/top/b/target"),
		ui.probe_bounds(p, "/top/a/.cache")
	testing.expect(t, newest.h > 0 && middle.h > 0 && oldest.h > 0, "three rows are drawn")
	testing.expect(t, newest.y < middle.y && middle.y < oldest.y, "newest first")
	testing.expect(t, ui.probe_tagged(p, record_time(1_800_200_000)), "when")
	testing.expect(t, ui.probe_tagged(p, "3.0 MB"), "how much")
	testing.expect(t, ui.probe_tagged(p, "Failed: permission denied"), "why it failed")
	testing.expect(t, !ui.probe_tagged(p, "Nothing has been"), "no empty state")
}

// Copy path puts the row's path on the clipboard.
@(test)
copy_path_puts_the_path_on_the_clipboard :: proc(t: ^testing.T) {
	r: Record_Rig
	record_rig_open(&r)
	defer record_rig_close(&r)
	p := &r.h.p

	r.m.record_open = true
	recorded(
		&r,
		{
			kept = true,
			actions = {
				{taken = 2, path = "/top/new", bytes = 20},
				{taken = 1, path = "/top/old", bytes = 10},
			},
		},
	)
	// The room the path is cut to leaves for Copy path is the room it takes.
	copy := ui.probe_bounds(p, "Copy path")
	testing.expectf(t, abs(copy.w - RECORD_COPY) < 0.5, "Copy path is %v wide", copy.w)
	testing.expect(t, ui.probe_click(p, "Copy path"), "the first row's Copy path")
	ui.probe_advance(p, 2, 1.0 / 60)
	testing.expect_value(t, ui.probe_clipboard(p), "/top/new")
}

// With nothing recorded the dialog says so, and with no store it says that.
@(test)
an_empty_or_missing_record_says_so :: proc(t: ^testing.T) {
	r: Record_Rig
	record_rig_open(&r)
	defer record_rig_close(&r)
	p := &r.h.p

	r.m.record_open = true
	recorded(&r, {kept = true})
	testing.expect(t, ui.probe_tagged(p, tr(.History_Empty)), "the empty state")
	testing.expect(t, !ui.probe_tagged(p, tr(.History_Unavailable)), "a store, so no complaint")
	recorded(&r, {})
	testing.expect(t, ui.probe_tagged(p, tr(.History_Unavailable)), "no store")
	testing.expect(t, !ui.probe_tagged(p, tr(.History_Empty)), "and no empty state")
}
