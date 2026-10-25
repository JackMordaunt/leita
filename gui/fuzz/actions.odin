package gui_fuzz

import "core:fmt"
import "core:strings"

import "jm:ui"
import bl "jm:ui/blend2d"
import "jm:ui/ops"
import "jm:ui/render"

import harness "jm:fuzz"

/*
Action is one thing a person does to the window, drawn from a case's bytes.
Wait is first, so a zero byte, which shrinking turns every byte into, is the
action that does nothing. Each is a few frames of input and then settle.
*/
Action :: enum u8 {
	Wait,
	Let_Scan_Run, // the gate lets the reader on by a few directories
	Finish_Scan, // the scan runs to its end
	Rescan, // Ctrl or Cmd+R, which reaches the window under a dialog
	Settings_Item, // the settings menu, then one of its items: a dialog, Rescan, Stop, the theme
	Back, // Alt+Left
	Forward, // Alt+Right
	Click, // anything the frame lets be clicked, by where it is drawn
	Right_Click, // the same, with the right button: an entry's menu
	Double_Click,
	Key, // one key, Escape, Enter, Tab and the arrows among them
	Type, // text, into whatever has the keyboard
	Search, // Ctrl+F and a term
	Locate, // Ctrl+L, a place on the made-up disk, Enter: a new scan
	Reclaim, // the Reclaim chart, and its Clean up
	Chart, // Sunburst, Treemap, Icicle, or a colouring
	Resize,
	Theme, // the system's theme changes under the window
	Language, // the settings menu's Language, then one
	Licence, // the licence dialog, a licence pasted, Add
	Scroll,
	Hover,
	Drag, // the panels' divider
	Pick, // a file dialog the window opened is answered, or fails
	Paint, // the frame drawn to pixels, as a live window does
}

// Step is an Action and what it was drawn with, kept to say what a failing case did.
Step :: struct {
	action: Action,
	detail: string,
}

// SIZES are window sizes from the smallest the window allows (gui/main.odin)
// up; the first is how it opens.
SIZES := [?]ops.Size{{1280, 820}, {640, 420}, {800, 600}, {1920, 1080}, {641, 1200}, {2400, 430}}

// KEYS are what Key presses, the simplest first.
KEYS := [?]ui.Key {
	.Escape,
	.Enter,
	.Tab,
	.Space,
	.Up,
	.Down,
	.Left,
	.Right,
	.Home,
	.End,
	.Page_Up,
	.Page_Down,
	.Backspace,
	.Delete,
	.F2,
}

// WORDS are what a case types: names on the made-up disk, a path, and the
// awkward. All UTF-8, as a platform's text input always is.
WORDS := [?]string {
	"a",
	"Docker",
	".raw",
	"node_modules",
	"Library",
	"/Users/alex",
	"/Users/alex/Source",
	"/",
	" ",
	"日本語",
	"..",
	"\\",
	"*",
}

// PLACES are where Locate goes: all on the made-up disk, which every path is.
PLACES := [?]string {
	"/Users/alex",
	"/Users/alex/Source",
	"/Users/alex/Library",
	"/",
	"/Users/alex/no such folder",
	"",
}

// SETTINGS are the settings menu's items, by the label each is found by.
SETTINGS := [?]string {
	"About Leita",
	"Rescan",
	"Stop",
	"Licence",
	"Monitoring",
	"History",
	"Export",
	"Dark theme",
	"Light theme",
}

CHARTS := [?]string{"Sunburst", "Treemap", "Icicle", "Reclaim", "Type", "Change", "Size", "Age"}

LANGUAGES := [?]string {
	"English",
	"Deutsch",
	"日本語",
	"Français",
	"Español",
	"Русский",
	"中文（简体）",
	"한국어",
	"Italiano",
	"Português (Brasil)",
}

