package sonar_view

import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "jm:ui"
import "jm:ui/design"
import "jm:ui/primer"
import tok "jm:ui/primer/tokens"

import "../../human"
import "../command"
import "../query"

/*
Reclaim mode: what can be deleted under the directory shown to free space without
losing anything, grouped by why each is safe, with a selection and one Clean up.
The host finds the candidates (package reclaim) once the scan is over and deletes
only those; the view chooses among them and asks before anything goes.

Everything here is deleted for good, not moved to the Trash: moving it there
would free nothing, and it all comes back by itself. The Trash itself is a group
of its own, emptied by its own button.

What was touched in the last week starts unchosen: it is likely in use, and making
it again is the annoying case.
*/

// reclaim_panel is Reclaim mode in the chart's place.
@(private)
reclaim_panel :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, _ := ui.need(
		gtx,
		query.Reclaim{generation = m.generation, dir = m.dir},
		query.Reclaim_Result,
	)
	if r == nil || r.generation != m.generation || !r.ready {
		if ui.row(gtx, gap = 8, align = .Center) {
			primer.spinner(gtx, .Small, label = "Looking")
			primer.text(
				gtx,
				"Reclaim looks once the scan is done.",
				color = primer.color(.Fg_Color_Muted),
			)
		}
		return
	}
	if len(r.groups) == 0 {
		primer.text(gtx, "Nothing here is safe to reclaim.", weight = .Semibold)
		primer.text(
			gtx,
			"Reclaim finds what builds and tools made and will make again: installed dependencies, build output, caches.",
			.Small,
			color = primer.color(.Fg_Color_Muted),
		)
		return
	}
	here := crumb_path(gtx, m.trail[:]) if len(m.trail) > 0 else ""
	primer.text(
		gtx,
		fmt.aprintf("%s can be reclaimed here", human.bytes(r.bytes), allocator = gtx.allocator),
		weight = .Semibold,
	)

	// The Trash is one thing with one action, so it stands above the list, always
	// in view, rather than at the end of it to be scrolled to.
	for g in r.groups {
		if g.trash {
			trash_row(gtx, m, g)
		}
	}

	// One list of rows, each group's header then its folders, of which only those
	// in view are laid out: a home holds hundreds.
	rows := make([dynamic]Reclaim_Row, gtx.allocator)
	for g, gi in r.groups {
		if g.trash {
			continue
		}
		append(&rows, Reclaim_Row{gi, -1})
		for _, ii in g.items {
			append(&rows, Reclaim_Row{gi, ii})
		}
	}
	list := Reclaim_List{m, r, rows[:], here}
	ui.flexible(gtx, 1)
	ui.list(gtx, &m.reclaim_scroll, len(rows), reclaim_row, &list)

	// The footer stays put under the list: what is chosen, and the one action.
	count, bytes := chosen_total(m, r)
	if ui.row(gtx, gap = 12, align = .Center) {
		ui.flexible(gtx, 1)
		primer.text(
			gtx,
			fmt.aprintf(
				"%s in %s %s chosen",
				human.bytes(bytes),
				human.count(u64(count)),
				"folder" if count == 1 else "folders",
				allocator = gtx.allocator,
			),
			color = primer.color(.Fg_Color_Muted),
		)
		if primer.button(gtx, "Clean up", .Danger, leading = .Trash, inactive = count == 0) &&
		   count > 0 {
			m.clean_open = true
		}
	}
}

// RECLAIM_ROW is the height of every row of the list, a header or a folder: a
// name over a caption, with room between.
RECLAIM_ROW :: f32(52)

// Reclaim_Row is one row of the list: group's header when item is -1, else one
// of its folders.
@(private)
Reclaim_Row :: struct {
	group, item: int,
}

@(private)
Reclaim_List :: struct {
	m:    ^Model,
	r:    ^query.Reclaim_Result,
	rows: []Reclaim_Row,
	here: string,
}

