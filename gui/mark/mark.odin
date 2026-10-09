/*
sonar's mark: the disk as a sunburst, a hub and two rings of folders with the
largest lit. One geometry, in a 100x100 unit box, drawn by the window's
toolbar (draw), written as SVG for branding/ (write_svg), and offered to
tools/logo beside the candidates it was chosen from.
*/
package sonar_mark

import "core:fmt"
import "core:math"
import "core:strings"
import "jm:ui"
import "jm:ui/ops"

// SEA is the lit cell's colour, in both schemes.
SEA :: ops.Color{14, 116, 144, 255}

CENTER :: ops.Point{50, 50}
HUB_R  :: 13 // the hub's radius
GAP    :: 3.5 // half the gap between two cells, degrees

// Cell is one folder: the ring between radii r0 and r1, from angle a0 to a1
// in degrees clockwise from three o'clock, less GAP at either end.
Cell :: struct {
	r0, r1, a0, a1: f32,
	lit:            bool,
}

CELLS := [?]Cell {
	{18, 30, -90, 90, false},
	{18, 30, 90, 198, false},
	{18, 30, 198, 270, false},
	{34, 45, -90, 25, true},
	{34, 45, 25, 90, false},
	{34, 45, 90, 160, false},
}

// draw draws the mark with its 100x100 box scaled to size at `at`.
draw :: proc(gtx: ^ui.Ctx, at: ops.Point, size: f32, ink, accent: ops.Color) {
	s := f64(size / 100)
	ops.transform_push(gtx.scene, {s, 0, 0, s, f64(at.x), f64(at.y)})
	defer ops.transform_pop(gtx.scene)
	draw_box(gtx, ink, accent)
}

// draw_box draws the mark in its own 100x100 box, under whatever transform
// the caller has pushed.
draw_box :: proc(gtx: ^ui.Ctx, ink, accent: ops.Color) {
	ops.fill(gtx.scene, ui.circle(CENTER, HUB_R), ink)
	for c in CELLS {
		ops.fill(
			gtx.scene,
			band(gtx, CENTER, c.r0, c.r1, rad(c.a0 + GAP), rad(c.a1 - GAP)),
			accent if c.lit else ink,
		)
	}
}

// write_svg writes the mark's shapes as SVG elements, one per line, in its
// 100x100 box. Arcs are SVG's own, so the file is exact where draw's cubics
// are within 0.03%.
write_svg :: proc(b: ^strings.Builder, ink, accent: ops.Color, indent := "  ") {
	fmt.sbprintfln(
		b,
		`%s<circle cx="%.0f" cy="%.0f" r="%.0f" fill="%s"/>`,
		indent,
		CENTER.x,
		CENTER.y,
		f32(HUB_R),
		hex(ink),
	)
	for c in CELLS {
		a0, a1 := rad(c.a0 + GAP), rad(c.a1 - GAP)
		large := 1 if a1 - a0 > math.PI else 0
		p0, p1 := on_circle(CENTER, c.r1, a0), on_circle(CENTER, c.r1, a1)
		q1, q0 := on_circle(CENTER, c.r0, a1), on_circle(CENTER, c.r0, a0)
		fmt.sbprintfln(
			b,
			`%s<path d="M%.3f %.3fA%.0f %.0f 0 %d 1 %.3f %.3fL%.3f %.3fA%.0f %.0f 0 %d 0 %.3f %.3fZ" fill="%s"/>`,
			indent,
			p0.x,
			p0.y,
			c.r1,
			c.r1,
			large,
			p1.x,
			p1.y,
			q1.x,
			q1.y,
			c.r0,
			c.r0,
			large,
			q0.x,
			q0.y,
			hex(accent if c.lit else ink),
		)
	}
}

hex :: proc(c: ops.Color) -> string {
	return fmt.tprintf("#%02x%02x%02x", c.r, c.g, c.b)
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
