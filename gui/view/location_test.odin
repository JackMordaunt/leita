package leita_view

import "core:strings"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../command"
import "../query"

@(private = "file")
Location_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
location_open :: proc(r: ^Location_Rig) {
	model_init(&r.m, "")
	r.m.settings_read = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&r.h, view, &r.m, {1000, 700}, fonts)
	ui.probe_frame(&r.h.p)
	ui.probe_frame(&r.h.p)
}

@(private = "file")
location_close :: proc(r: ^Location_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

@(private = "file")
LONG_DIR :: "directory_with_a_very_long_name"

// location_trail_open is the bar at rest on a finished scan whose crumbs fill it.
@(private = "file")
location_trail_open :: proc(r: ^Location_Rig, crumbs: []query.Crumb, size: ops.Size = {640, 700}) {
	model_init(&r.m, crumbs[0].name)
	r.m.settings_read = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&r.h, view, &r.m, size, fonts)
	p := &r.h.p
	ui.probe_deliver(
		p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = crumbs[0].name},
	)
	ui.probe_deliver(
		p,
		query.Rings{generation = 1, dir = query.ROOT},
		query.Rings_Result{generation = 1, dir = 1, crumbs = crumbs, bytes = 100, was = -1},
	)
	ui.probe_frame(p)
	ui.probe_frame(p)
}

@(private = "file")
full_crumbs :: proc() -> []query.Crumb {
	top := strings.concatenate(
		{"/scanroot/", LONG_DIR, "_aaa/", LONG_DIR, "_bbb/", LONG_DIR, "_ccc"},
		context.temp_allocator,
	)
	crumbs := make([]query.Crumb, 4, context.temp_allocator)
	crumbs[0] = {1, top}
	crumbs[1] = {2, strings.concatenate({LONG_DIR, "_ddd"}, context.temp_allocator)}
	crumbs[2] = {3, strings.concatenate({LONG_DIR, "_eee"}, context.temp_allocator)}
	crumbs[3] = {4, strings.concatenate({LONG_DIR, "_fff"}, context.temp_allocator)}
	return crumbs
}

// A path longer than a command can carry is not sent, which would scan an
// ancestor of it: the field stays, and the status says why, until a path that
// fits is entered.
@(test)
a_path_too_long_to_send_is_refused_in_the_field :: proc(t: ^testing.T) {
	r: Location_Rig
	location_open(&r)
	defer location_close(&r)
	p := &r.h.p

	defer free_all(context.temp_allocator)
	long := strings.repeat("/dir", command.MAX_PATH / 4 + 1, context.temp_allocator)
	ui.text_set(&r.m.path, long)
	r.m.editing, r.m.edit_focus = true, true
	ui.probe_advance(p, 5, 1.0 / 60)
	ui.probe_key(p, .Enter)
	ui.probe_frame(p)
	testing.expect(t, sent(p, command.Scan) == nil, "nothing is scanned")
	testing.expect(t, r.m.path_long, "the path is said to be too long")
	testing.expect(t, r.m.editing, "the field stays to be corrected")
	testing.expect(t, ui.probe_tagged(p, "that path is too long to scan"), "the status says so")

	ui.text_set(&r.m.path, "/top")
	ui.probe_advance(p, 5, 1.0 / 60)
	ui.probe_key(p, .Enter)
	scan, scanned := sent(p, command.Scan).?
	testing.expect(t, scanned, "a path that fits is scanned")
	testing.expect_value(t, command.text_of(&scan.path), "/top")
	testing.expect(t, !r.m.path_long, "and the warning goes")

}

// A frame leaves the theme it drew in behind it unset: primer's scheme is
// thread-local, tests share threads, and the Model that holds the scheme is the
// test's own stack, so a scheme left installed is read dead by the next test on
// that thread (ASan: stack-use-after-return in primer.color, 2026-10-17).
@(test)
a_frame_leaves_no_scheme_behind :: proc(t: ^testing.T) {
	r: Location_Rig
	location_open(&r)
	defer location_close(&r)
	r.m.dark = true
	ui.probe_frame(&r.h.p)
	testing.expect(t, primer.scheme() != &r.m.scheme, "the scheme is not the Model's")
	testing.expect_value(t, primer.theme(), primer.Theme.Light)
}

// A path that fills the bar has no empty end to click: a click on the well, or
// on the current step, opens the field. A click on another step still navigates,
// and Ctrl+L still opens the field.
@(test)
a_full_location_bar_opens_on_a_click :: proc(t: ^testing.T) {
	r: Location_Rig
	location_trail_open(&r, full_crumbs())
	defer location_close(&r)
	p := &r.h.p

	current := strings.concatenate({LONG_DIR, "_fff"}, context.temp_allocator)
	parent := strings.concatenate({LONG_DIR, "_eee"}, context.temp_allocator)
	bar := ui.probe_bounds(p, "Location")
	testing.expect(t, bar.w > 0, "the bar is drawn")
	deepest := ui.probe_bounds(p, current)
	testing.expect(t, deepest.w > 0, "the deepest step is shown")
	root := ui.probe_bounds(p, "scanroot")
	testing.expectf(
		t,
		root.x < bar.x,
		"the top has scrolled off: scanroot at %v, bar from %v",
		root.x,
		bar.x,
	)
	testing.expect(t, !r.m.editing, "the bar is the steps")

	ui.probe_click_at(p, {bar.x + bar.w - 3, bar.y + bar.h / 2})
	testing.expect(t, r.m.editing, "a click on the full bar opens the field")
	testing.expect(
		t,
		strings.contains(ui.text_string(&r.m.path), current),
		"holding the path shown",
	)

	ui.probe_key(p, .Escape)
	ui.probe_frame(p)
	testing.expect(t, !r.m.editing, "Escape puts the steps back")

	testing.expect(t, ui.probe_click(p, current), "the current step")
	testing.expect(t, r.m.editing, "opens the field, already being here")
	testing.expect_value(t, r.m.dir, query.ROOT)
	ui.probe_frame(p)

	ui.probe_key(p, .Escape)
	ui.probe_frame(p)
	testing.expect(t, !r.m.editing, "Escape puts the steps back")
	testing.expect(t, ui.probe_click(p, parent), "a step that is not current")
	testing.expect_value(t, r.m.dir, u32(3))
	testing.expect(t, !r.m.editing, "navigates rather than opening the field")

	r.m.dir = query.ROOT
	ui.probe_frame(p)
	ui.probe_key(p, .L, {ui.SHORTCUT})
	testing.expect(t, r.m.editing, "Ctrl+L still opens the field")
}