// reclaim_row draws row i of the list: a group's header with its total and why
// it is safe, or one folder with its size and when it was touched, its path cut
// in the middle to the room beside the size.
@(private)
reclaim_row :: proc(gtx: ^ui.Ctx, i: int, user: rawptr) {
	l := (^Reclaim_List)(user)
	m := l.m
	row := l.rows[i]
	g := l.r.groups[row.group]
	cs := gtx.constraints
	width := cs.max.x - PAD if ui.is_finite(cs.max.x) else 480
	if !ui.sized(gtx, {min = {cs.min.x, RECLAIM_ROW}, max = {cs.max.x, RECLAIM_ROW}}) {
		return
	}
	// Clear of the list's scroll bar.
	ui.inset(gtx, {right = PAD})

	if row.item >= 0 {
		it := g.items[row.item]
		size := human.bytes(it.bytes)
		room := width - text_width(gtx, size, .Small) - 12 - primer.CHOICE_BOX - primer.CHOICE_GAP
		if ui.row(gtx, gap = 12, align = .Center) {
			ui.flexible(gtx, 1)
			tick := is_chosen(m, it)
			if primer.checkbox(
				gtx,
				&tick,
				label = cut_path(gtx, relative_path(it.path, l.here), room),
				caption = modified_caption(it),
			) {
				m.reclaim_pick[it.node] = tick
			}
			primer.text(gtx, size, .Small)
		}
		return
	}

	total := human.bytes(g.bytes)
	room := width - text_width(gtx, total, .Medium, .Semibold) - 12
	if ui.row(gtx, gap = 12, align = .Center) {
		ui.flexible(gtx, 1)
		tick := true
		for it in g.items {
			tick &&= is_chosen(m, it)
		}
		// The reason under the box rather than as its caption, so it is cut to
		// the room the total leaves.
		if ui.column(gtx, gap = 2) {
			if primer.checkbox(
				gtx,
				&tick,
				label = fmt.aprintf("All %s", g.name, allocator = gtx.allocator),
			) {
				for it in g.items {
					m.reclaim_pick[it.node] = tick
				}
			}
			if ui.inset(gtx, {left = primer.CHOICE_BOX + primer.CHOICE_GAP}) {
				primer.truncate(
					gtx,
					g.reason,
					max_width = room - primer.CHOICE_BOX - primer.CHOICE_GAP,
					size = .Small,
					color = primer.color(.Fg_Color_Muted),
				)
			}
		}
		primer.text(gtx, total, weight = .Semibold)
	}
}

// trash_row is the Trash: what it holds, why emptying it is safe, and the button
// that empties it.
@(private)
trash_row :: proc(gtx: ^ui.Ctx, m: ^Model, g: query.Reclaim_Group) {
	total := human.bytes(g.bytes)
	width := gtx.constraints.max.x if ui.is_finite(gtx.constraints.max.x) else 480
	room :=
		width -
		text_width(gtx, total, .Medium, .Semibold) -
		text_width(gtx, "Empty Trash", .Small) -
		2 * 12 -
		16
	if ui.row(gtx, gap = 12, align = .Center) {
		ui.flexible(gtx, 1)
		if ui.column(gtx, gap = 2) {
			primer.text(gtx, g.name, weight = .Semibold)
			primer.truncate(
				gtx,
				g.reason,
				max_width = room,
				size = .Small,
				color = primer.color(.Fg_Color_Muted),
			)
		}
		primer.text(gtx, total, weight = .Semibold)
		if primer.button(gtx, "Empty Trash", .Danger, .Small) {
			m.trash_node, m.trash_bytes, m.empty_open = g.items[0].node, g.bytes, true
		}
	}
}

// text_width is how wide s is set in size and weight.
@(private)
text_width :: proc(
	gtx: ^ui.Ctx,
	s: string,
	size := primer.Text_Size.Medium,
	weight := primer.Text_Weight.Normal,
) -> f32 {
	st := primer.text_style(size, weight)
	return design.layout_style(gtx, s, st, primer.font_for(gtx, st.weight)).width
}

/*
cut_path is path, or when it is wider than room, cut short so it fits: its last
name kept whole, since that names the folder, and the way to it cut in the middle,
by letters rather than names, since the names above are what tell one folder from
another of the same name. Bisects on the letters kept.
*/
@(private)
cut_path :: proc(gtx: ^ui.Ctx, path: string, room: f32) -> string {
	st := primer.text_style(.Medium)
	fits :: proc(gtx: ^ui.Ctx, s: string, st: tok.Type_Style, room: f32) -> bool {
		return design.layout_style(gtx, s, st, primer.font_for(gtx, st.weight)).width <= room
	}
	if !ui.is_finite(room) || fits(gtx, path, st, room) {
		return path
	}
	at := strings.last_index_byte(path, '/')
	if at <= 0 {
		return middle_cut(gtx, path, st, room)
	}
	way, last := path[:at], path[at:]
	cut :: proc(gtx: ^ui.Ctx, way, last: string, keep: int) -> string {
		head := keep / 2
		tail := len(way) - (keep - head)
		for head > 0 && !utf8.rune_start(way[head]) {
			head -= 1
		}
		for tail < len(way) && !utf8.rune_start(way[tail]) {
			tail += 1
		}
		return strings.concatenate({way[:head], "…", way[tail:], last}, gtx.allocator)
	}
	if !fits(gtx, cut(gtx, way, last, 0), st, room) {
		return strings.concatenate({"…", last}, gtx.allocator)
	}
	lo, hi := 0, len(way) // lo letters fit, hi do not
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if fits(gtx, cut(gtx, way, last, mid), st, room) {
			lo = mid
		} else {
			hi = mid
		}
	}
	return cut(gtx, way, last, lo)
}

