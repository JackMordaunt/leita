// The estoile round: candidate marks for the name, after the wavy-rayed star
// of the Mordaunt arms (argent, a chevron between three estoiles sable). The
// sunburst opens the round as the mark to beat; the rest move from it toward
// heraldry. The star of cells, 6, was chosen.
package main

import "core:math"
import "jm:ui"
import "jm:ui/ops"

import mark "../../gui/mark"

ESTOILE_MARKS := [?]Mark {
	{"sunburst", mark_sunburst},
	{"estoile", mark_estoile},
	{"lit ray", mark_lit_ray},
	{"pierced", mark_pierced},
	{"sized rays", mark_sized_rays},
	{"star of cells", mark_star_of_cells},
	{"arms", mark_arms},
	{"roundel", mark_roundel},
	{"app tile", mark_app_tile},
}

RAYS :: 6

// Star describes an estoile at c: RAYS wavy rays, ray i pointing at
// rot + i turns/RAYS and reaching reach[i]. Neighbouring rays meet at the
// valley radius; amp is how far a ray's centreline swings from straight.
Star :: struct {
	c:      ops.Point,
	reach:  [RAYS]f32,
	valley: f32,
	amp:    f32,
	rot:    f32,
}

star :: proc(c: ops.Point, r: f32, rot := f32(-math.PI / 2)) -> Star {
	return {c = c, reach = r, valley = r * 0.26, amp = r * 0.06, rot = rot}
}

// ray_edges appends ray i's outline from the valley before it to the valley
// after it: out along one edge to the tip, back along the other. The
// centreline makes a serpentine of one and a half waves that dies away
// toward the tip, and the width tapers to nothing there, slimming fast.
ray_edges :: proc(b: ^mark.Path_B, s: Star, i: int, start: bool) {
	N :: 20
	half := f32(math.PI) / RAYS
	theta := s.rot + f32(i) * 2 * f32(math.PI) / RAYS
	u := ops.Point{math.cos(theta), math.sin(theta)}
	v := ops.Point{-u.y, u.x}
	x0, h0 := s.valley * math.cos(half), s.valley * math.sin(half)
	at   :: proc(s: Star, u, v: ops.Point, x, y: f32) -> ops.Point {
		return {s.c.x + x * u.x + y * v.x, s.c.y + x * u.y + y * v.y}
	}
	edge :: proc(s: Star, x0, h0: f32, i: int, t, side: f32) -> (x, y: f32) {
		x = x0 + (s.reach[i] - x0) * t
		centre := s.amp * math.sin(3 * f32(math.PI) * t) * math.pow(1 - t, 0.7)
		width := h0 * math.pow(1 - t, 1.5)
		return x, centre + side * width
	}
	for j in 0 ..= N {
		x, y := edge(s, x0, h0, i, f32(j) / N, -1)
		p := at(s, u, v, x, y)
		if j == 0 && start {
			mark.pb_move(b, p)
		} else {
			mark.pb_line(b, p)
		}
	}
	for j := N - 1; j >= 0; j -= 1 {
		x, y := edge(s, x0, h0, i, f32(j) / N, 1)
		mark.pb_line(b, at(s, u, v, x, y))
	}
}

// star_outline appends the whole estoile as one closed subpath.
star_outline :: proc(b: ^mark.Path_B, s: Star) {
	for i in 0 ..< RAYS {
		ray_edges(b, s, i, i == 0)
	}
	mark.pb_close(b)
}

// circle_path appends a full circle as one closed subpath.
circle_path :: proc(b: ^mark.Path_B, c: ops.Point, r: f32) {
	mark.pb_move(b, on_circle(c, r, 0))
	mark.pb_arc(b, c, r, 0, 2 * math.PI)
	mark.pb_close(b)
}

fill_star :: proc(gtx: ^ui.Ctx, s: Star, color: ops.Color) {
	b := mark.pb(gtx)
	star_outline(&b, s)
	ops.fill(gtx.scene, mark.pb_done(gtx, &b), color)
}

// fill_ray fills ray i alone, closed across its two valleys.
fill_ray :: proc(gtx: ^ui.Ctx, s: Star, i: int, color: ops.Color) {
	b := mark.pb(gtx)
	ray_edges(&b, s, i, true)
	mark.pb_close(&b)
	ops.fill(gtx.scene, mark.pb_done(gtx, &b), color)
}

// even_odd fills b's subpaths so that each one inside another cuts a hole.
even_odd :: proc(gtx: ^ui.Ctx, b: ^mark.Path_B, color: ops.Color) {
	ref := mark.pb_done(gtx, b)
	gtx.scene.paths[ref.id].rule = .Even_Odd
	ops.fill(gtx.scene, ref, color)
}

