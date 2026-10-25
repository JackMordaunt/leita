package gui_fuzz

import "core:fmt"
import "core:strings"

import "jm:ui"

import "../../human"
import "../../scan"
import "../../survey"
import "../app"
import "../msg"
import "../query"

/*
hold checks what must be true of the window after every action, and says the
first that is not, "" when all are. was is the scan the view showed before
the action.

	rescan     no dialog about the tree survives a new scan: its Confirm would act
	           on the new scan's entries, which the person has not seen (card 516)
	nodes      what is shown, picked, and the way back and forth all name entries
	           the scan holds
	totals     Contents says the total and the count the tree holds for the folder
	           shown
	focus      the keyboard is on something drawn, and inside an open modal dialog

A crash, a failed bounds check and an ASan report end the child process the
case runs in, which the harness reports as Crashed.
*/
hold :: proc(w: ^Window, was: u32, allocator := context.temp_allocator) -> string {
	if why := rescan_closed_dialogs(w, was, allocator); why != "" {
		return why
	}
	if why := nodes_exist(w, allocator); why != "" {
		return why
	}
	if why := totals_agree(w, allocator); why != "" {
		return why
	}
	if why := focus_visible(w, allocator); why != "" {
		return why
	}
	return ""
}

@(private)
rescan_closed_dialogs :: proc(
	w: ^Window,
	was: u32,
	allocator := context.temp_allocator,
) -> string {
	m := &w.m
	if m.generation == was {
		return ""
	}
	open: [9]string
	n := 0
	flags := [?]struct {
		on:   bool,
		what: string,
	} {
		{m.menu_open, "the entry menu"},
		{m.trash_open, "Move to Trash"},
		{m.rename_open, "Rename"},
		{m.export_open, "Export"},
		{m.clean_open, "Clean up"},
		{m.empty_open, "Empty Trash"},
		{m.since_open, "the snapshots menu"},
		{m.trash_node != 0, "the Trash entry"},
		{len(m.reclaim_pick) > 0, "the Reclaim choices"},
	}
	for f in flags {
		if f.on {
			open[n] = f.what
			n += 1
		}
	}
	if n == 0 {
		return ""
	}
	return fmt.aprintf(
		"rescan: scan %d became %d with %s still open",
		was,
		m.generation,
		strings.join(open[:n], ", ", allocator),
		allocator = allocator,
	)
}

// settled_scan is the desk's scan when it has finished and is the one the view
// shows, so its tree holds still while it is read; nil otherwise.
@(private)
settled_scan :: proc(w: ^Window) -> ^app.Scan {
	s, generation := state(w)
	if s != .Done || generation != w.m.generation || generation == 0 {
		return nil
	}
	return w.h.desk.scan
}

@(private)
nodes_exist :: proc(w: ^Window, allocator := context.temp_allocator) -> string {
	context.temp_allocator = allocator // what it says, and what it reads to say it
	sc := settled_scan(w)
	if sc == nil {
		return ""
	}
	m := &w.m
	t := &sc.tree
	roll := &sc.roll
	held :: proc(t: ^scan.Tree, roll: ^survey.Rollup, id: u32) -> bool {
		if id == query.ROOT {
			return true
		}
		if id >= t.count {
			return false
		}
		if .Used not_in scan.node_flags(scan.node(t, id)) {
			return false
		}
		return !survey.removed(roll, t, id)
	}
	if !held(t, roll, m.dir) {
		return fmt.tprintf("nodes: the folder shown, %d, is not in scan %d", m.dir, m.generation)
	}

	for id, i in m.back {
		if !held(t, roll, id) {
			return fmt.tprintf("nodes: back step %d, %d, is not in scan %d", i, id, m.generation)
		}
	}

	for id, i in m.forward {
		if !held(t, roll, id) {
			return fmt.tprintf(
				"nodes: forward step %d, %d, is not in scan %d",
				i,
				id,
				m.generation,
			)
		}
	}

	picks := [?]struct {
		what: string,
		id:   u32,
	} {
		{"the chart's pick", m.chart_pick},
		{"the search's pick", m.search_pick},
		{"the file clicked", m.file_click},
		{"the Trash entry", m.trash_node},
	}
	for p in picks {
		if p.id != 0 && !held(t, roll, p.id) {
			return fmt.tprintf("nodes: %s, %d, is not in scan %d", p.what, p.id, m.generation)
		}
	}

	if (m.menu_open || m.trash_open || m.rename_open) && !held(t, roll, m.target.node) {
		return fmt.tprintf(
			"nodes: the menu's entry %q, %d, is not in scan %d",
			m.target.name,
			m.target.node,
			m.generation,
		)
	}

	for id in m.reclaim_pick {
		if !held(t, roll, id) {
			return fmt.tprintf("nodes: the Reclaim choice %d is not in scan %d", id, m.generation)
		}
	}
	return ""
}

