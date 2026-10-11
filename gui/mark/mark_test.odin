package leita_mark

import "core:math"
import "core:testing"
import "jm:ui/ops"

// An arc ends on its circle at its end angle whatever its sweep or
// direction, and splits into one cubic per quarter turn or less: the
// mark's cells and the window's sunburst are built from nothing else.
@(test)
arc_ends_on_its_circle :: proc(t: ^testing.T) {
	c := ops.Point{50, 50}
	cases := [?][3]f32 {
		{0, math.PI / 2, 1},
		{rad(-90), rad(240), 4},
		{rad(-15), rad(-270), 3},
		{0, 0.1, 1},
	}
	for tc in cases {
		b := Path_B {
			make([dynamic]ops.Path_Verb, context.temp_allocator),
			make([dynamic]ops.Point, context.temp_allocator),
		}
		pb_move(&b, on_circle(c, 30, tc[0]))
		pb_arc(&b, c, 30, tc[0], tc[1])
		testing.expect_value(t, len(b.verbs), 1 + int(tc[2]))
		end := b.pts[len(b.pts) - 1]
		want := on_circle(c, 30, tc[1])
		testing.expectf(
			t,
			abs(end.x - want.x) < 1e-3 && abs(end.y - want.y) < 1e-3,
			"arc %v ends at %v, want %v",
			tc,
			end,
			want,
		)
	}
}

// The midpoint of a quarter-turn cubic sits within 0.03% of the radius.
@(test)
arc_cubic_stays_on_the_circle :: proc(t: ^testing.T) {
	b := Path_B {
		make([dynamic]ops.Path_Verb, context.temp_allocator),
		make([dynamic]ops.Point, context.temp_allocator),
	}
	pb_move(&b, {100, 0})
	pb_arc(&b, {0, 0}, 100, 0, math.PI / 2)
	p0, c1, c2, p1 := b.pts[0], b.pts[1], b.pts[2], b.pts[3]
	mid := (p0 + 3 * c1 + 3 * c2 + p1) / 8
	testing.expectf(
		t,
		abs(math.sqrt(mid.x * mid.x + mid.y * mid.y) - 100) < 0.03,
		"midpoint %v off the circle",
		mid,
	)
}
