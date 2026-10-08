package sonar_view

import "core:fmt"
import "core:time"

import "jm:ui"
import "jm:ui/design"
import "jm:ui/ops"
import "jm:ui/primer"

import "../../human"
import "../command"
import "../query"

/*
Colouring by change: each entry by how it has grown or shrunk since a snapshot,
an earlier scan of the same place kept by the host (query.History). The legend
row names the snapshot compared with, as a pill that opens a menu of the others,
and the scale from shrank to grew.

An entry is unchanged within CHANGE_SAME of what it held, or within 2% of it;
grew or shrank a lot by half again or more. One not kept in the snapshot was
under 1 MiB then, or not there: if it holds more than that now, it is new as far
as the snapshot can tell, and counts as grew a lot; if less, it is too small to
say, and unchanged.
*/

Change :: enum u8 {
	Shrank_Much,
	Shrank,
	Same,
	Grew,
	Grew_Much,
}

// CHANGE_SAME is the least change that counts as a change.
CHANGE_SAME :: 64 << 10

/*
CHANGE_LIGHT and CHANGE_DARK are a diverging scale on Primer's light and dark
grounds: blue for shrank, orange for grew, each in two strengths, and a grey
between that recedes. Checked with the dataviz skill's validator over all pairs:
normal-vision ΔE at least 16.2 on white and 17.3 on dark, protan and deutan at
least 14.2 and 15.3, every step of each arm at least 2:1 against its ground; the
grey alone is under that, as the unchanged should be.

	node validate_palette.js "#0550ae,#5b9cf2,#b4bcc5,#e8914a,#b35000" \
		--mode light --surface "#ffffff" --pairs all
	node validate_palette.js "#6cb6ff,#2563b8,#3f4650,#a65a1c,#f69d50" \
		--mode dark --surface "#0d1117" --pairs all
*/
@(rodata)
CHANGE_LIGHT := [Change]ops.Color {
	.Shrank_Much = {0x05, 0x50, 0xae, 255},
	.Shrank      = {0x5b, 0x9c, 0xf2, 255},
	.Same        = {0xb4, 0xbc, 0xc5, 255},
	.Grew        = {0xe8, 0x91, 0x4a, 255},
	.Grew_Much   = {0xb3, 0x50, 0x00, 255},
}

@(rodata)
CHANGE_DARK := [Change]ops.Color {
	.Shrank_Much = {0x6c, 0xb6, 0xff, 255},
	.Shrank      = {0x25, 0x63, 0xb8, 255},
	.Same        = {0x3f, 0x46, 0x50, 255},
	.Grew        = {0xa6, 0x5a, 0x1c, 255},
	.Grew_Much   = {0xf6, 0x9d, 0x50, 255},
}

CHANGE_NAMES := [Change]string {
	.Shrank_Much = "Shrank a lot",
	.Shrank      = "Shrank",
	.Same        = "Unchanged",
	.Grew        = "Grew",
	.Grew_Much   = "Grew a lot",
}

// change_of is how an entry holding bytes changed from was, -1 when the snapshot
// did not keep it; unchanged as far as can be said while none is compared.
change_of :: proc(bytes: u64, was: i64, compared: bool) -> Change {
	if !compared {
		return .Same
	}
	if was < 0 {
		return .Grew_Much if bytes >= query.KEPT_MIN else .Same
	}
	then := u64(was)
	delta := bytes - then if bytes > then else then - bytes
	if delta < CHANGE_SAME || delta * 50 <= then {
		return .Same
	}
	much := delta * 2 >= then
	if bytes > then {
		return .Grew_Much if much else .Grew
	}
	return .Shrank_Much if much else .Shrank
}

// change_colour is a change's colour on the ground drawn on.
change_colour :: proc(c: Change) -> ops.Color {
	bg := primer.color(.Bg_Color_Default)
	dark := int(bg[0]) + int(bg[1]) + int(bg[2]) < 3 * 128
	return CHANGE_DARK[c] if dark else CHANGE_LIGHT[c]
}

// delta_text is how an entry holding bytes changed from was, as a signed size:
// "+1.2 GiB", "−300 MiB", "new", or "" when it is unchanged or cannot be said.
delta_text :: proc(
	bytes: u64,
	was: i64,
	compared: bool,
	allocator := context.temp_allocator,
) -> string {
	switch {
	case !compared:
		return ""
	case was < 0:
		return "new" if bytes >= query.KEPT_MIN else ""
	case u64(was) == bytes:
		return ""
	case bytes > u64(was):
		return fmt.aprintf("+%s", human.bytes(bytes - u64(was)), allocator = allocator)
	}
	return fmt.aprintf("−%s", human.bytes(u64(was) - bytes), allocator = allocator)
}

// change_note is how an entry changed, as a clause to follow its size: " · +1.2
// GiB since then", " · unchanged", or " · new since then".
change_note :: proc(gtx: ^ui.Ctx, bytes: u64, was: i64, compared: bool) -> string {
	d := delta_text(bytes, was, compared, gtx.allocator)
	switch {
	case !compared:
		return ""
	case d == "" && was >= 0:
		return " · unchanged"
	case d == "":
		return ""
	}
	return fmt.aprintf(" · %s since then", d, allocator = gtx.allocator)
}

