/*
estoile's mark: the star of cells, the disk as a sunburst drawn after an
estoile, the star in the Mordaunt arms ("a chevron between three estoiles",
Burke's General Armory). A hub and one ring of six folders, each cell
sending a slim ray out from the middle of its outer arc, the largest lit.
One geometry, in a 100x100 unit box, drawn by the window's toolbar (draw),
written as SVG for branding/ (write_svg), and offered to tools/logo beside
the candidates it was chosen from.
*/
package estoile_mark

import "core:fmt"
import "core:math"
import "core:strings"
import "jm:ui"
import "jm:ui/ops"

// SEA is the lit cell's colour, in both schemes.
SEA :: ops.Color{14, 116, 144, 255}

CENTER  :: ops.Point{50, 50}
HUB_R   :: 11 // the hub's radius
CELL_R0 :: 17 // a cell's inner radius
CELL_R1 :: 29 // a cell's outer radius, where its ray stands
TIP_R   :: 48 // how far a ray reaches
CELLS   :: 6
LIT     :: 1 // the lit cell, counted clockwise from twelve o'clock
GAP     :: 3.5 // half the gap between two cells, degrees
SPAN    :: 9 // half a ray's footing on the outer arc, degrees

// Cell is cell i's outline: its outer arc from a0 to the ray's footing, the
// ray out to its tip and back, the rest of the outer arc to a1, then the
// inner arc home. Angles are radians clockwise from three o'clock.
Cell :: struct {
	a0, a1, mid: f32,
}

cell :: proc(i: int) -> Cell {
	mid := rad(-90 + f32(i) * 360 / CELLS)
	half := rad(180 / CELLS - GAP)
	return {mid - half, mid + half, mid}
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
	for i in 0 ..< CELLS {
		c := cell(i)
		b := pb(gtx)
		pb_move(&b, on_circle(CENTER, CELL_R1, c.a0))
		pb_arc(&b, CENTER, CELL_R1, c.a0, c.mid - rad(SPAN))
		pb_line(&b, on_circle(CENTER, TIP_R, c.mid))
		pb_line(&b, on_circle(CENTER, CELL_R1, c.mid + rad(SPAN)))
		pb_arc(&b, CENTER, CELL_R1, c.mid + rad(SPAN), c.a1)
		pb_line(&b, on_circle(CENTER, CELL_R0, c.a1))
		pb_arc(&b, CENTER, CELL_R0, c.a1, c.a0)
		pb_close(&b)
		ops.fill(gtx.scene, pb_done(gtx, &b), accent if i == LIT else ink)
	}
}

// write_svg writes the mark's shapes as SVG elements, one per line, in its
// 100x100 box. Arcs are SVG's own, so the file is exact where draw's cubics
// are within 0.03% (arc_cubic_stays_on_the_circle). Every arc sweeps less
// than half a turn.
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
	pt :: proc(r, a: f32) -> string {
		p := on_circle(CENTER, r, a)
		return fmt.tprintf("%.3f %.3f", p.x, p.y)
	}
	for i in 0 ..< CELLS {
		c := cell(i)
		fmt.sbprintfln(
			b,
			`%s<path d="M%sA%d %d 0 0 1 %sL%sL%sA%d %d 0 0 1 %sL%sA%d %d 0 0 0 %sZ" fill="%s"/>`,
			indent,
			pt(CELL_R1, c.a0),
			CELL_R1,
			CELL_R1,
			pt(CELL_R1, c.mid - rad(SPAN)),
			pt(TIP_R, c.mid),
			pt(CELL_R1, c.mid + rad(SPAN)),
			CELL_R1,
			CELL_R1,
			pt(CELL_R1, c.a1),
			pt(CELL_R0, c.a1),
			CELL_R0,
			CELL_R0,
			pt(CELL_R0, c.a0),
			hex(accent if i == LIT else ink),
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
