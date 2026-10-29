package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../../version"
import "../query"

@(private = "file")
Title_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
title_open :: proc(r: ^Title_Rig) {
	model_init(&r.m, "/top")
	r.m.settings_read = true
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
	ui.probe_frame(&r.h.p)
	ui.probe_frame(&r.h.p)
}

@(private = "file")
title_close :: proc(r: ^Title_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

@(private = "file")
title_show :: proc(p: ^ui.Probe, bar: ui.Title_Bar) {
	p.title_bar = bar
	ui.probe_frame(p)
	ui.probe_frame(p)
}

@(private = "file")
area_holds :: proc(r: ops.Rect, x, y: f32) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

// Without a caption the top row keeps its margin, and nothing drags the window.
@(test)
the_toolbar_keeps_its_margin_without_a_caption :: proc(t: ^testing.T) {
	r: Title_Rig
	title_open(&r)
	defer title_close(&r)
	p := &r.h.p

	gear := ui.probe_bounds(p, "Settings")
	testing.expectf(t, gear.w > 0 && gear.y >= PAD && gear.y < PAD + BAR_GAP, "gear at %v", gear)
	testing.expect_value(t, len(p.prev.drags), 0)
}

// When the frame draws the caption buttons, a thin bar BAR tall holds
// them at its right, and back and forward after the mark and the product.
// The toolbar sits below it at full size. Everything in the bar but the
// buttons drags; nothing below it does.
@(test)
the_thin_bar_drags_around_its_buttons :: proc(t: ^testing.T) {
	r: Title_Rig
	title_open(&r)
	defer title_close(&r)
	p := &r.h.p

	gear_was := ui.probe_bounds(p, "Settings")
	// A way back and a way forward, so both are live and named.
	open(&r.m, 7)
	open(&r.m, 8)
	go_back(&r.m)
	title_show(p, {height = 30, buttons = {854, 0, 146, 30}, drawn = true, active = true})

	testing.expect_value(t, len(p.prev.buttons), 3)
	buttons: ops.Rect
	for b, i in p.prev.buttons {
		testing.expectf(t, b.rect.y == 0 && b.rect.h == BAR && b.rect.w == 46, "button %d at %v", i, b.rect)
		buttons = b.rect if i == 0 else both_bounds(buttons, b.rect)
	}
	testing.expect_value(t, buttons, ops.Rect{1000 - 138, 0, 138, BAR})
	for name in ([]string{"Minimize", "Maximize", "Close"}) {
		testing.expectf(t, ui.probe_tagged(p, name), "%s is drawn", name)
	}

	back := ui.probe_bounds(p, "Back")
	forward := ui.probe_bounds(p, "Forward")
	for c in ([]ops.Rect{back, forward}) {
		testing.expectf(t, c.w > 0 && c.y >= 0 && c.y + c.h <= BAR, "%v is not in the bar", c)
	}
	testing.expectf(t, back.x + back.w <= forward.x, "back %v is not before forward %v", back, forward)

	// At 1000 wide every tool fits, left of the gear, all in the bar.
	gear := ui.probe_bounds(p, "Settings")
	tools := []ops.Rect {
		ui.probe_bounds(p, "Rescan"),
		ui.probe_bounds(p, "Export"),
		ui.probe_bounds(p, "Theme"),
		gear,
	}
	for c, i in tools {
		testing.expectf(t, c.w > 0 && c.y >= 0 && c.y + c.h <= BAR, "tool %d at %v is not in the bar", i, c)
		if i > 0 {
			testing.expectf(t, tools[i - 1].x + tools[i - 1].w <= c.x, "tool %d at %v is not after %v", i, c, tools[i - 1])
		}
	}
	testing.expectf(t, gear.x + gear.w <= buttons.x - 2 * BAR_GAP - 1 + 0.5, "gear %v leaves no room for the rule before %v", gear, buttons)
	testing.expectf(t, tools[0].x - (forward.x + forward.w) >= BAR_DRAG, "the drag between forward and the tools is under BAR_DRAG")

	// The toolbar below is the location and its magnifier, at full size.
	place := ui.probe_bounds(p, "Location")
	search := ui.probe_bounds(p, "Search")
	for c in ([]ops.Rect{place, search}) {
		testing.expectf(t, c.w > 0 && c.y >= BAR, "%v is not below the bar", c)
	}
	testing.expectf(t, gear_was.h > 0, "the gear was in the toolbar before")

	corner, middle, after := false, false, false
	for d in p.prev.drags {
		testing.expectf(t, d.y + d.h <= BAR, "a drag %v reaches below the bar", d)
		for c in ([]ops.Rect{back, forward, buttons}) {
			testing.expectf(t, !rect_meets(d, c), "a drag %v covers %v", d, c)
		}
		for c in tools {
			testing.expectf(t, !rect_meets(d, c), "a drag %v covers a tool %v", d, c)
		}
		corner ||= area_holds(d, 2, 2)
		middle ||= area_holds(d, 500, BAR / 2)
		after ||= area_holds(d, forward.x + forward.w + 4, BAR / 2)
	}
	testing.expect(t, corner, "the mark's corner drags")
	testing.expect(t, middle, "the middle of the bar drags")
	testing.expect(t, after, "the bar just after forward drags")
}

// Back and forward in the thin bar walk the history the mouse buttons walk.
@(test)
the_thin_bar_walks_the_history :: proc(t: ^testing.T) {
	r: Title_Rig
	title_open(&r)
	defer title_close(&r)
	p := &r.h.p
	title_show(p, {height = 30, buttons = {854, 0, 146, 30}, drawn = true, active = true})

	open(&r.m, 7)
	title_show(p, p.title_bar)
	testing.expect(t, ui.probe_click(p, "Back"))
	ui.probe_frame(p)
	testing.expect_value(t, r.m.dir, query.ROOT)
	testing.expect_value(t, len(r.m.forward), 1)
	testing.expect(t, ui.probe_click(p, "Forward"))
	ui.probe_frame(p)
	testing.expect_value(t, r.m.dir, u32(7))
}

// The platform's own caption buttons keep the row clear of them too.
@(test)
the_toolbar_sits_clear_of_the_platform_buttons :: proc(t: ^testing.T) {
	r: Title_Rig
	title_open(&r)
	defer title_close(&r)
	p := &r.h.p

	buttons := ops.Rect{860, 0, 140, 32}
	title_show(p, {height = 32, buttons = buttons})

	gear := ui.probe_bounds(p, "Settings")
	done := ui.probe_bounds(p, "Done")
	testing.expectf(t, gear.w > 0 && gear.x + gear.w <= buttons.x - BAR_GAP + 0.5, "gear %v meets the buttons %v", gear, buttons)
	testing.expectf(t, done.w > 0 && done.y >= gear.y + gear.h, "the status %v is not below the row", done)
	testing.expect_value(t, len(p.prev.buttons), 0)
	for d in p.prev.drags {
		testing.expectf(t, !rect_meets(d, buttons), "a drag %v covers the buttons %v", d, buttons)
	}
}

// Caption buttons on the left push the branding past them.
@(test)
the_toolbar_clears_caption_buttons_on_the_left :: proc(t: ^testing.T) {
	r: Title_Rig
	title_open(&r)
	defer title_close(&r)
	p := &r.h.p

	buttons := ops.Rect{0, 0, 140, 32}
	title_show(p, {height = 32, buttons = buttons})

	name := ui.probe_bounds(p, version.PRODUCT)
	testing.expectf(
		t,
		name.x >= buttons.x + buttons.w + BAR_GAP + BAR_MARK + BAR_GAP - 0.5,
		"Leita at %v, buttons %v",
		name,
		buttons,
	)
}

// The tools collapse into the gear by priority as the bar narrows, Theme
// first and Rescan last, and keep BAR_DRAG free to drag by.
@(test)
the_bar_tools_collapse_by_priority :: proc(t: ^testing.T) {
	buttons := ops.Rect{0, 0, 138, BAR}
	wide := bar_layout(1000, BAR, {1000 - 138, 0, 138, BAR}, 40)
	testing.expect_value(t, wide.shown, bit_set[Bar_Tool]{.Rescan, .Export, .Theme})

	all_at := f32(0)
	prev := wide.shown
	order := make([dynamic]Bar_Tool, context.temp_allocator)
	for w := f32(1000); w > 200; w -= 1 {
		buttons = {w - 138, 0, 138, BAR}
		l := bar_layout(w, BAR, buttons, 40)
		nav_end := l.nav_x + 2 * TOOL + TOOL_GAP
		if l.shown != {} {
			testing.expectf(t, l.free - nav_end >= BAR_DRAG - 0.01, "at %v the drag is %v", w, l.free - nav_end)
		}
		testing.expectf(t, l.shown <= prev, "at %v a tool came back: %v after %v", w, l.shown, prev)
		for tool in prev - l.shown {
			append(&order, tool)
		}
		if l.shown == {.Rescan, .Export, .Theme} {
			all_at = w
		}
		prev = l.shown
	}
	testing.expect_value(t, len(order), 3)
	if len(order) == 3 {
		testing.expect_value(t, order[0], Bar_Tool.Theme)
		testing.expect_value(t, order[2], Bar_Tool.Rescan)
	}
	testing.expectf(t, all_at > 0 && all_at < 800, "every tool fits only from %v", all_at)
}

// Buttons on the left, as macOS has them, push the mark past them and leave
// the gear at the right edge.
@(test)
a_bar_with_buttons_on_the_left_keeps_the_gear_right :: proc(t: ^testing.T) {
	l := bar_layout(1000, BAR_MAC, {0, 0, 80, 52}, 40)
	testing.expect_value(t, l.divider, 80 + BAR_GAP)
	testing.expect_value(t, l.lead, 80 + 2 * BAR_GAP + 1)
	testing.expect_value(t, l.gear_x, 1000 - BAR_INSET - TOOL)
}
