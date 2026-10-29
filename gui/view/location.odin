package leita_view

import "core:strings"

import "jm:ui"
import "jm:ui/design"
import "jm:ui/ops"
import "jm:ui/primer"

import "../command"
import "../query"

/*
The location bar: where the window is, and where it can go. It is the only place
the window spells out a path in full.

At rest it is the path to the directory at the centre of the sunburst, a step
for each directory from the top of the filesystem down. Those inside the scan open
their directory; those above where the scan began are muted, and scan from there.
The steps sit in a window onto them that shows the deepest, letting the top
fade off its left edge, and that scrolls sideways under the wheel or a trackpad
with no bar.

A click on the bar's empty end, on the current step, or Cmd/Ctrl+L, turns it into a
field holding the path: Enter scans what it holds, Escape or a click away puts the
steps back. With no scan yet, or one that failed, it is the field. A path that fills
the bar has no empty end; a click on the current step is then what still opens it.
*/

// LOCATION_HEIGHT is the bar's height, Primer's medium control.
LOCATION_HEIGHT :: f32(32)

// LOCATION_FADE is how far the steps fade out at an edge they run past.
LOCATION_FADE :: f32(40)

// LOCATION_PAD is the space inside the bar's ends, before the first step and after
// the last.
LOCATION_PAD :: f32(6)

// TRAIL_BUTTON is the room at the trail's right end each of its buttons,
// the folder and the magnifier, takes, and TRAIL_GAP the well left bare
// between the steps and them.
TRAIL_BUTTON :: f32(30)
TRAIL_GAP :: f32(4)

// SCAN_PICK is the area the folder dialog the bar opens answers.
@(private)
SCAN_PICK :: ops.Area_Id(0x6c65_6974_7363_616e) // "leitscan"

// take_scan_pick scans the folder the bar's dialog chose. A cancel, or a
// platform with no dialog to show, leaves things as they are; a path too
// long to send opens the field holding it, saying so.
@(private)
take_scan_pick :: proc(gtx: ^ui.Ctx, m: ^Model) {
	for e in ui.events(gtx, SCAN_PICK) {
		if e.kind != .Picked || e.text == "" {
			continue
		}
		req := command.Scan {
			path = command.text_make(e.text),
		}
		if req.path.cut {
			edit_location(m, e.text)
			m.path_long = true
			continue
		}
		close_search(m)
		ui.command(gtx, command.Command(req))
		m.editing, m.path_long = false, false
	}
}

// Step is one step of the location.
Step :: struct {
	label:   string,
	path:    string, // above the scan: the path to scan from
	node:    u32, // in the scan: the directory
	inside:  bool, // in the scan, opened by node; else above it, scanned from path
	current: bool, // the directory at the centre
}

/*
steps_of is the location as steps: the top of the scan's own path split into the
directories above it, then the crumbs from the top of the scan down. The top's
name is a whole path, as the reader names it.
*/
@(private)
steps_of :: proc(gtx: ^ui.Ctx, crumbs: []query.Crumb) -> []Step {
	sep := separator(crumbs)
	top := crumbs[0].name
	out := make([dynamic]Step, gtx.allocator)
	parts := strings.split(strings.trim_right(top, sep), sep, gtx.allocator)
	if len(parts) <= 1 || top == sep {
		append(&out, Step{label = safe(gtx, top), node = crumbs[0].node, inside = true})
	} else {
		sb := strings.builder_make(gtx.allocator)
		for part, i in parts[:len(parts) - 1] {
			if i > 0 || part != "" {
				strings.write_string(&sb, part)
			}
			strings.write_string(&sb, sep)
			label := safe(gtx, part) if part != "" else sep
			append(
				&out,
				Step{label = label, path = strings.clone(strings.to_string(sb), gtx.allocator)},
			)
		}
		append(
			&out,
			Step{label = safe(gtx, parts[len(parts) - 1]), node = crumbs[0].node, inside = true},
		)
	}
	for c in crumbs[1:] {
		append(&out, Step{label = safe(gtx, c.name), node = c.node, inside = true})
	}
	out[len(out) - 1].current = true
	return out[:]
}

// location draws the bar across what it is offered, the trail keeping room
// clear at its right end. It says whether it drew the trail rather than the
// field.
@(private)
location :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result, room: f32 = 0) -> bool {
	r, _ := ui.need(gtx, query.Rings{generation = m.generation, dir = m.dir}, query.Rings_Result)
	if r != nil && r.generation == m.generation && r.gone {
		leave_gone(m, r.up)
		ui.request_frame(gtx)
	}
	if r != nil && r.generation == m.generation && len(r.crumbs) > 0 {
		keep_trail(m, r.crumbs)
	}
	if !trail_shows(m, prog) {
		location_field(gtx, m, len(m.trail) > 0 && m.trail_generation == m.generation)
		return false
	}
	trail(gtx, m, steps_of(gtx, m.trail[:]), crumb_path(gtx, m.trail[:]), room)
	return true
}

