package leita_view

import "core:fmt"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

/*
What a chart shows of a scan that did not finish. A directory the walk left short
(query.Arc.incomplete) has its arc or box outlined in the ink, and so does the
hub, or the treemap's whole frame, where the scan was stopped or failed
(query.Rings_Result.incomplete): with that outline the disc does not read as the
whole disk. Each outline is also a tag, "incomplete" and the name, and the
chart's tree says it for a screen reader (chart_tree.odin). The status line says
why (status_messages).
*/

// INCOMPLETE_KEY marks the ids of the tags of the outlines from the ids of a
// chart's other parts.
INCOMPLETE_KEY :: 0xe9

// mark_incomplete outlines shape, which lies inside the part it is for.
@(private)
mark_incomplete :: proc(gtx: ^ui.Ctx, shape: ops.Shape) {
	ops.stroke(gtx.scene, shape, primer.color(.Fg_Color_Default), {width = 2})
}

// tag_incomplete names the n-th outline of the chart p, for the entry called
// name, over rect.
@(private)
tag_incomplete :: proc(gtx: ^ui.Ctx, p: ^ui.Placement, n: u64, name: string, rect: ops.Rect) {
	ops.tag(
		gtx.scene,
		ui.id_mix(ui.id_mix(p.id, INCOMPLETE_KEY), n),
		fmt.aprintf("%s %s", tr(.Incomplete), name, allocator = gtx.allocator),
		rect,
	)
}
