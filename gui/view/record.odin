package leita_view

import "core:time"

import "jm:timefmt"
import "jm:ui"
import "jm:ui/primer"

import "../../human"
import "../query"

/*
History: History in the settings menu opens a dialog that lists what leita
changed on disk at the person's request, newest first, as `leita history` does:
when, in the local time zone, what, how much, and why it failed when it did.
A row's Copy path puts its path on the clipboard, for a message to whoever
asks what happened to a folder.

The record is the host's to read, from the store the scans are kept in; the
dialog asks for it only while it is open, so a deletion made with it open
appears at once.
*/

// RECORD_ROWS is how many rows the dialog shows at once; the rest scroll.
RECORD_ROWS :: 8

// RECORD_ROW is the height of a row: the path over what came of it, with room
// between.
RECORD_ROW :: f32(52)

// RECORD_WHEN is the room a row's time has, in the dialog's layout; the sizes
// beside it are shorter than this.
RECORD_WHEN :: f32(132)

// RECORD_COPY is the room Copy path takes: a medium icon button.
RECORD_COPY :: f32(32)

@(private)
Record_List :: struct {
	r: ^query.Record_Result,
}

// record_dialog is History, over everything while it is open.
@(private)
record_dialog :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if !m.record_open {
		return
	}
	r, _ := ui.need(gtx, query.Record{}, query.Record_Result)
	close := false
	buttons := [1]primer.Dialog_Button{{content = tr(.Close), clicked = &close}}
	if primer.dialog(
		gtx,
		&m.record_open,
		tr(.History),
		footer = buttons[:],
		width = .XLarge,
		align = .Top,
	) {
		ui.column(gtx, gap = 12, align = .Fill)
		switch {
		case r == nil:
			primer.text(gtx, tr(.Looking), color = primer.color(.Fg_Color_Muted))
		case !r.kept:
			primer.inline_message(gtx, tr(.History_Unavailable), .Warning)
		case len(r.actions) == 0:
			primer.text(gtx, tr(.History_Empty), color = primer.color(.Fg_Color_Muted))
		case:
			record_list(gtx, m, r)
		}
	}
	if close {
		m.record_open = false
	}
}

// record_list is the rows, set in a list of RECORD_ROWS rows or fewer, of which
// only those in view are laid out: the record keeps a thousand.
@(private)
record_list :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Record_Result) {
	cs := gtx.constraints
	rows := min(len(r.actions), RECORD_ROWS)
	height := RECORD_ROW * f32(rows)
	if !ui.sized(gtx, {min = {cs.min.x, height}, max = {cs.max.x, height}}) {
		return
	}
	list := Record_List{r}
	ui.list(gtx, &m.record_list, len(r.actions), record_row, &list)
}

// record_row draws row i of the record: its time, its path cut to the room the
// size and Copy path leave, and under the path how it went, if it did not go
// well or was a rename.
@(private)
record_row :: proc(gtx: ^ui.Ctx, i: int, user: rawptr) {
	a := (^Record_List)(user).r.actions[i]
	cs := gtx.constraints
	width := cs.max.x - PAD if ui.is_finite(cs.max.x) else 600
	if !ui.sized(gtx, {min = {cs.min.x, RECORD_ROW}, max = {cs.max.x, RECORD_ROW}}) {
		return
	}
	// Clear of the list's scroll bar.
	ui.inset(gtx, {right = PAD})

	size := human.bytes(a.bytes)
	room := width - RECORD_WHEN - text_width(gtx, size, .Small) - RECORD_COPY - 3 * 12
	if ui.row(gtx, gap = 12, align = .Center) {
		primer.text(gtx, record_time(a.taken), .Small, color = primer.color(.Fg_Color_Muted))
		ui.flexible(gtx, 1)
		if ui.column(gtx, gap = 2) {
			primer.text(gtx, cut_path(gtx, a.path, room))
			if how := record_how(gtx, a); how != "" {
				primer.truncate(
					gtx,
					how,
					max_width = room,
					size = .Small,
					color = primer.color(.Fg_Color_Danger if a.failed else .Fg_Color_Muted),
				)
			}
		}
		primer.text(gtx, size, .Small)
		if primer.icon_button(
			gtx,
			.Copy,
			tr(.Copy_Path),
			.Invisible,
			description = a.path,
			key = u64(i),
		) {
			ui.clipboard_write(gtx, a.path)
		}
	}
}

// record_time is when an action was taken, to the minute, in the local time zone.
@(private)
record_time :: proc(taken: i64) -> string {
	return timefmt.local(time.unix(taken, 0), "%Y-%m-%d %H:%M", context.temp_allocator)
}

// record_how says how an action went when that is more than that it did: why it
// failed, or what a rename gave. "" for one that simply worked.
@(private)
record_how :: proc(gtx: ^ui.Ctx, a: query.Action) -> string {
	switch {
	case a.failed && a.why != "":
		return trf(gtx, .History_Failed, a.why)
	case a.failed:
		return tr(.Failed)
	case a.renamed_to != "":
		return trf(gtx, .History_Renamed, a.renamed_to)
	}
	return ""
}