// trail_shows is whether the bar shows the trail rather than the field. Until
// the answer for a directory just opened lands, it shows the trail it had,
// rather than dropping to the field for those frames.
@(private)
trail_shows :: proc(m: ^Model, prog: ^query.Progress_Result) -> bool {
	have := len(m.trail) > 0 && m.trail_generation == m.generation
	return have && !m.editing && prog != nil && prog.state != .Failed
}

// keep_trail copies crumbs, the way to the directory the bar shows, into the
// model when they differ from what it holds: the answer they came in is replaced
// every tick and gone when the next directory is asked for.
@(private)
keep_trail :: proc(m: ^Model, crumbs: []query.Crumb) {
	same := len(crumbs) == len(m.trail) && m.trail_generation == m.generation
	for c, i in crumbs {
		if !same {
			break
		}
		same = c.node == m.trail[i].node && c.name == m.trail[i].name
	}
	if same {
		return
	}
	forget_trail(m)
	for c in crumbs {
		append(&m.trail, query.Crumb{c.node, strings.clone(c.name)})
	}
	m.trail_generation = m.generation
	// A new place: show its deepest steps again.
	m.location_follow = true
}

forget_trail :: proc(m: ^Model) {
	for c in m.trail {
		delete(c.name)
	}
	clear(&m.trail)
}

// STEP_PAD is the space either side of a step's name, and CHEVRON the width
// of the mark between two steps.
STEP_PAD :: f32(6)
CHEVRON  :: f32(16)

/*
trail is the bar at rest, one widget: the field's well, the steps laid along a
strip inside it, clipped to it and moved by how far it is scrolled, and fades at
an edge the steps run past. The strip is laid out here rather than as a row of
widgets, since a row gives what it cannot fit no width at all, and the bar has to
know how long the strip is to scroll it. Each step takes the pointer through an
area of its own; the well beneath takes the wheel, and a press on its empty end
or on the current step opens the field.
*/
@(private)
trail :: proc(gtx: ^ui.Ctx, m: ^Model, steps: []Step, here: string, room: f32 = 0, loc := #caller_location) {
	// The width is read inside the widget: a flexible slot's share is set as the
	// widget opens, and before that the constraints are the whole row's.
	p := ui.widget_open(gtx, loc = loc)
	width := gtx.constraints.max.x
	if !ui.is_finite(width) {
		width = 480
	}
	box := ops.Rect{0, 0, width, LOCATION_HEIGHT}

	// Lay the steps out: each a name with room either side, a chevron between.
	Laid :: struct {
		para: ui.Paragraph,
		x, w: f32,
	}
	laid := make([]Laid, len(steps), gtx.allocator)
	x: f32
	for s, i in steps {
		if i > 0 {
			x += CHEVRON
		}
		st := primer.text_style(.Medium, .Semibold if s.current else .Normal)
		para := design.layout_style(gtx, s.label, st, primer.font_for(gtx, st.weight))
		laid[i] = {para, x, para.width + 2 * STEP_PAD}
		x += laid[i].w
	}
	most := max(x + 2 * LOCATION_PAD + room - width, 0)
	if m.location_follow {
		m.location_offset = most
	}

	for e in ui.events(gtx, p.id) {
		#partial switch e.kind {
		case .Scroll:
			// A trackpad's sideways swipe, or the wheel, which most mice have only.
			// A unit is a wheel's notch; jm's scroll boxes move SCROLL_STEP for one.
			delta := e.scroll.x if e.scroll.x != 0 else e.scroll.y
			m.location_offset = clamp(m.location_offset + delta * ui.SCROLL_STEP, 0, most)
			m.location_follow = false
		case .Press:
			if e.button == .Left {
				edit_location(m, here)
			}
		}
	}
	m.location_offset = clamp(m.location_offset, 0, most)

	well := ops.Round_Rect{box, 6}
	bg := primer.color(.Control_Bg_Color_Rest)
	ops.fill(gtx.scene, well, bg)
	ops.input_area(gtx.scene, p.id, box, {.Press, .Scroll}, .Text)

	ops.clip_push(gtx.scene, ops.Round_Rect{{1, 1, width - 2 - room, LOCATION_HEIGHT - 2}, 0 if room > 0 else 5})
	shift := LOCATION_PAD - m.location_offset
	step_h := LOCATION_HEIGHT - 8
	for s, i in steps {
		l := laid[i]
		if i > 0 {
			primer.icon(
				gtx,
				.Chevron_Right,
				{shift + l.x - CHEVRON, (LOCATION_HEIGHT - 16) / 2},
				16,
				primer.color(.Fg_Color_Muted),
			)
		}
		id := ui.id_mix(p.id, u64(i + 1))
		rect := ops.Rect{shift + l.x, 4, l.w, step_h}
		c := design.control(gtx, id, rect, .Live)
		if c.hovered && !s.current {
			ops.fill(
				gtx.scene,
				ops.Round_Rect{rect, 4},
				primer.color(.Control_Transparent_Bg_Color_Hover),
			)
		}
		ink := primer.color(.Fg_Color_Default if s.inside else .Fg_Color_Muted)
		design.draw_paragraph(
			gtx,
			l.para,
			{rect.x + STEP_PAD, rect.y + (step_h - l.para.height) / 2},
			ink,
		)
		design.listen(gtx, c.st, id, rect, design.CLICK_KINDS, .Default if s.current else .Pointer)
		ops.tag(gtx.scene, id, s.label)
		if c.clicked {
			switch {
			case s.current:
				// Already here: a full bar has no empty end, so this click opens the field.
				edit_location(m, here)
			case s.inside:
				open(m, s.node)
			case:
				ui.command(gtx, command.Command(command.Scan{path = command.text_make(s.path)}))
			}
		}
	}

	// Fades where the strip runs past an edge, so a cut step reads as going on.
	// They are inside the clip, which rounds them into the well's corners, and
	// under the border, which is drawn last so nothing paints over it.
	clear := bg
	clear[3] = 0
	fade :: proc(gtx: ^ui.Ctx, x0, x1: f32, from, to: ops.Color) {
		stops := make([]ops.Gradient_Stop, 2, gtx.allocator)
		stops[0], stops[1] = {0, from}, {1, to}
		r := ops.Rect{min(x0, x1), 0, abs(x1 - x0), LOCATION_HEIGHT}
		ops.fill(gtx.scene, r, ops.Linear_Gradient{{x0, 0}, {x1, 0}, stops})
	}
	if m.location_offset > 0.5 {
		fade(gtx, 0, LOCATION_FADE, bg, clear)
	}
	if m.location_offset < most - 0.5 {
		fade(gtx, width - room - LOCATION_FADE, width - room, clear, bg)
	}
	ops.clip_pop(gtx.scene)
	ops.stroke(gtx.scene, well, primer.color(.Border_Color_Default), {width = 1})

	ops.tag(gtx.scene, p.id, tr(.Location))
	ui.semantics(
		gtx,
		&p,
		{role = .Navigation, label = tr(.Location), value = ui.frame_string(gtx, safe(gtx, here))},
	)
	ui.widget_close(gtx, &p, {size = {width, LOCATION_HEIGHT}})
}

