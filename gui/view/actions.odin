package leita_view

import "core:strings"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../../human"
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

// Menu_From is where the right-click menu was opened, which is where it is drawn.
Menu_From :: enum u8 {
	Sunburst,
	Treemap,
	Icicle,
	Contents,
	Largest,
	Search,
}

// Target is the entry a menu or dialog is about, kept past the frame it was
// chosen in because the rings it came from are replaced every tick.
Target :: struct {
	node:      u32,
	name:      string, // owned
	directory: bool,
	hub:       bool, // the directory at the centre, not an arc
}

// open makes dir the one shown, in the sunburst and the listing both, and
// remembers the one it replaces. A search gives way to it.
open :: proc(m: ^Model, dir: u32) {
	if m.searching {
		close_search(m)
	}
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

// leave_gone moves the window off the directory it shows, which the host has
// forgotten (moved to the Trash, or cleaned up), to up, the nearest ancestor still
// in the tree, and drops the directory from the history. The host forgets a node
// without telling the window, so a history id is found out when it is reached;
// until then it is only a number that names nothing, never drawn.
@(private)
leave_gone :: proc(m: ^Model, up: u32) {
	gone := m.dir
	m.dir = up
	m.scroll = {}
	drop_id :: proc(ids: ^[dynamic]u32, gone, here: u32) {
		kept := 0
		for id in ids^ {
			if id != gone {
				ids[kept] = id
				kept += 1
			}
		}
		resize(ids, kept)
		// A step to the place already shown goes nowhere.
		for len(ids) > 0 && ids[len(ids) - 1] == here {
			pop(ids)
		}
	}
	drop_id(&m.back, gone, up)
	drop_id(&m.forward, gone, up)
}

// walk_history walks the history on the mouse's back and forward buttons, or Alt with
// an arrow, wherever the pointer is: keys the frame asks for window-wide. The
// platform's command key, Cmd on macOS and Ctrl elsewhere, with L edits the
// location, with F searches, and with R scans the place again.
@(private)
walk_history :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	nav := ui.claim_id(gtx)
	ui.key_interest(gtx, nav, .Browser_Back)
	ui.key_interest(gtx, nav, .Browser_Forward)
	ui.key_interest(gtx, nav, .Left, {.Alt})
	ui.key_interest(gtx, nav, .Right, {.Alt})
	ui.key_interest(gtx, nav, .L, {ui.SHORTCUT})
	ui.key_interest(gtx, nav, .F, {ui.SHORTCUT})
	ui.key_interest(gtx, nav, .R, {ui.SHORTCUT})
	for e in ui.events(gtx, nav) {
		if e.kind != .Key {
			continue
		}
		#partial switch e.key {
		case .Browser_Back, .Left:
			go_back(m)
		case .Browser_Forward, .Right:
			go_forward(m)
		case .L:
			if len(m.trail) > 0 {
				close_search(m)
				edit_location(m, crumb_path(gtx, m.trail[:]))
			}
		case .F:
			open_search(m)
		case .R:
			rescan(gtx, prog)
		}
	}
}

// can_rescan is whether there is a finished scan to run again: a place, and no
// scan running there.
@(private)
can_rescan :: proc(prog: ^query.Progress_Result) -> bool {
	return prog != nil && prog.target != "" && prog.state != .Scanning
}

// rescan scans the place again, which picks up what changed on disk since;
// nothing while a scan runs or before one.
@(private)
rescan :: proc(gtx: ^ui.Ctx, prog: ^query.Progress_Result) {
	if !can_rescan(prog) {
		return
	}
	ui.command(gtx, command.Command(command.Scan{path = command.text_make(prog.target)}))
}

// aim makes the menu and dialogs about t, under its name made safe to draw
// (safe): the dialogs show it, the rename field starts from it, and a rename
// that leaves it as it is is none.
@(private)
aim :: proc(m: ^Model, t: Target) {
	delete(m.target.name)
	m.target = t
	m.target.name = strings.clone(human.shown(t.name))
}

@(private)
entry_of :: proc(m: ^Model) -> command.Entry {
	return {generation = m.generation, node = m.target.node}
}

// open_file asks the host to open the file node as the system would, in the
// application it opens it with. The menu's Open is the other kind: a directory
// made the one shown.
@(private)
open_file :: proc(gtx: ^ui.Ctx, m: ^Model, node: u32) {
	ui.command(
		gtx,
		command.Command(command.Open{entry = {generation = m.generation, node = node}}),
	)
}

