package main

import "../../gui/query"
import "../../gui/view"
import "core:fmt"
import "core:math"
import "core:strings"
import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

// Locate a visible first-level directory in the current chart, never the sidebar.
chart_target :: proc(h: ^render.Headless, name: string) -> ops.Point {
	model := current_model
	if name != "Users" {fail("the capture chart fixture names Users")}
	if model.mode == .Sunburst {
		hit, ok := ui.probe_find_top(&h.p, "Sunburst chart")
		if !ok {fail("no Sunburst chart")}
		pose, found := model.poses[folder_node]
		if !found || pose.sweep <= 0 {fail("no visible Users arc")}
		radius := model.burst / 2 - 2
		hub := radius * view.HUB
		middle := hub + (radius - hub) / f32(query.RING_DEPTH) / 2
		angle := (pose.start + pose.sweep / 2) * math.TAU - math.PI / 2
		point := ops.Point {
			model.burst / 2 + middle * math.cos(angle),
			model.burst / 2 + middle * math.sin(angle),
		}
		return ops.apply(hit.transform, point)
	}
	tag := fmt.tprintf("%s %s", "box" if model.mode == .Treemap else "bar", name)
	hit, ok := ui.probe_find(&h.p, tag)
	if !ok {fail(fmt.tprintf("no chart folder %s", tag))}
	box := ops.transform_rect(hit.transform, ops.shape_bounds(&h.p.scene, hit.shape))
	// Target the directory label; -at verifies which folder the input actually opened.
	return {box.x + min(40, box.w / 2), box.y + 6}
}

//review:ignore code-without-tests suite.py exercises this assertion after every real chart and breadcrumb click in both themes.
assert_location :: proc(movie: ^Movie, expected: string) {
	model := current_model
	path := strings.builder_make(context.temp_allocator)
	for crumb, i in model.trail {
		if i > 1 || (i == 1 && model.trail[0].name != "/") {strings.write_byte(&path, '/')}
		strings.write_string(&path, crumb.name)
	}
	actual := strings.to_string(path)
	if actual != expected ||
	   len(model.trail) == 0 ||
	   model.dir != model.trail[len(model.trail) - 1].node {
		fail(fmt.tprintf("navigation expected %s, got %s (node %d)", expected, actual, model.dir))
	}
	fmt.printfln(
		"NAVIGATION\t%d\t%v\t%d\t%s\t%v",
		movie.frame,
		model.mode,
		model.dir,
		actual,
		observed.state,
	)
}