// 2. The estoile as the arms bear it: six wavy rays, sable.
mark_estoile :: proc(gtx: ^ui.Ctx, k: Ink) {
	fill_star(gtx, star({50, 50}, 47), k.ink)
}

// 3. The estoile with the sunburst's habit: one ray lit, the largest folder.
mark_lit_ray :: proc(gtx: ^ui.Ctx, k: Ink) {
	s := star({50, 50}, 47)
	fill_star(gtx, s, k.ink)
	fill_ray(gtx, s, 1, k.accent)
}

// 4. The estoile pierced, heraldry's word for a hole through a charge: the
// sunburst's hub, inverted.
mark_pierced :: proc(gtx: ^ui.Ctx, k: Ink) {
	s := star({50, 50}, 47)
	s.valley = 47 * 0.36
	b := mark.pb(gtx)
	star_outline(&b, s)
	circle_path(&b, {50, 50}, 8)
	even_odd(gtx, &b, k.ink)
	fill_ray(gtx, s, 1, k.accent)
}

// 5. The estoile as data: each ray as long as a folder is large, the
// largest lit. A sunburst with one ring, drawn as a star.
mark_sized_rays :: proc(gtx: ^ui.Ctx, k: Ink) {
	s := star({50, 50}, 47, rot = rad(-60))
	s.reach = {47, 39, 34, 30, 27, 25}
	s.valley = 11
	s.amp = 1.5
	fill_star(gtx, s, k.ink)
	fill_ray(gtx, s, 0, k.accent)
}

// 6. The star of cells, the chosen mark: the sunburst's own cells, each
// sending a slim ray out from the middle of its outer arc. Its geometry is
// gui/mark's, which the window and branding/ draw too.
mark_star_of_cells :: proc(gtx: ^ui.Ctx, k: Ink) {
	mark.draw_box(gtx, k.ink, k.accent)
}

// shield_path is a heater shield filling most of the box.
shield_path :: proc(gtx: ^ui.Ctx) -> ops.Path_Ref {
	b := mark.pb(gtx)
	mark.pb_move(&b, {14, 8})
	mark.pb_line(&b, {86, 8})
	mark.pb_line(&b, {86, 46})
	mark.pb_cubic(&b, {86, 70}, {70, 86}, {50, 95})
	mark.pb_cubic(&b, {30, 86}, {14, 70}, {14, 46})
	mark.pb_close(&b)
	return mark.pb_done(gtx, &b)
}

// luma is a colour's rough brightness, enough to tell ink from paper.
luma :: proc(c: ops.Color) -> f32 {
	return 0.299 * f32(c.r) + 0.587 * f32(c.g) + 0.114 * f32(c.b)
}

// 7. The Mordaunt arms: argent, a chevron between three estoiles sable. The
// tinctures hold in either scheme: the field takes the lighter of ink and
// paper, the charges the darker.
mark_arms :: proc(gtx: ^ui.Ctx, k: Ink) {
	argent, sable := k.paper, k.ink
	if luma(argent) < luma(sable) {
		argent, sable = sable, argent
	}
	shield := shield_path(gtx)
	ops.fill(gtx.scene, shield, argent)
	ops.clip_push(gtx.scene, shield)
	b := mark.pb(gtx)
	mark.pb_move(&b, {50, 37})
	mark.pb_line(&b, {100, 87})
	mark.pb_line(&b, {100, 101})
	mark.pb_line(&b, {50, 51})
	mark.pb_line(&b, {0, 101})
	mark.pb_line(&b, {0, 87})
	mark.pb_close(&b)
	ops.fill(gtx.scene, mark.pb_done(gtx, &b), sable)
	ops.clip_pop(gtx.scene)
	fill_star(gtx, star({31, 25}, 11), sable)
	fill_star(gtx, star({69, 25}, 11), sable)
	fill_star(gtx, star({50, 74}, 11), sable)
	ops.stroke(gtx.scene, shield, sable, stroke_w(4))
}

// 8. The estoile knocked out of a roundel, for small sizes and favicons.
mark_roundel :: proc(gtx: ^ui.Ctx, k: Ink) {
	b := mark.pb(gtx)
	circle_path(&b, {50, 50}, 46)
	star_outline(&b, star({50, 50}, 36))
	even_odd(gtx, &b, k.ink)
}

// 9. The app-icon form: the estoile in paper on an ink tile, one ray lit.
mark_app_tile :: proc(gtx: ^ui.Ctx, k: Ink) {
	ops.fill(gtx.scene, ops.Round_Rect{{6, 6, 88, 88}, 22}, k.ink)
	s := star({50, 50}, 36)
	fill_star(gtx, s, k.paper)
	fill_ray(gtx, s, 1, k.accent)
}
