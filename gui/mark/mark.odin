/*
leita's mark, the found cell: the disk as a sunburst, a hub and two rings of
folders, the outer ring partial as a real tree is, one cell lit as the find.
The window's toolbar draws it (draw), and the sunburst view draws its cells
with the same path helpers. The candidates it was chosen from, and the
branding/ files, come from the logo tool.
*/
package leita_mark

import "core:math"
import "jm:ui"
import "jm:ui/ops"

// SEA is the find's colour, in both schemes.
SEA :: ops.Color{14, 116, 144, 255}

CENTER :: ops.Point{50, 50}

// BANDS is the found cell's tree, each band {r0, r1, a0, a1} with angles in
// degrees clockwise from three o'clock: an inner ring of four, an outer ring
// partial as a real tree is.
BANDS := [?][4]f32 {
	{15, 29, -88, -2},
	{15, 29, 2, 88},
	{15, 29, 92, 178},
	{15, 29, 182, 268},
	{33, 47, -88, -38},
	{33, 47, -34, -2},
	{33, 47, 2, 60},
	{33, 47, 64, 88},
	{33, 47, 182, 240},
}
LIT :: 6 // the band lit as the find
HUB :: 10 // the hub's radius

// draw draws the mark with its 100x100 box scaled to size at `at`.
draw :: proc(gtx: ^ui.Ctx, at: ops.Point, size: f32, ink, accent: ops.Color) {
	s := f64(size / 100)
	ops.transform_push(gtx.scene, {s, 0, 0, s, f64(at.x), f64(at.y)})
	defer ops.transform_pop(gtx.scene)
	ops.fill(gtx.scene, ui.circle(CENTER, HUB), ink)
	for b, i in BANDS {
		ops.fill(
			gtx.scene,
			band(gtx, CENTER, b[0], b[1], rad(b[2]), rad(b[3])),
			accent if i == LIT else ink,
		)
	}
}

// ---------------------------------------------------------------- paths

Path_B :: struct {
	verbs: [dynamic]ops.Path_Verb,
	pts:   [dynamic]ops.Point,
}

pb :: proc(gtx: ^ui.Ctx) -> Path_B {
	return {make([dynamic]ops.Path_Verb, gtx.allocator), make([dynamic]ops.Point, gtx.allocator)}
}

pb_move :: proc(b: ^Path_B, p: ops.Point) {
	append(&b.verbs, ops.Path_Verb.Move)
	append(&b.pts, p)
}

pb_line :: proc(b: ^Path_B, p: ops.Point) {
	append(&b.verbs, ops.Path_Verb.Line)
	append(&b.pts, p)
}

pb_cubic :: proc(b: ^Path_B, c1, c2, p: ops.Point) {
	append(&b.verbs, ops.Path_Verb.Cubic)
	append(&b.pts, c1, c2, p)
}

pb_close :: proc(b: ^Path_B) {
	append(&b.verbs, ops.Path_Verb.Close)
}

// pb_arc continues the path along the circle at c of radius r from angle
// a0 to a1, in radians, clockwise on screen when a1 > a0. The path must
// already stand at on_circle(c, r, a0). Each quarter turn or less is one
// cubic, which is within 0.03% of the circle.
pb_arc :: proc(b: ^Path_B, c: ops.Point, r, a0, a1: f32) {
	n := max(1, int(math.ceil(abs(a1 - a0) / (math.PI / 2))))
	step := (a1 - a0) / f32(n)
	k := 4.0 / 3.0 * math.tan(step / 4) * r
	for i in 0 ..< n {
		s := a0 + f32(i) * step
		e := s + step
		p0, p1 := on_circle(c, r, s), on_circle(c, r, e)
		c1 := ops.Point{p0.x - k * math.sin(s), p0.y + k * math.cos(s)}
		c2 := ops.Point{p1.x + k * math.sin(e), p1.y - k * math.cos(e)}
		pb_cubic(b, c1, c2, p1)
	}
}

pb_done :: proc(gtx: ^ui.Ctx, b: ^Path_B) -> ops.Path_Ref {
	return {ops.add_path(gtx.scene, {verbs = b.verbs[:], points = b.pts[:]})}
}

on_circle :: proc(c: ops.Point, r, a: f32) -> ops.Point {
	return {c.x + r * math.cos(a), c.y + r * math.sin(a)}
}

rad :: proc(deg: f32) -> f32 {
	return deg * math.PI / 180
}

// band is the ring segment between radii r0 and r1 from a0 to a1, in
// radians: one cell.
band :: proc(gtx: ^ui.Ctx, c: ops.Point, r0, r1, a0, a1: f32) -> ops.Path_Ref {
	b := pb(gtx)
	pb_move(&b, on_circle(c, r1, a0))
	pb_arc(&b, c, r1, a0, a1)
	pb_line(&b, on_circle(c, r0, a1))
	pb_arc(&b, c, r0, a1, a0)
	pb_close(&b)
	return pb_done(gtx, &b)
}