// is_chosen is whether a candidate is in the selection: what the person chose, or
// at first, chosen unless recently touched.
@(private)
is_chosen :: proc(m: ^Model, it: query.Candidate) -> bool {
	if picked, ok := m.reclaim_pick[it.node]; ok {
		return picked
	}
	return !it.recent
}

// chosen_total is how many candidates are chosen, outside the Trash, and what
// they hold.
@(private)
chosen_total :: proc(m: ^Model, r: ^query.Reclaim_Result) -> (count: int, bytes: u64) {
	for g in r.groups {
		if g.trash {
			continue
		}
		for it in g.items {
			if is_chosen(m, it) {
				count += 1
				bytes += it.bytes
			}
		}
	}
	return
}

// reclaim_dialogs ask before anything is deleted, saying it is for good. They are
// drawn with the window's other dialogs, over everything, not in the panel.
@(private)
reclaim_dialogs :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if m.mode != .Reclaim {
		m.clean_open, m.empty_open = false, false
		return
	}
	r, _ := ui.need(
		gtx,
		query.Reclaim{generation = m.generation, dir = m.dir},
		query.Reclaim_Result,
	)
	if r == nil || r.generation != m.generation || !r.ready {
		return
	}
	count, bytes := chosen_total(m, r)
	answer := primer.confirmation_dialog(
		gtx,
		&m.clean_open,
		fmt.aprintf(
			"Delete %s %s for good?",
			human.count(u64(count)),
			"folder" if count == 1 else "folders",
			allocator = gtx.allocator,
		),
		fmt.aprintf(
			"This frees %s. Nothing is moved to the Trash: each comes back by itself when the project is next built or installed, or the tool next runs.",
			human.bytes(bytes),
			allocator = gtx.allocator,
		),
		confirm_content = "Delete",
		confirm_type = .Danger,
	)
	if answer == .Confirm {
		// In batches a Clean can carry.
		batch := command.Clean {
			generation = m.generation,
		}
		for g in r.groups {
			if g.trash {
				continue
			}
			for it in g.items {
				if !is_chosen(m, it) {
					continue
				}
				batch.nodes[batch.count] = it.node
				batch.count += 1
				if batch.count == len(batch.nodes) {
					ui.command(gtx, command.Command(batch))
					batch.count = 0
				}
			}
		}
		if batch.count > 0 {
			ui.command(gtx, command.Command(batch))
		}
	}

	trash := primer.confirmation_dialog(
		gtx,
		&m.empty_open,
		"Empty the Trash?",
		fmt.aprintf(
			"%s in the Trash will be deleted for good.",
			human.bytes(m.trash_bytes),
			allocator = gtx.allocator,
		),
		confirm_content = "Empty",
		confirm_type = .Danger,
	)
	if trash == .Confirm {
		ui.command(
			gtx,
			command.Command(
				command.Empty_Trash{entry = {generation = m.generation, node = m.trash_node}},
			),
		)
	}
}

// relative_path is path from under here, the directory shown, or path whole.
@(private)
relative_path :: proc(path, here: string) -> string {
	if here != "" &&
	   strings.has_prefix(path, here) &&
	   len(path) > len(here) + 1 &&
	   path[len(here)] == '/' {
		return path[len(here) + 1:]
	}
	return path
}

// modified_caption says when a candidate was last touched, and that a recent one
// is left unchosen.
@(private)
modified_caption :: proc(it: query.Candidate) -> string {
	if it.modified <= 0 {
		return ""
	}
	when_ := ago(time.time_to_unix(time.now()) - it.modified)
	if it.recent {
		return fmt.tprintf("Modified %s, so likely in use", when_)
	}
	return fmt.tprintf("Modified %s", when_)
}

// ago is a span of seconds in the past, in words.
ago :: proc(seconds: i64) -> string {
	day :: 24 * 60 * 60
	switch {
	case seconds < day:
		return "today"
	case seconds < 2 * day:
		return "yesterday"
	case seconds < 60 * day:
		return fmt.tprintf("%d days ago", seconds / day)
	case seconds < 2 * 365 * day:
		return fmt.tprintf("%d months ago", seconds / (30 * day))
	}
	return fmt.tprintf("%d years ago", seconds / (365 * day))
}
