package leita_view

import "jm:ui"

import "../query"

/*
The charts by keyboard. With a chart focused (Tab reaches it; it shows a ring),
the arrow keys move a pick through the arcs it draws, as a file browser's do
through a tree:

	Left, Right  the previous or next entry in the same directory, largest first
	Down         into the picked directory, to its largest entry
	Up           out to the directory the pick lies in; from the first ring, to
	             nothing picked, and then up to the directory above the one shown
	Enter        the pick opened: a directory becomes the one shown, a file opens
	             in its application
	Escape       nothing picked

Where nothing is picked, the entry under the pointer or the hovered row is the one
the keys start from, and with nothing there either, Left, Right and Down start at
the largest entry of the directory shown. The pick is lit as a hovered arc is, in
the info block and for a screen reader (describe_chart), until the pointer moves.
Down opens the folder in the chart's tree and Up closes it again
(toggle_said_open), so what a reader hears and what the keys do agree.

Keys held with a modifier belong to the window: Alt with an arrow walks the
history (walk_history).
*/

// chart_step is the arc the key moves the pick to from arc at, -1 for none: the
// arc's own for a key that goes nowhere, and -1 for Up out of the first ring. The
// arcs of a directory come largest first, so a sibling is the next arc with the
// same parent.
@(private)
chart_step :: proc(r: ^query.Rings_Result, at: int, key: ui.Key) -> int {
	if at < 0 {
		#partial switch key {
		case .Left, .Right, .Down:
			return find_arc(r, -1, 0, +1)
		}
		return -1
	}
	up := int(r.arcs[at].up)
	to := at
	#partial switch key {
	case .Right:
		to = find_arc(r, up, at + 1, +1)
	case .Left:
		to = find_arc(r, up, at - 1, -1)
	case .Down:
		to = find_arc(r, at, 0, +1)
	case .Up:
		return up
	}
	return to if to >= 0 else at
}

// find_arc is the first arc under parent (-1 for the first ring) from start on,
// stepping by step through r's arcs, or -1.
@(private)
find_arc :: proc(r: ^query.Rings_Result, parent, start, step: int) -> int {
	for i := start; i >= 0 && i < len(r.arcs); i += step {
		if int(r.arcs[i].up) == parent {
			return i
		}
	}
	return -1
}

// picked_arc is the arc the keys have picked in r, and whether they have.
@(private)
picked_arc :: proc(m: ^Model, r: ^query.Rings_Result) -> (at: int, ok: bool) {
	if !m.chart_keys || m.chart_pick == 0 {
		return -1, false
	}
	at = arc_of(r, m.chart_pick)
	return at, at >= 0
}

// set_chart_pick makes arc at the pick, or nothing for -1.
@(private)
set_chart_pick :: proc(m: ^Model, r: ^query.Rings_Result, at: int) {
	if at < 0 {
		m.chart_pick, m.chart_keys = 0, false
		return
	}
	m.chart_pick, m.chart_keys = r.arcs[at].node, true
}

// chart_key acts on a key event e a focused chart saw, from arc at: the one under
// the pointer or the pick, -1 for none.
@(private)
chart_key :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Rings_Result, e: ui.Event, at: int) {
	if e.mods != {} {
		return
	}
	// The chart reads the pick before it reads the keys, so the frame after shows it.
	ui.request_frame(gtx)
	#partial switch e.key {
	case .Left, .Right:
		set_chart_pick(m, r, chart_step(r, at, e.key))
	case .Down:
		to := chart_step(r, at, .Down)
		if at >= 0 && to != at && !m.said_open[r.arcs[at].node] {
			toggle_said_open(m, r.arcs[at].node)
		}
		set_chart_pick(m, r, to)
	case .Up:
		if at < 0 {
			if len(r.crumbs) > 1 {
				open(m, r.crumbs[len(r.crumbs) - 2].node)
			}
			return
		}
		if up := int(r.arcs[at].up); up >= 0 && m.said_open[r.arcs[up].node] {
			toggle_said_open(m, r.arcs[up].node)
		}
		set_chart_pick(m, r, chart_step(r, at, .Up))
	case .Enter:
		if at < 0 {
			return
		}
		if !r.arcs[at].directory {
			open_file(gtx, m, r.arcs[at].node)
			return
		}
		open(m, r.arcs[at].node)
		set_chart_pick(m, r, -1)
	case .Escape:
		set_chart_pick(m, r, -1)
	}
}