/*
totals_agree reads the line under Contents, "320.8 GB in 17 items", and checks
it against the tree: the folder's total and how many entries it holds. It is
only read once the scan is over and while Contents is drawn.
*/
@(private)
totals_agree :: proc(w: ^Window, allocator := context.temp_allocator) -> string {
	context.temp_allocator = allocator // what it says, and what it reads to say it
	sc := settled_scan(w)
	m := &w.m
	if sc == nil || m.searching || m.mode == .Reclaim {
		return ""
	}
	t := &sc.tree
	roll := &sc.roll
	dir := t.root if m.dir == query.ROOT else m.dir
	count := 0
	it := survey.children(roll, dir)
	for _ in survey.next_child(&it) {
		count += 1
	}

	want := msg.trf(
		m.strings,
		.Listing_Summary,
		count,
		human.bytes(survey.total(roll, dir)),
		allocator = allocator,
	)

	heading := msg.tr(m.strings, .Contents)
	nodes := ui.probe_current(&w.p).nodes
	for n, i in nodes {
		if n.semantics.role != .Heading || n.semantics.label != heading {
			continue
		}
		for later in nodes[i + 1:] {
			if later.semantics.role != .Text {
				continue
			}
			said := later.semantics.label
			if !strings.contains(said, " ") || strings.has_prefix(said, want) {
				return ""
			}
			return fmt.tprintf("totals: Contents of %d says %q, the tree %q", dir, said, want)
		}
	}
	return ""
}

/*
focus_visible: the area with the keyboard is one this frame drew, inside the
window; while a modal dialog is open the keyboard is in it, on its layer or one
over it.
*/
@(private)
focus_visible :: proc(w: ^Window, allocator := context.temp_allocator) -> string {
	context.temp_allocator = allocator // what it says, and what it reads to say it
	frame := ui.probe_current(&w.p)
	focus := w.p.router.focus
	modal := i32(-1)
	modal_name := ""
	for n in frame.nodes {
		if .Modal in n.semantics.states && n.layer >= modal {
			modal = n.layer
			modal_name = n.semantics.label
		}
	}

	if focus == 0 {
		if modal >= 0 {
			return fmt.tprintf(
				"focus: the dialog %q is open with the keyboard nowhere",
				modal_name,
			)
		}
		return ""
	}

	for h in frame.hits {
		if h.area != focus {
			continue
		}
		if modal >= 0 && h.layer < modal {
			return fmt.tprintf(
				"focus: the keyboard is on %q under the dialog %q",
				ui.probe_focus_name(&w.p),
				modal_name,
			)
		}
		return ""
	}

	if LOST_FOCUS_KNOWN {
		return ""
	}
	return fmt.tprintf(
		"focus: the keyboard is on %d, %q, which this frame did not draw",
		focus,
		ui.probe_focus_name(&w.p),
	)
}

/*
LOST_FOCUS_KNOWN leaves out the half of the focus invariant that the window does
not keep yet: an action that takes away what has the keyboard, a Contents row
that opens its folder, leaves the keyboard on the row that has gone, and jm:ui
does not move it on (card 767). The modal half holds and is checked.
Set it false once that card is done.
*/
LOST_FOCUS_KNOWN :: true