// taken_text says when a snapshot was taken: today's by the time, this year's
// by the day, older ones by the year too.
taken_text :: proc(unix: i64, allocator := context.temp_allocator) -> string {
	t := time.unix(unix, 0)
	y, mon, d := time.date(t)
	ny, _, _ := time.date(time.now())
	h, mi, _ := time.clock(t)
	months := [time.Month]string {
		.January   = "Jan",
		.February  = "Feb",
		.March     = "Mar",
		.April     = "Apr",
		.May       = "May",
		.June      = "Jun",
		.July      = "Jul",
		.August    = "Aug",
		.September = "Sep",
		.October   = "Oct",
		.November  = "Nov",
		.December  = "Dec",
	}
	if y != ny {
		return fmt.aprintf("%d %s %d", d, months[mon], y, allocator = allocator)
	}
	return fmt.aprintf("%d %s %02d:%02d", d, months[mon], h, mi, allocator = allocator)
}

/*
change_legend is the legend row by change: the snapshot compared with, as a pill
that opens a menu of the others to compare with instead, then the scale. With no
earlier scan of the place, it says the next scan will be compared with this one.
*/
@(private)
change_legend :: proc(gtx: ^ui.Ctx, m: ^Model) {
	h, _ := ui.need(gtx, query.History{generation = m.generation}, query.History_Result)
	muted := primer.color(.Fg_Color_Muted)
	switch {
	case h == nil || h.generation != m.generation:
		return
	case !h.kept:
		primer.text(
			gtx,
			"Scans are not being kept, so there is nothing to compare with",
			.Small,
			color = muted,
		)
		return
	case len(h.snapshots) == 0:
		primer.text(
			gtx,
			"No earlier scan of this folder yet: the next scan will be compared with this one" if h.ready else "Comparing once the scan is done",
			.Small,
			color = muted,
		)
		return
	}
	if ui.wrap(gtx, gap = LEGEND_GAP, line_gap = LEGEND_LINE_GAP, align = .Center) {
		label := "Compare with…"
		if h.compared.id != 0 {
			label = fmt.aprintf(
				"Since %s",
				taken_text(h.compared.taken),
				allocator = gtx.allocator,
			)
		}
		if since_pill(gtx, label, m.since_open) {
			m.since_open = !m.since_open
		}
		anchor := ui.last_widget(gtx)
		since_menu(gtx, m, h, anchor)
		for c in Change {
			sc := ui.scope_open(gtx, c)
			if ui.row(gtx, gap = LEGEND_INSET, align = .Center) {
				swatch(gtx, change_colour(c))
				primer.text(gtx, CHANGE_NAMES[c], .Small, color = muted)
			}
			ui.scope_close(&sc)
		}
	}
}

// since_menu lists the snapshots to compare with, newest first, the one compared
// with ticked, and None.
@(private)
since_menu :: proc(gtx: ^ui.Ctx, m: ^Model, h: ^query.History_Result, anchor: ui.Last_Widget) {
	menu := primer.action_menu_open(
		gtx,
		&m.since_open,
		anchor,
		selection = .Single,
		name = "Compare with",
	)
	defer primer.action_menu_close(&menu)
	if !menu.visible {
		return
	}
	for snap in h.snapshots {
		if primer.action_menu_item(
			&menu,
			taken_text(snap.taken, gtx.allocator),
			description = human.bytes(snap.bytes, gtx.allocator),
			selected = snap.id == h.compared.id,
		) {
			ui.command(gtx, command.Command(command.Baseline{m.generation, snap.id}))
		}
	}
	primer.action_menu_divider(&menu)
	if primer.action_menu_item(&menu, "None", selected = h.compared.id == 0) {
		ui.command(gtx, command.Command(command.Baseline{m.generation, 0}))
	}
}

/*
since_pill is the pill naming the snapshot compared with, as tall as a chip so
the legend row keeps its height: its text and a chevron, tinted under the pointer
and filled while its menu is open. It reports a click.
*/
@(private)
since_pill :: proc(gtx: ^ui.Ctx, label: string, open: bool, loc := #caller_location) -> bool {
	st := primer.text_style(.Small)
	para := design.layout_style(gtx, label, st, primer.font_for(gtx, st.weight))
	chevron := st.line_height - 4
	size := ops.Size{2 * CHIP_PAD + para.width + LEGEND_INSET + chevron, st.line_height}
	p := ui.widget_open(gtx, loc = loc)
	box := ops.Rect{0, 0, size.x, size.y}
	c := design.control(gtx, p.id, box, .Live)
	pill := ops.Round_Rect{box, size.y / 2}
	switch {
	case open:
		ops.fill(gtx.scene, pill, primer.color(.Control_Bg_Color_Selected))
	case c.hovered:
		ops.fill(gtx.scene, pill, primer.color(.Control_Transparent_Bg_Color_Hover))
	}
	ops.stroke(gtx.scene, pill, primer.color(.Border_Color_Default), {width = 1})
	ink := primer.color(.Fg_Color_Default)
	design.draw_paragraph(gtx, para, {CHIP_PAD, (size.y - para.height) / 2}, ink)
	primer.icon(
		gtx,
		.Chevron_Down,
		{CHIP_PAD + para.width + LEGEND_INSET, (size.y - chevron) / 2},
		chevron,
		primer.color(.Fg_Color_Muted),
	)
	design.listen(gtx, c.st, p.id, box, design.CLICK_KINDS, .Pointer)
	ops.tag(gtx.scene, p.id, label)
	ui.semantics(gtx, &p, {role = .Button, label = label, states = {.Expanded} if open else {}})
	ui.widget_close(gtx, &p, {size = size})
	return c.clicked
}
