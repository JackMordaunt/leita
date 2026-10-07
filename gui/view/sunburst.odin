package sonar_view

import "core:fmt"
import "core:math"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import tok "jm:ui/primer/tokens"

import "../../human"
import "../query"

/*
The directory shown, as a sunburst: its contents in the first ring around a hub,
theirs in the next, each arc's sweep its share of its parent's. A click on a
directory's arc opens it, which makes it the hub; a click on the hub goes up.

Every arc is one entry the host laid out (query.Rings); the view only turns turns
into radians. Hit testing is done here rather than per arc: the disc is one input
area, and the pointer's angle and distance from the centre name the arc under it.
*/

// BRANCHES colour the first ring's entries in turn, and everything under each the
// same hue, lighter with every ring. jm's Primer tokens hold no categorical
// palette, so these are its emphasis colours, which every theme binds to
// distinct hues.
@(rodata)
BRANCHES := [?]tok.Role {
	.Bg_Color_Accent_Emphasis,
	.Bg_Color_Success_Emphasis,
	.Bg_Color_Done_Emphasis,
	.Bg_Color_Attention_Emphasis,
	.Bg_Color_Severe_Emphasis,
	.Bg_Color_Sponsors_Emphasis,
	.Bg_Color_Danger_Emphasis,
}

// HUB is the hub's radius as a share of the whole.
HUB :: f32(0.18)

// FADE is how much of the background each ring further out mixes in, and
// FILE_FADE how much more a file's arc takes than a directory's.
FADE      :: f32(0.13)
FILE_FADE :: f32(0.2)

// BURST_MIN is the smallest the sunburst is drawn, whatever it is offered.
BURST_MIN :: f32(160)

// Burst is the sunburst's geometry at one size.
@(private)
Burst :: struct {
	center: ops.Point,
	hub:    f32,
	ring:   f32, // each ring's width
}

@(private)
burst_of :: proc(side: f32) -> Burst {
	r := side / 2 - 2
	hub := r * HUB
	return {{side / 2, side / 2}, hub, (r - hub) / query.RING_DEPTH}
}

// Hit is what a point over the sunburst lands on.
@(private)
Hit :: enum u8 {
	Nothing,
	Hub,
	Arc,
}

// hit_at names the arc at p, or the hub.
@(private)
hit_at :: proc(r: ^query.Rings_Result, b: Burst, p: ops.Point) -> (u: Hit, arc: int) {
	dx, dy := p.x - b.center.x, p.y - b.center.y
	dist := math.sqrt(dx * dx + dy * dy)
	if dist <= b.hub {
		return .Hub, -1
	}
	depth := int((dist - b.hub) / b.ring) + 1
	if depth > query.RING_DEPTH {
		return .Nothing, -1
	}
	// Turns clockwise from twelve o'clock, as the host lays them out.
	t := (math.atan2(dy, dx) + math.PI / 2) / math.TAU
	t -= math.floor(t)
	for a, i in r.arcs {
		if int(a.depth) == depth && t >= a.start && t < a.start + a.sweep {
			return .Arc, i
		}
	}
	return .Nothing, -1
}

// rings_panel is the sunburst with the way to it above and what the pointer is
// over below it.
@(private)
rings_panel :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ui.column(gtx, gap = 8, align = .Fill)
	r, _ := ui.need(gtx, query.Rings{generation = m.generation, dir = m.dir}, query.Rings_Result)
	if r == nil || r.generation != m.generation || len(r.crumbs) == 0 {
		primer.skeleton_box(gtx, width = 320, height = 320, delay = .Short)
		return
	}

	items := make([]primer.Breadcrumb, len(r.crumbs), gtx.allocator)
	for c, i in r.crumbs {
		items[i] = {
			label    = c.name,
			selected = i == len(r.crumbs) - 1,
		}
	}
	if at := primer.breadcrumbs(gtx, items); at >= 0 && at < len(r.crumbs) - 1 {
		open(m, r.crumbs[at].node)
	}

	// What the pointer is over, as of the last frame's size: the caption comes
	// before the disc that would measure it this frame.
	b := burst_of(m.burst)
	u, at := hit_at(r, b, m.pointer)
	if !m.inside {
		u = .Nothing
	}
	primer.text(gtx, caption(gtx, r, u, at), .Small, color = primer.color(.Fg_Color_Muted))

	ui.flexible(gtx, 1)
	if ui.column(gtx, align = .Center) {
		sunburst(gtx, m, r, u == .Arc ? at : -1)
	}
}

@(private)
caption :: proc(gtx: ^ui.Ctx, r: ^query.Rings_Result, u: Hit, at: int) -> string {
	here := r.crumbs[len(r.crumbs) - 1].name
	switch u {
	case .Arc:
		a := r.arcs[at]
		share := r.bytes > 0 ? 100 * f64(a.bytes) / f64(r.bytes) : 0
		return fmt.aprintf(
			"%s · %s · %.1f%% of %s%s",
			a.name,
			human.bytes(a.bytes),
			share,
			here,
			a.directory ? " · click to open" : "",
			allocator = gtx.allocator,
		)
	case .Hub:
		if len(r.crumbs) > 1 {
			return fmt.aprintf(
				"%s · %s · click to go up",
				here,
				human.bytes(r.bytes),
				allocator = gtx.allocator,
			)
		}
	case .Nothing:
	}
	return fmt.aprintf("%s · %s", here, human.bytes(r.bytes), allocator = gtx.allocator)
}