// entry_menu is the right-click menu, under anchor moved by at: the point
// clicked in the sunburst, or a list row's name with at zero. The caller draws it
// in the anchor's own space.
@(private)
entry_menu :: proc(gtx: ^ui.Ctx, m: ^Model, anchor: ui.Last_Widget, at := ops.Point{}) {
	ops.transform_push(gtx.scene, ops.translate(at.x, at.y))
	defer ops.transform_pop(gtx.scene)
	menu := primer.action_menu_open(
		gtx,
		&m.menu_open,
		anchor,
		name = trf(gtx, .Actions_For, m.target.name),
	)
	defer primer.action_menu_close(&menu)
	if !menu.visible {
		return
	}
	t := m.target
	if t.directory &&
	   !t.hub &&
	   primer.action_menu_item(&menu, tr(.Open), leading = .File_Directory_Open_Fill) {
		open(m, t.node)
	}
	if !t.directory && primer.action_menu_item(&menu, tr(.Open_File), leading = .File) {
		open_file(gtx, m, t.node)
	}
	if primer.action_menu_item(&menu, tr(.Locate), leading = .Link_External) {
		ui.command(gtx, command.Command(command.Locate{entry = entry_of(m)}))
	}
	if t.hub {
		return
	}
	if primer.action_menu_item(&menu, tr(.Rename), leading = .Pencil) {
		ui.text_set(&m.rename, t.name)
		ui.text_select(&m.rename, 0, len(t.name))
		m.rename_open, m.rename_focus = true, true
	}
	primer.action_menu_divider(&menu)
	if primer.action_menu_item(&menu, tr(.Trash), leading = .Trash, variant = .Danger) {
		m.trash_open = true
	}
}

// row_menu gives a list row's name button the right-click menu: a right press on it aims the menu at t and opens it there,
// and while it is open for t from this list it is drawn under the button. A
// button acts on left clicks only, so a right press reaches its area unclaimed.
@(private)
row_menu :: proc(gtx: ^ui.Ctx, m: ^Model, from: Menu_From, name: ui.Last_Widget, t: Target) {
	for e in ui.events(gtx, name.id) {
		if e.kind == .Press && e.button == .Right {
			aim(m, t)
			m.menu_from, m.menu_open = from, true
		}
	}
	if m.menu_open && m.menu_from == from && m.target.node == t.node && !m.target.hub {
		entry_menu(gtx, m, name)
	}
}

// dialogs are the questions a menu choice asks before it becomes a command.
@(private)
dialogs :: proc(gtx: ^ui.Ctx, m: ^Model) {
	answer := primer.confirmation_dialog(
		gtx,
		&m.trash_open,
		trf(gtx, .Trash_Title, m.target.name),
		trf(gtx, .Trash_Body, m.target.name),
		confirm_content = tr(.Trash),
		confirm_type = .Danger,
	)
	if answer == .Confirm {
		ui.command(gtx, command.Command(command.Trash{entry = entry_of(m)}))
	}

	cancel, rename := false, false
	buttons := [2]primer.Dialog_Button {
		{content = tr(.Cancel), clicked = &cancel},
		{content = tr(.Rename), type = .Primary, clicked = &rename},
	}
	if primer.dialog(
		gtx,
		&m.rename_open,
		tr(.Rename),
		m.target.name,
		footer = buttons[:],
		width = .Medium,
	) {
		field := primer.text_input(gtx, &m.rename, block = true, name = tr(.New_Name))
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

// notice floats what came of each request in a toast at the window's lower left,
// clear of the actions at the foot of the panels, such as Reclaim's Clean up. One
// that went well leaves on its own; one that failed stays until dismissed. One
// that saved a file offers Locate, which shows it in the file manager.
@(private)
notice :: proc(gtx: ^ui.Ctx, m: ^Model, n: query.Notice) {
	if n.id != 0 && n.id != m.notice_seen {
		m.notice_seen = n.id
		opts: primer.Toast_Options
		if n.saved {
			opts.action = tr(.Locate)
		}
		toast := primer.toast_push(
			&m.toasts,
			safe(gtx, n.text),
			.Error if n.failed else .Success,
			opts,
		)
		if n.saved {
			m.saved_toasts[toast] = n.id
		}
	}
	ev := primer.toaster(gtx, &m.toasts, .Bottom_Start)
	if notice, ok := m.saved_toasts[ev.action]; ok && ev.action != 0 {
		ui.command(gtx, command.Command(command.Reveal{notice = notice}))
	}
	// A toast gone, timed out or dismissed, has no Locate to press.
	gone := make([dynamic]int, gtx.allocator)
	for toast in m.saved_toasts {
		showing := false
		for t in m.toasts.items {
			showing ||= t.id == toast && !t.leaving
		}
		if !showing {
			append(&gone, toast)
		}
	}
	for toast in gone {
		delete_key(&m.saved_toasts, toast)
	}
}
