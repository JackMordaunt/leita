package estoile_view

import "core:testing"

import "jm:ui"

import "../query"

// Ease_Case is a frame that only eases one layout, and what it drew.
@(private = "file")
Ease_Case :: struct {
	m:     Model,
	r:     query.Rings_Result,
	drawn: query.Arc,
}

@(private = "file")
ease_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	c := (^Ease_Case)(user)
	c.drawn = ease(gtx, &c.m, &c.r)[0]
}

@(test)
an_arc_glides_to_each_new_layout_rather_than_jumping :: proc(t: ^testing.T) {
	arcs := []query.Arc{{node = 7, depth = 1, start = 0, sweep = 0.5}}
	c := Ease_Case {
		r = {generation = 1, dir = 1, arcs = arcs},
	}
	defer model_destroy(&c.m)
	p: ui.Probe
	ui.probe_init(&p, ease_frame, &c, {100, 100})
	defer ui.probe_destroy(&p)

	// New, it grows from nothing at its middle: one frame in, part of the way.
	ui.probe_frame(&p)
	testing.expectf(
		t,
		c.drawn.sweep > 0 && c.drawn.sweep < 0.5,
		"one frame in, sweep %v",
		c.drawn.sweep,
	)
	testing.expectf(
		t,
		c.drawn.start > 0 && c.drawn.start < 0.25,
		"one frame in, start %v",
		c.drawn.start,
	)

	// A second on, it is exactly where it was laid.
	ui.probe_advance(&p, 60, 1.0 / 60)
	testing.expect_value(t, c.drawn.sweep, 0.5)
	testing.expect_value(t, c.drawn.start, 0)

	// The scan moves on and the arc shrinks: it glides there, not jumps.
	arcs[0].sweep = 0.3
	ui.probe_frame(&p)
	testing.expectf(
		t,
		c.drawn.sweep < 0.5 && c.drawn.sweep > 0.3,
		"a frame after the change, sweep %v",
		c.drawn.sweep,
	)
	ui.probe_advance(&p, 60, 1.0 / 60)
	testing.expect_value(t, c.drawn.sweep, 0.3)
}