// sunburst draws r as a disc as large as it is offered, and opens what is clicked.
@(private)
sunburst :: proc(
	gtx: ^ui.Ctx,
	m: ^Model,
	r: ^query.Rings_Result,
	hovered: int,
	loc := #caller_location,
) {
	offer := gtx.constraints.max
	side := min(offer.x, offer.y)
	if !ui.is_finite(side) {
		side = min(offer.x, 520) if ui.is_finite(offer.x) else 520
	}
	side = max(side, BURST_MIN)
	m.burst = side
	b := burst_of(side)

	p := ui.widget_open(gtx, loc = loc)
	pressed := false
	for e in ui.events(gtx, p.id) {
		#partial switch e.kind {
		case .Move, .Enter:
			m.pointer, m.inside = e.pos, true
		case .Leave:
			m.inside = false
		case .Press:
			if e.button == .Left {
				m.pointer, m.inside = e.pos, true
				pressed = true
			}
		}
	}

	bg := primer.color(.Bg_Color_Default)
	for a, i in r.arcs {
		fill := primer.color(BRANCHES[int(a.branch) % len(BRANCHES)])
		if i != hovered {
			fade := FADE * f32(a.depth - 1) + (a.directory ? 0 : FILE_FADE)
			fill = mix(fill, bg, fade)
		}
		r0 := b.hub + b.ring * f32(a.depth - 1)
		shape := band(gtx, b.center, r0, r0 + b.ring, a.start, a.start + a.sweep)
		ops.fill(gtx.scene, shape, fill)
		ops.stroke(gtx.scene, shape, bg, {width = 1})
		if a.depth == 1 {
			ops.tag(gtx.scene, p.id, fmt.aprintf("arc %s", a.name, allocator = gtx.allocator))
		}
	}
	hub := ui.circle(b.center, b.hub - 1)
	ops.fill(gtx.scene, hub, primer.color(.Bg_Color_Muted))
	ops.stroke(gtx.scene, hub, primer.color(.Border_Color_Default), {width = 1})
	ops.tag(gtx.scene, p.id, "hub")

	ops.input_area(gtx.scene, p.id, ops.Rect{0, 0, side, side}, {.Press, .Move, .Enter, .Leave})
	ops.tag(gtx.scene, p.id, "Sunburst")
	ui.widget_close(gtx, &p, {size = {side, side}})

	if !pressed {
		return
	}
	switch u, at := hit_at(r, b, m.pointer); u {
	case .Arc:
		if r.arcs[at].directory {
			open(m, r.arcs[at].node)
		}
	case .Hub:
		if len(r.crumbs) > 1 {
			open(m, r.crumbs[len(r.crumbs) - 2].node)
		}
	case .Nothing:
	}
}

// --- geometry ------------------------------------------------------------------

// on_circle is the point at turn t, clockwise from twelve o'clock, on the circle
// of radius r about c.
@(private)
on_circle :: proc(c: ops.Point, r, t: f32) -> ops.Point {
	a := t * math.TAU - math.PI / 2
	return {c.x + r * math.cos(a), c.y + r * math.sin(a)}
}

// band is the ring between radii r0 and r1 from turn t0 to t1: one arc. Each
// stretch of a quarter turn or less is one cubic, within 0.03% of the circle.
@(private)
band :: proc(gtx: ^ui.Ctx, c: ops.Point, r0, r1, t0, t1: f32) -> ops.Path_Ref {
	verbs := make([dynamic]ops.Path_Verb, gtx.allocator)
	pts := make([dynamic]ops.Point, gtx.allocator)
	arc :: proc(
		verbs: ^[dynamic]ops.Path_Verb,
		pts: ^[dynamic]ops.Point,
		c: ops.Point,
		r, t0, t1: f32,
	) {
		n := max(1, int(math.ceil(abs(t1 - t0) * 4)))
		step := (t1 - t0) / f32(n)
		k := 4.0 / 3.0 * math.tan(step * math.TAU / 4) * r
		for i in 0 ..< n {
			s, e := t0 + f32(i) * step, t0 + f32(i + 1) * step
			as, ae := s * math.TAU - math.PI / 2, e * math.TAU - math.PI / 2
			p0, p1 := on_circle(c, r, s), on_circle(c, r, e)
			append(verbs, ops.Path_Verb.Cubic)
			append(
				pts,
				ops.Point{p0.x - k * math.sin(as), p0.y + k * math.cos(as)},
				ops.Point{p1.x + k * math.sin(ae), p1.y - k * math.cos(ae)},
				p1,
			)
		}
	}
	append(&verbs, ops.Path_Verb.Move)
	append(&pts, on_circle(c, r1, t0))
	arc(&verbs, &pts, c, r1, t0, t1)
	append(&verbs, ops.Path_Verb.Line)
	append(&pts, on_circle(c, r0, t1))
	arc(&verbs, &pts, c, r0, t1, t0)
	append(&verbs, ops.Path_Verb.Close)
	return {ops.add_path(gtx.scene, {verbs = verbs[:], points = pts[:]})}
}

// mix is a with t of b blended in.
@(private)
mix :: proc(a, b: ops.Color, t: f32) -> ops.Color {
	out: ops.Color
	for i in 0 ..< 3 {
		out[i] = u8(f32(a[i]) * (1 - t) + f32(b[i]) * t)
	}
	out[3] = 255
	return out
}
