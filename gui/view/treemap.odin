package sonar_view

import "core:fmt"
import "core:math"

import "jm:ui"
import "jm:ui/design"
import "jm:ui/ops"
import "jm:ui/primer"

import "../query"

/*
The directory shown as a treemap: a box for each entry, sized by what it holds,
and inside each directory's box the boxes of what it holds, down as far as the
sunburst's rings go. It draws the same answer as the sunburst (query.Rings), so the
two always agree, laid out here rather than by the host because the shapes depend
on the room the window gives it.

The layout is squarified (Bruls, Huizing and van Wijk, 2000): a directory's
entries, largest first, go into rows across its box, each row taking entries while
that brings its boxes nearer square, so boxes stay easy to compare and to point at.
A directory big enough for one shows its name in a strip along its top.

A click on a directory's box opens it, and a click on a file the directory holding
it; a right click opens the entry's menu, and
the boxes ease from one layout to the next as the sunburst's arcs do.
*/

// Mode is how the window draws the directory shown.
Mode :: enum u8 {
	Sunburst,
	Treemap,
}

// mode_switch is the segmented control that picks the mode. A new mode starts its
// shapes from nothing, so it grows in.
@(private)
mode_switch :: proc(gtx: ^ui.Ctx, m: ^Model) {
	// In Mode's order: the selected segment's index is the mode.
	modes := [?]primer.Segment {
		{label = "Sunburst", icon = .Circle},
		{label = "Treemap", icon = .Apps},
	}
	#assert(len(modes) == len(Mode))
	at := int(m.mode)
	if primer.segmented_control(gtx, modes[:], &at, name = "View", size = .Small) {
		m.mode = Mode(at)
		m.menu_open = false
		clear(&m.poses)
		clear(&m.boxes)
	}
}

// TREE_HEADER is a directory's name strip, TREE_PAD the inset its contents keep
// from its edge, and TREE_LABEL_MIN the narrowest box that is labelled.
TREE_HEADER    :: f32(18)
TREE_PAD       :: f32(2)
TREE_LABEL_MIN :: f32(44)

// Box is one entry laid out: the arc it draws, its box, and for a directory the
// box its contents go in and whether it has room for its name.
Box :: struct {
	arc:    int,
	rect:   ops.Rect,
	inner:  ops.Rect,
	header: bool,
}

/*
lay_boxes lays r's arcs out as boxes within room, each directory's contents within
its box. An entry's box is its share of what holds it; the share the host left out,
entries too small to draw, is left empty at the end of the last row.
*/
@(private)
lay_boxes :: proc(gtx: ^ui.Ctx, r: ^query.Rings_Result, room: ops.Rect) -> []Box {
	// Each arc's index is its contents' slot, after the top's at 0.
	kids := make([][dynamic]int, len(r.arcs) + 1, gtx.allocator)
	for &k in kids {
		k = make([dynamic]int, gtx.allocator)
	}
	for a, i in r.arcs {
		append(&kids[a.up + 1], i)
	}
	boxes := make([dynamic]Box, gtx.allocator)
	place(gtx, r, kids, 0, room, f64(r.bytes), &boxes)
	return boxes[:]
}

@(private)
place :: proc(
	gtx: ^ui.Ctx,
	r: ^query.Rings_Result,
	kids: [][dynamic]int,
	slot: int,
	area: ops.Rect,
	total: f64,
	boxes: ^[dynamic]Box,
) {
	items := kids[slot][:]
	if len(items) == 0 || total <= 0 || area.w < 1 || area.h < 1 {
		return
	}
	space := f64(area.w) * f64(area.h)
	sizes := make([]f32, len(items) + 1, gtx.allocator)
	used: f64
	for it, i in items {
		share := space * f64(r.arcs[it].bytes) / total
		sizes[i] = f32(share)
		used += share
	}
	sizes[len(items)] = f32(max(space - used, 0))
	rects := squarify(gtx, sizes, area)
	for it, i in items {
		rect := rects[i]
		b := Box {
			arc  = it,
			rect = rect,
		}
		if r.arcs[it].directory {
			b.inner = {
				rect.x + TREE_PAD,
				rect.y + TREE_PAD,
				rect.w - 2 * TREE_PAD,
				rect.h - 2 * TREE_PAD,
			}
			if rect.h >= 2 * TREE_HEADER && rect.w >= TREE_LABEL_MIN {
				b.header = true
				b.inner.y += TREE_HEADER - TREE_PAD
				b.inner.h -= TREE_HEADER - TREE_PAD
			}
		}
		append(boxes, b)
		if r.arcs[it].directory {
			place(gtx, r, kids, it + 1, b.inner, f64(r.arcs[it].bytes), boxes)
		}
	}
}

