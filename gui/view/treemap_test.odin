package sonar_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"

@(private = "file")
Squarify_Case :: struct {
	sizes: []f32,
	room:  ops.Rect,
	got:   [8]ops.Rect,
}

@(private = "file")
squarify_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	c := (^Squarify_Case)(user)
	copy(c.got[:], squarify(gtx, c.sizes, c.room))
}

// The worked example of Bruls, Huizing and van Wijk's squarified treemaps paper:
// areas 6, 6, 4, 3, 2, 2, 1 in a 6 by 4 room.
@(test)
squarify_keeps_every_area_and_keeps_boxes_near_square :: proc(t: ^testing.T) {
	c := Squarify_Case {
		sizes = {6, 6, 4, 3, 2, 2, 1},
		room  = {0, 0, 6, 4},
	}
	p: ui.Probe
	ui.probe_init(&p, squarify_frame, &c, {100, 100})
	defer ui.probe_destroy(&p)
	for size, i in c.sizes {
		b := c.got[i]
		testing.expectf(
			t,
			abs(b.w * b.h - size) < 1e-3,
			"box %d has area %v, not %v",
			i,
			b.w * b.h,
			size,
		)
		testing.expectf(
			t,
			b.x >= -1e-3 && b.y >= -1e-3 && b.x + b.w <= 6 + 1e-3 && b.y + b.h <= 4 + 1e-3,
			"box %d %v leaves the room",
			i,
			b,
		)
		aspect := max(b.w / b.h, b.h / b.w)
		testing.expectf(t, aspect < 3, "box %d is %v to 1", i, aspect)
	}
	// The first row is the two largest, side by side down the shorter edge.
	testing.expectf(
		t,
		abs(c.got[0].x - c.got[1].x) < 1e-3,
		"the two largest share a column: %v %v",
		c.got[0],
		c.got[1],
	)
}