// edit_location turns the bar into the field, holding the path shown.
@(private)
edit_location :: proc(m: ^Model, here: string) {
	if m.editing {
		return
	}
	ui.text_set(&m.path, here)
	ui.text_select(&m.path, 0, len(here))
	m.editing, m.edit_focus, m.path_long = true, true, false
}

// location_field is the bar as a field: Enter scans its path, Escape or a click
// away puts the steps back, when there are steps to put back.
@(private)
location_field :: proc(gtx: ^ui.Ctx, m: ^Model, have: bool) {
	field := primer.text_input(
		gtx,
		&m.path,
		placeholder = tr(.Location_Placeholder),
		leading = .File_Directory,
		action = .File_Directory,
		action_name = tr(.Scan_Choose),
		block = true,
		name = tr(.Location),
	)
	if field.action {
		ui.pick_folder(gtx, SCAN_PICK, strings.trim_space(ui.text_string(&m.path)))
	}
	if m.edit_focus {
		if field.focused {
			m.edit_focus = false
		} else {
			ui.focus_request(gtx, field.id)
		}
	}
	for e in ui.events(gtx, field.id) {
		if e.kind == .Key && e.key == .Escape {
			m.editing, m.path_long = false, false
			m.bar_focus = true
		}
	}
	if field.submitted {
		path := strings.trim_space(ui.text_string(&m.path))
		req := command.Scan {
			path = command.text_make(path),
		}
		switch {
		case req.path.cut:
			// Sent cut, it would scan an ancestor of what was typed; the field
			// stays so the path can be shortened.
			m.path_long = true
		case path != "":
			ui.command(gtx, command.Command(req))
			m.editing, m.path_long = false, false
			m.bar_focus = true
		case:
			m.editing = false
			m.bar_focus = true
		}
	}
	if m.editing && !m.edit_focus && !field.focused && have {
		m.editing, m.path_long = false, false // focus went elsewhere
	}
}
