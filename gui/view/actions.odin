package sonar_view

import "core:fmt"
import "core:strings"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../command"
import "../query"

/*
Where the window has been, and what it can do to an entry.

Every directory opened is remembered, so the mouse's back and forward buttons, or
Alt with an arrow, walk the way back and forth as a browser does. A right click on
an arc offers what can be done to its entry: open it, show it in the file manager,
rename it, move it to the Trash. The view only asks; the host does it and says how
it went in a notice.
*/

// HISTORY is how many directories back the window remembers.
HISTORY :: 256

// Target is the entry a menu or dialog is about, kept past the frame it was
// chosen in because the rings it came from are replaced every tick.
Target :: struct {
	node:      u32,
	name:      string, // owned
	directory: bool,
	hub:       bool, // the directory at the centre, not an arc
}

// open makes dir the one shown, in the sunburst and the listing both, and
// remembers the one it replaces.
open :: proc(m: ^Model, dir: u32) {
	if dir == m.dir {
		return
	}
	if len(m.back) == HISTORY {
		ordered_remove(&m.back, 0)
	}
	append(&m.back, m.dir)
	clear(&m.forward)
	m.dir = dir
	m.scroll = {}
}

go_back :: proc(m: ^Model) {
	if dir, ok := pop_safe(&m.back); ok {
		append(&m.forward, m.dir)
		m.dir = dir
		m.scroll = {}
	}
}

go_forward :: proc(m: ^Model) {
	if dir, ok := pop_safe(&m.forward); ok {
		append(&m.back, m.dir)
		m.dir = dir
		m.scroll = {}
	}
}

// forget_history drops the way back and forth, for a new scan whose tree numbers
// its nodes afresh.
forget_history :: proc(m: ^Model) {
	clear(&m.back)
	clear(&m.forward)
}

// walk_history walks the history on the mouse's back and forward buttons, or Alt with
// an arrow, wherever the pointer is: keys the frame asks for window-wide.
@(private)
walk_history :: proc(gtx: ^ui.Ctx, m: ^Model) {
	nav := ui.claim_id(gtx)
	ui.key_interest(gtx, nav, .Browser_Back)
	ui.key_interest(gtx, nav, .Browser_Forward)
	ui.key_interest(gtx, nav, .Left, {.Alt})
	ui.key_interest(gtx, nav, .Right, {.Alt})
	for e in ui.events(gtx, nav) {
		if e.kind != .Key {
			continue
		}
		#partial switch e.key {
		case .Browser_Back, .Left:
			go_back(m)
		case .Browser_Forward, .Right:
			go_forward(m)
		}
	}
}

// aim makes the menu and dialogs about t.
@(private)
aim :: proc(m: ^Model, t: Target) {
	delete(m.target.name)
	m.target = t
	m.target.name = strings.clone(t.name)
}

@(private)
entry_of :: proc(m: ^Model) -> command.Entry {
	return {generation = m.generation, node = m.target.node}
}

// entry_menu is the right-click menu, at the point that was clicked. The caller
// has the sunburst's transform pushed and passes its area as the anchor.
@(private)
entry_menu :: proc(gtx: ^ui.Ctx, m: ^Model, anchor: ops.Area_Id) {
	ops.transform_push(gtx.scene, ops.translate(m.menu_at.x, m.menu_at.y))
	defer ops.transform_pop(gtx.scene)
	menu := primer.action_menu_open(
		gtx,
		&m.menu_open,
		{anchor, {0, 0}},
		name = fmt.aprintf("Actions for %s", m.target.name, allocator = gtx.allocator),
	)
	defer primer.action_menu_close(&menu)
	if !menu.visible {
		return
	}
	t := m.target
	if t.directory &&
	   !t.hub &&
	   primer.action_menu_item(&menu, "Open", leading = .File_Directory_Open_Fill) {
		open(m, t.node)
	}
	if primer.action_menu_item(
		&menu,
		"Locate",
		description = "Show in the file manager",
		leading = .Link_External,
	) {
		ui.command(gtx, command.Command(command.Locate{entry = entry_of(m)}))
	}
	if t.hub {
		return
	}
	if primer.action_menu_item(&menu, "Rename…", leading = .Pencil) {
		ui.text_set(&m.rename, t.name)
		ui.text_select(&m.rename, 0, len(t.name))
		m.rename_open, m.rename_focus = true, true
	}
	primer.action_menu_divider(&menu)
	if primer.action_menu_item(&menu, "Move to Trash", leading = .Trash, variant = .Danger) {
		m.trash_open = true
	}
}

// dialogs are the questions a menu choice asks before it becomes a command.
@(private)
dialogs :: proc(gtx: ^ui.Ctx, m: ^Model) {
	answer := primer.confirmation_dialog(
		gtx,
		&m.trash_open,
		"Move to Trash?",
		fmt.aprintf(
			"%s and everything in it will be moved to the Trash, where it can be restored.",
			m.target.name,
			allocator = gtx.allocator,
		),
		confirm_content = "Move to Trash",
		confirm_type = .Danger,
	)
	if answer == .Confirm {
		ui.command(gtx, command.Command(command.Trash{entry = entry_of(m)}))
	}

	cancel, rename := false, false
	buttons := [2]primer.Dialog_Button {
		{content = "Cancel", clicked = &cancel},
		{content = "Rename", type = .Primary, clicked = &rename},
	}
	if primer.dialog(
		gtx,
		&m.rename_open,
		"Rename",
		m.target.name,
		footer = buttons[:],
		width = .Medium,
	) {
		field := primer.text_input(gtx, &m.rename, block = true, name = "New name")
		// The name is what the dialog is for, so typing goes straight into it. The
		// menu that opened the dialog hands focus back to the sunburst a frame after
		// it closes, so this asks until the field has it.
		if m.rename_focus {
			if ui.focused(gtx) == field.id {
				m.rename_focus = false
			} else {
				ui.focus_request(gtx, field.id)
			}
		}
		rename ||= field.submitted
	}
	if cancel {
		m.rename_open = false
	}
	if rename {
		m.rename_open = false
		name := strings.trim_space(ui.text_string(&m.rename))
		if name != "" && name != m.target.name {
			ui.command(
				gtx,
				command.Command(
					command.Rename{entry = entry_of(m), name = command.text_make(name)},
				),
			)
		}
	}
}

// notice shows what came of the last request, until it is dismissed.
@(private)
notice :: proc(gtx: ^ui.Ctx, m: ^Model, n: query.Notice) {
	if n.id == 0 || n.id == m.notice_seen {
		return
	}
	if primer.banner(gtx, n.text, variant = n.failed ? .Critical : .Success, dismissible = true) ==
	   .Dismiss {
		m.notice_seen = n.id
	}
}
