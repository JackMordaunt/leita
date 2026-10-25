package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../query"

// The location bar's two fields, closed from the keyboard, give the keyboard to
// the magnifier beside them. They used to leave it on the field that had gone,
// so it was nowhere a person could see or Tab on from: the gui fuzz suite's
// focus invariant found it after Ctrl+L, a path, Enter.

@(private = "file")
Bar_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
bar_open :: proc(r: ^Bar_Rig) {
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
	run_bar_frames(p)
}

@(private = "file")
bar_close :: proc(r: ^Bar_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

// run_bar_frames lets a key land, the field close, and the focus asked for arrive.
@(private = "file")
run_bar_frames :: proc(p: ^ui.Probe) {
	for _ in 0 ..< 4 {
		ui.probe_frame(p)
	}
}

// drawn is whether the frame drew the area with the keyboard.
@(private = "file")
drawn :: proc(p: ^ui.Probe) -> bool {
	for h in ui.probe_current(p).hits {
		if h.area == p.router.focus {
			return true
		}
	}
	return false
}

@(test)
the_keyboard_comes_back_to_the_magnifier_when_a_bar_field_closes :: proc(t: ^testing.T) {
	r: Bar_Rig
	bar_open(&r)
	defer bar_close(&r)

	p := &r.h.p

	Close :: struct {
		what:   string,
		open:   ui.Key,
		typed:  string,
		closes: ui.Key,
	}
	closes := []Close {
		{"the location, Escape", .L, "", .Escape},
		{"the location, Enter", .L, "/top/src", .Enter},
		{"the search, Escape", .F, "main", .Escape},
	}
	for c in closes {
		ui.probe_key(p, c.open, {ui.SHORTCUT})
		run_bar_frames(p)
		testing.expectf(t, r.m.editing || r.m.searching, "%s opened", c.what)
		if c.typed != "" {
			ui.probe_type(p, c.typed)
		}
		ui.probe_key(p, c.closes)
		run_bar_frames(p)
		testing.expectf(t, !r.m.editing && !r.m.searching, "%s closed", c.what)
		testing.expectf(t, drawn(p), "%s left the keyboard on something drawn", c.what)
		testing.expectf(
			t,
			ui.probe_focus_name(p) == "Search",
			"%s gave the keyboard to the magnifier, not %q",
			c.what,
			ui.probe_focus_name(p),
		)
	}
}