// act draws one action from src, carries it out, and says what it did.
act :: proc(w: ^Window, src: ^harness.Source, allocator := context.temp_allocator) -> Step {
	context.temp_allocator = allocator // what it draws, and the Step that says so
	a := Action(harness.integer_in(src, 0, len(Action)))
	detail := ""
	p := &w.p
	switch a {
	case .Wait:
		ui.probe_advance(p, harness.integer_in(src, 1, 30), 1.0 / 60)
	case .Let_Scan_Run:
		n := 1 << uint(harness.integer_in(src, 0, 12))
		let_through(n)
		detail = fmt.tprint(n)
	case .Finish_Scan:
		if !finish(w) {
			detail = "the scan did not finish"
		}
	case .Rescan:
		ui.probe_key(p, .R, {ui.SHORTCUT})
	case .Settings_Item:
		item := harness.choice(src, SETTINGS[:])
		detail = item
		if ui.probe_click(p, "Settings") {
			ui.probe_advance(p, 6, 1.0 / 60)
			ui.probe_click_top(p, item)
		}
	case .Back:
		ui.probe_key(p, .Left, {.Alt})
	case .Forward:
		ui.probe_key(p, .Right, {.Alt})
	case .Click, .Right_Click, .Double_Click:
		button := ui.Button.Right if a == .Right_Click else .Left
		clicks := u8(2) if a == .Double_Click else 1
		if at, name, ok := pick_area(w, src); ok {
			detail = name
			ui.probe_click_at(p, at, button, clicks)
		}
	case .Key:
		k := harness.choice(src, KEYS[:])
		mods: ui.Mods
		if harness.boolean(src) {
			mods = {.Shift}
		}
		detail = fmt.tprint(k, mods)
		ui.probe_key(p, k, mods)
	case .Type:
		text := harness.text(src, WORDS[:], 4, context.temp_allocator)
		detail = text
		ui.probe_type(p, text)
	case .Search:
		ui.probe_key(p, .F, {ui.SHORTCUT})
		ui.probe_advance(p, 2, 1.0 / 60)
		text := harness.text(src, WORDS[:], 3, context.temp_allocator)
		detail = text
		ui.probe_type(p, text)
	case .Locate:
		place := harness.choice(src, PLACES[:])
		detail = place
		ui.probe_key(p, .L, {ui.SHORTCUT})
		ui.probe_advance(p, 2, 1.0 / 60)
		ui.probe_key(p, .A, {ui.SHORTCUT})
		ui.probe_type(p, place)
		ui.probe_key(p, .Enter)
	case .Reclaim:
		ui.probe_click(p, "Reclaim")
		settle(w)
		if harness.boolean(src) && ui.probe_click(p, "Clean up") {
			detail = "Clean up"
			settle(w)
			confirm := harness.choice(src, []string{"Cancel", "Delete"})
			detail = strings.concatenate({detail, ", ", confirm}, context.temp_allocator)
			ui.probe_click_top(p, confirm)
		}
	case .Chart:
		c := harness.choice(src, CHARTS[:])
		detail = c
		ui.probe_click(p, c)
	case .Resize:
		s := harness.choice(src, SIZES[:])
		detail = fmt.tprint(s)
		p.size = s
	case .Theme:
		w.m.dark = !w.m.dark
	case .Language:
		lang := harness.choice(src, LANGUAGES[:])
		detail = lang
		if ui.probe_click(p, "Settings") {
			ui.probe_advance(p, 6, 1.0 / 60)
			if ui.probe_click_top(p, "Language") {
				ui.probe_advance(p, 10, 1.0 / 60)
				ui.probe_click_top(p, lang)
			}
		}
	case .Licence:
		if ui.probe_click(p, "Settings") {
			ui.probe_advance(p, 6, 1.0 / 60)
			ui.probe_click_top(p, "Licence")
			settle(w)
			text := harness.text(
				src,
				[]string{"LEITA-", "AAAA", "-", "{\"licence\":1}", "\n"},
				4,
				context.temp_allocator,
			)
			detail = text
			ui.probe_click(p, "Licence to add")
			ui.probe_type(p, text)
			if harness.boolean(src) {
				ui.probe_click_top(p, "Add licence")
			}
		}
	case .Scroll:
		at := point_in(w, src)
		dy := f32(harness.integer_in(src, -8, 9)) * 60
		detail = fmt.tprint(at, dy)
		ui.probe_scroll_at(p, at, dy)
	case .Hover:
		at := point_in(w, src)
		ui.probe_move(p, at.x, at.y)
	case .Drag:
		dx := f32(harness.integer_in(src, -20, 21)) * 20
		dy := f32(harness.integer_in(src, -20, 21)) * 20
		detail = fmt.tprint(dx, dy)
		ui.probe_drag(p, "Resize panels", dx, dy)
	case .Pick:
		if q, asked := ui.probe_picking(p); asked {
			if harness.boolean(src) {
				detail = "fail"
				ui.probe_pick_fail(p)
			} else {
				ext := ""
				if dot := strings.last_index_byte(q.name, '.'); dot >= 0 {
					ext = q.name[dot:]
				}
				chosen := fmt.tprintf("%s/picked%s", w.dir, ext)
				detail = chosen
				ui.probe_pick(p, chosen)
			}
		}
	case .Paint:
		paint(w)
	}
	settle(w)
	return {a, strings.clone(detail, allocator)}
}

