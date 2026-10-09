package estoile_view

import "jm:ui"
import "jm:ui/design"
import "jm:ui/ops"
import "jm:ui/primer"

/*
A grip is the divider between two of the window's sections, dragged to share the
room between them: a vertical one between the sunburst and the side column, a
horizontal one between the two lists. It reports the drag and leaves the sharing
to its caller, which alone knows the limits. A double click is the caller's to
read too, and with focus the arrow keys step it.

It draws a hairline rule down its middle with three dots at the centre, the
rule turning accent and heavier while the pointer is over it or dragging it,
and it shows the resize cursor.
*/

// GRIP is a grip's thickness: the strip that takes the pointer, its rule down the
// middle.
GRIP :: f32(16)

// GRIP_STEP is how far an arrow key moves a focused grip.
GRIP_STEP :: f32(16)

// Grip_Event is what happened to a grip this frame.
Grip_Event :: struct {
	started:  bool, // a drag began
	dragging: bool, // a drag is under way, pull the distance it has come
	pull:     f32, // along the grip's travel, since the press: right or down is positive
	double:   bool, // double clicked
	step:     f32, // an arrow key's move, right or down positive
}

@(private)
Grip_Drag :: struct {
	dragging: bool,
	pull:     f32,
}

// grip draws a grip across what it is offered: a vertical one, travelling
// sideways (.Horizontal), as tall as it is offered, or a horizontal one, travelling
// up and down, as wide. name is what it is called; value says where it stands.
@(private)
grip :: proc(
	gtx: ^ui.Ctx,
	travel: ui.Axis,
	name, value: string,
	loc := #caller_location,
) -> (
	g: Grip_Event,
) {
	offer := gtx.constraints.max
	size := ops.Size{GRIP, offer.y} if travel == .Horizontal else ops.Size{offer.x, GRIP}
	if !ui.is_finite(size.x) || !ui.is_finite(size.y) {
		size = {GRIP, GRIP}
	}
	p := ui.widget_open(gtx, loc = loc)
	area := ops.Rect{0, 0, size.x, size.y}
	c := design.control(gtx, p.id, area, .Live)
	d := ui.widget_data(gtx, p.id, Grip_Drag)
	for e in ui.events(gtx, p.id) {
		#partial switch e.kind {
		case .Press:
			if e.button != .Left {
				continue
			}
			if e.clicks >= 2 {
				g.double = true
				continue
			}
			d^ = {
				dragging = true,
			}
			g.started = true
		case .Move:
			if d.dragging && c.pressed {
				d.pull += e.travel.x if travel == .Horizontal else e.travel.y
			}
		case .Release, .Cancel:
			d.dragging = false
		case .Key:
			#partial switch e.key {
			case .Left, .Up:
				g.step = -GRIP_STEP
			case .Right, .Down:
				g.step = GRIP_STEP
			}
		}
	}
	g.dragging, g.pull = d.dragging, d.pull

	active := d.dragging || c.hovered
	ink := primer.color(.Border_Color_Accent_Emphasis if active else .Border_Color_Default)
	weight: f32 = 2 if active else 1
	dot := primer.color(.Fg_Color_Muted)
	if travel == .Horizontal {
		ops.fill(gtx.scene, ops.Rect{size.x / 2 - weight / 2, 0, weight, size.y}, ink)
		for i in -1 ..= 1 {
			at := ops.Point{size.x / 2, size.y / 2 + f32(i) * 6}
			ops.fill(gtx.scene, ui.circle(at, 1.5), dot)
		}
	} else {
		ops.fill(gtx.scene, ops.Rect{0, size.y / 2 - weight / 2, size.x, weight}, ink)
		for i in -1 ..= 1 {
			at := ops.Point{size.x / 2 + f32(i) * 6, size.y / 2}
			ops.fill(gtx.scene, ui.circle(at, 1.5), dot)
		}
	}
	cursor := ops.Cursor.Resize_EW if travel == .Horizontal else ops.Cursor.Resize_NS
	design.listen(gtx, c.st, p.id, area, design.CLICK_KINDS, cursor)
	ops.tag(gtx.scene, p.id, name)
	ui.semantics(gtx, &p, {role = .Slider, label = name, value = value})
	ui.widget_close(gtx, &p, {size = size})
	return
}