/*
squarify divides area among sizes, areas that sum to it, in order: a row at a
time along the area's shorter side, each row taking sizes while that does not make
its worst box less square, then the rest of the area holding the rest.
*/
@(private)
squarify :: proc(gtx: ^ui.Ctx, sizes: []f32, area: ops.Rect) -> []ops.Rect {
	out := make([]ops.Rect, len(sizes), gtx.allocator)
	rest := area
	i := 0
	for i < len(sizes) {
		side := min(rest.w, rest.h)
		if side <= 0 {
			break
		}
		j := i + 1
		best := worst(sizes[i:j], side)
		for j < len(sizes) {
			next := worst(sizes[i:j + 1], side)
			if next > best {
				break
			}
			best = next
			j += 1
		}
		sum: f32
		for v in sizes[i:j] {
			sum += v
		}
		if rest.w >= rest.h {
			// A column down the left of what is left.
			w := sum / rest.h
			y := rest.y
			for k in i ..< j {
				h := sizes[k] / w if w > 0 else 0
				out[k] = {rest.x, y, w, h}
				y += h
			}
			rest.x += w
			rest.w -= w
		} else {
			// A row along the top.
			h := sum / rest.w
			x := rest.x
			for k in i ..< j {
				w := sizes[k] / h if h > 0 else 0
				out[k] = {x, rest.y, w, h}
				x += w
			}
			rest.y += h
			rest.h -= h
		}
		i = j
	}
	return out
}

// worst is how far from square the least square box of a row along side would be:
// its longer edge over its shorter.
@(private)
worst :: proc(row: []f32, side: f32) -> f32 {
	sum, most: f32
	least := f32(math.F32_MAX)
	for v in row {
		sum += v
		most = max(most, v)
		least = min(least, v)
	}
	if sum <= 0 || least <= 0 {
		return math.F32_MAX
	}
	s2, w2 := sum * sum, side * side
	return max(w2 * most / s2, s2 / (w2 * least))
}

/*
ease_boxes moves each box part of the way from where it was drawn toward where the
layout puts it, as ease does for arcs: a new box grows from nothing at its centre,
a new centre or scan starts every box from nothing, and frames are asked for only
while a box is moving.
*/
@(private)
ease_boxes :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Rings_Result, boxes: []Box) {
	if m.boxes_dir != r.dir || m.boxes_generation != r.generation {
		clear(&m.boxes)
		m.boxes_dir, m.boxes_generation = r.dir, r.generation
	}
	k := gtx.reduce_motion ? 1 : 1 - math.exp(-EASE_RATE * gtx.dt)
	clear(&m.boxes_next)
	moving := false
	toward :: proc(was, to: ops.Rect, k: f32) -> ops.Rect {
		return {
			was.x + (to.x - was.x) * k,
			was.y + (to.y - was.y) * k,
			was.w + (to.w - was.w) * k,
			was.h + (to.h - was.h) * k,
		}
	}
	for &b in boxes {
		node := r.arcs[b.arc].node
		was, seen := m.boxes[node]
		if !seen {
			was = {b.rect.x + b.rect.w / 2, b.rect.y + b.rect.h / 2, 0, 0}
		}
		now := toward(was, b.rect, k)
		if abs(now.x - b.rect.x) +
			   abs(now.y - b.rect.y) +
			   abs(now.w - b.rect.w) +
			   abs(now.h - b.rect.h) <
		   0.5 {
			now = b.rect
		} else {
			moving = true
		}
		b.rect = now
		m.boxes_next[node] = now
	}
	m.boxes, m.boxes_next = m.boxes_next, m.boxes
	if moving {
		ui.request_frame(gtx)
	}
}

// box_at is the deepest box at p, or -1.
@(private)
box_at :: proc(boxes: []Box, p: ops.Point) -> int {
	#reverse for b, i in boxes {
		if ops.rect_contains(b.rect, p) {
			return i
		}
	}
	return -1
}