// point_in is a point in the window, on a grid of 64ths of it.
@(private)
point_in :: proc(w: ^Window, src: ^harness.Source) -> ops.Point {
	x := f32(harness.integer_in(src, 0, 64)) / 64
	y := f32(harness.integer_in(src, 0, 64)) / 64
	return {x * w.p.size.x, y * w.p.size.y}
}

/*
pick_area is the middle of one of the frame's areas that takes a click, and
its name: the topmost layer's when an overlay is open, as a person can reach
only that, and otherwise any. What is drawn changes from frame to frame, so the
choice is an index into this frame's areas, the same for the same frame.
*/
@(private)
pick_area :: proc(
	w: ^Window,
	src: ^harness.Source,
	allocator := context.temp_allocator,
) -> (
	at: ops.Point,
	name: string,
	ok: bool,
) {
	frame := ui.probe_current(&w.p)
	top := i32(0)
	for h in frame.hits {
		if .Press in h.kinds {
			top = max(top, h.layer)
		}
	}

	areas := make([dynamic]ops.Rect, allocator)
	names := make([dynamic]string, allocator)
	for n in frame.nodes {
		if n.layer < top || n.rect.w <= 0 || n.rect.h <= 0 {
			continue
		}
		if !clickable(n.semantics.role) {
			continue
		}
		r := n.rect
		if r.x + r.w <= 0 || r.y + r.h <= 0 || r.x >= w.p.size.x || r.y >= w.p.size.y {
			continue
		}
		append(&areas, r)
		append(&names, n.semantics.label)
	}
	if len(areas) == 0 {
		return {}, "", false
	}
	i := harness.integer_in(src, 0, len(areas))
	r := areas[i]
	// Near the start of a row, where its name is: a row's centre may be a bar.
	x := r.x + min(r.w / 2, 24)
	// The label is the frame's, gone when the next is laid out.
	return {x, r.y + r.h / 2}, strings.clone(names[i], allocator), true
}

@(private)
clickable :: proc(role: ops.Role) -> bool {
	#partial switch role {
	case .Button,
	     .Checkbox,
	     .Radio,
	     .Switch,
	     .Menu_Item,
	     .Menu_Item_Checkbox,
	     .Menu_Item_Radio,
	     .List_Item,
	     .Tree_Item,
	     .Tab,
	     .Link,
	     .Text_Field,
	     .Combo_Box,
	     .Option,
	     .Slider:
		return true
	}
	return false
}

// paint draws the frame to an image in memory, as a live window does each frame.
@(private)
paint :: proc(w: ^Window) {
	image: bl.ImageCore
	bl.image_init(&image)
	defer bl.image_destroy(&image)

	if bl.image_create(&image, i32(w.p.size.x), i32(w.p.size.y), .PRGB32) != 0 {
		return
	}
	render.render(&w.r, ui.probe_current(&w.p), &image, w.clear)
}
