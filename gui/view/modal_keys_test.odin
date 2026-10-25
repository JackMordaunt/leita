package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../command"
import "../query"

// The window's shortcuts, Cmd/Ctrl with L, F or R and Alt with an arrow, are
// asked for window-wide, so they reach the window under a modal dialog. There
// Ctrl+L opened the location field behind the About dialog and took the
// keyboard out of it, which the gui fuzz suite's focus invariant found; Ctrl+R
// scanned again behind a dialog, the way in to card 516.

@(private = "file")
Modal_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
modal_open :: proc(r: ^Modal_Rig) {
	model_init(&r.m, "/top")
	r.m.settings_read = true
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
	ui.probe_deliver(
		p,
		query.Rings{generation = 1, dir = query.ROOT},
		query.Rings_Result{generation = 1, dir = 1, crumbs = {{1, "/top"}}, bytes = 100, was = -1},
	)
	run_modal_frames(p)
}

@(private = "file")
modal_close :: proc(r: ^Modal_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

@(private = "file")
run_modal_frames :: proc(p: ^ui.Probe) {
	for _ in 0 ..< 4 {
		ui.probe_frame(p)
	}
}

@(test)
the_window_shortcuts_wait_while_a_modal_dialog_is_open :: proc(t: ^testing.T) {
	r: Modal_Rig
	modal_open(&r)
	defer modal_close(&r)

	p := &r.h.p

	// A way back to walk, so Alt+Left would have somewhere to go.
	append(&r.m.back, 7)
	r.m.about_open = true
	run_modal_frames(p)
	testing.expect_value(t, ui.probe_focus_name(p), "Close")

	ui.probe_key(p, .R, {ui.SHORTCUT})
	testing.expect(t, sent(p, command.Scan) == nil, "Ctrl+R does not scan behind the dialog")
	run_modal_frames(p)
	ui.probe_key(p, .L, {ui.SHORTCUT})
	run_modal_frames(p)
	testing.expect(t, !r.m.editing, "Ctrl+L does not open the location behind the dialog")
	ui.probe_key(p, .F, {ui.SHORTCUT})
	run_modal_frames(p)
	testing.expect(t, !r.m.searching, "Ctrl+F does not open the search behind the dialog")
	ui.probe_key(p, .Left, {.Alt})
	run_modal_frames(p)
	testing.expect_value(t, r.m.dir, query.ROOT)
	testing.expect_value(t, ui.probe_focus_name(p), "Close")

	// Closed, the shortcuts are the window's again.
	ui.probe_key(p, .Escape)
	run_modal_frames(p)
	testing.expect(t, !r.m.about_open)
	ui.probe_key(p, .R, {ui.SHORTCUT})
	_, scanned := sent(p, command.Scan).?
	testing.expect(t, scanned, "Ctrl+R scans again with the dialog closed")
}