// treemap_panel is the treemap with the info block over it.
@(private)
treemap_panel :: proc(gtx: ^ui.Ctx, m: ^Model, answer: ^query.Rings_Result) {
	// Laid out for the room the treemap had last frame: the block comes before
	// the treemap that would measure it this frame.
	boxes := lay_boxes(gtx, answer, {0, 0, m.tree_room.x, m.tree_room.y})
	ease_boxes(gtx, m, answer, boxes)
	u, at := Hit.Nothing, -1
	if i := box_at(boxes, m.pointer); m.inside && i >= 0 {
		u, at = .Arc, boxes[i].arc
	}
	info(gtx, answer, answer, u, at)
	ui.flexible(gtx, 1)
	treemap(gtx, m, answer, boxes, at)
}

// treemap draws the boxes across the room it is offered and acts on what is
// clicked.
@(private)
treemap :: proc(
	gtx: ^ui.Ctx,
	m: ^Model,
	r: ^query.Rings_Result,
	boxes: []Box,
	hovered: int,
	loc := #caller_location,
) {
	p := ui.widget_open(gtx, loc = loc)
	size := gtx.constraints.max
	if !ui.is_finite(size.x) || !ui.is_finite(size.y) {
		size = {480, 360}
	}
	m.tree_room = size
	pressed, menu := false, false
	for e in ui.events(gtx, p.id) {
		#partial switch e.kind {
		case .Move, .Enter:
			m.pointer, m.inside = e.pos, true
		case .Leave:
			m.inside = false
		case .Press:
			m.pointer, m.inside = e.pos, true
			#partial switch e.button {
			case .Left:
				pressed = true
			case .Right:
				menu = true
			}
		}
	}

	bg := primer.color(.Bg_Color_Default)
	small := primer.text_style(.Small)
	font := primer.font_for(gtx, small.weight)
	for b in boxes {
		a := r.arcs[b.arc]
		if b.rect.w < 1 || b.rect.h < 1 {
			continue
		}
		fill := primer.color(BRANCHES[int(a.branch) % len(BRANCHES)])
		if b.arc != hovered {
			// A directory is the frame its contents sit in, so it is lighter than
			// what fills it.
			fade := FADE * f32(a.depth - 1) + (a.directory ? 0.45 : FILE_FADE)
			fill = mix(fill, bg, min(fade, 0.85))
		}
		ops.fill(gtx.scene, b.rect, fill)
		ops.stroke(gtx.scene, b.rect, bg, {width = 1})
		labelled :=
			b.header || (!a.directory && b.rect.w >= TREE_LABEL_MIN && b.rect.h >= TREE_HEADER)
		if labelled {
			para := design.layout_style(gtx, a.name, small, font)
			ops.clip_push(gtx.scene, ops.Rect{b.rect.x, b.rect.y, b.rect.w - TREE_PAD, b.rect.h})
			design.draw_paragraph(
				gtx,
				para,
				{b.rect.x + 4, b.rect.y + 2},
				primer.readable_text(fill),
			)
			ops.clip_pop(gtx.scene)
		}
		if a.depth == 1 {
			ops.tag(
				gtx.scene,
				ui.id_mix(p.id, u64(b.arc + 1)),
				fmt.aprintf("box %s", a.name, allocator = gtx.allocator),
				b.rect,
			)
		}
	}

	room := ops.Rect{0, 0, size.x, size.y}
	ops.input_area(gtx.scene, p.id, room, {.Press, .Move, .Enter, .Leave})
	ops.tag(gtx.scene, p.id, "Treemap chart")

	if menu {
		if i := box_at(boxes, m.pointer); i >= 0 {
			a := r.arcs[boxes[i].arc]
			aim(m, {node = a.node, name = a.name, directory = a.directory})
			m.menu_open, m.menu_at, m.menu_from = true, m.pointer, .Treemap
		}
	}
	if m.menu_from == .Treemap {
		entry_menu(gtx, m, {p.id, {0, 0}}, m.menu_at)
	}
	ui.widget_close(gtx, &p, {size = size})

	// A directory's contents cover most of its box, so a click on a file opens the
	// directory holding it, which is the one the pointer was in.
	if pressed {
		if i := box_at(boxes, m.pointer); i >= 0 {
			a := r.arcs[boxes[i].arc]
			switch {
			case a.directory:
				open(m, a.node)
			case a.up >= 0:
				open(m, r.arcs[a.up].node)
			}
		}
	}
}
