/*
Package journeys_gui walks the window the way a person does, on the made-up disk:
the real host, desk and reader on their own threads, and the real view in a
probe in place of a window. What a journey checks is what a screen reader is
told (ui.probe_semantics, the tree AccessKit hands the platform): labels, the
sizes said, which item is selected. Pixels are only kept, never compared.

just journeys runs these after the command line's. LEITA_JOURNEY_ARTIFACTS names
a folder each journey keeps its evidence in, a PNG and the accessibility tree of
every step it names; unset, nothing is kept.

The made-up disk is the oracle: the same entries and sizes each run of a day
(synth), so a size said is checked exactly.
*/
package journeys_gui

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:ui"
import bl "jm:ui/blend2d"
import "jm:ui/ops"
import "jm:ui/render"

import "../../gui/app"
import "../../gui/view"
import "../../synth"

// HOME is the made-up disk's home folder, the path a journey opens on.
HOME :: synth.HOME

// Window is one run of the application for a journey: the host, the view's
// model and the probe drawing it, with a data folder of its own.
Window :: struct {
	name:     string, // the journey's, which names its evidence
	dir:      string, // the data folder: history, settings, licence, reports
	steps:    int, // evidence kept so far
	h:        app.Host,
	m:        view.Model,
	using hl: render.Headless,
	data:     ui.Data_Host,
	faces:    []ops.Font_Ref,
	backs:    []ops.Font_Id,
}

/*
budget is the time a journey may take before the runner fails it, so one that
hangs fails by name instead of holding the run until the job's timeout. Each
journey sets its own: what it waits on differs. A whole scan of the made-up
disk is paced as a real walk; its status line said 9.2 s on 2026-10-24.
*/
budget :: proc(t: ^testing.T, seconds: int) {
	testing.set_fail_timeout(t, time.Duration(seconds) * time.Second)
}

// folder is a fresh data folder for name, emptied of any an earlier run left.
folder :: proc(name: string) -> string {
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.aprintf(
		"%s/leita_gui_journey_%s_%d",
		tmp,
		name,
		os.get_pid(),
		allocator = runtime.heap_allocator(),
	)
	os.remove_all(dir)
	_ = os.make_directory(dir)
	return dir
}

/*
open starts the application on path, scanning the made-up disk of day, keeping
its history, settings and licence in dir ("" for a folder of its own, removed
by close). Two windows given one dir are two runs on one machine.
*/
open :: proc(w: ^Window, t: ^testing.T, name: string, day: int, dir := "", path := HOME) {
	w.name = name
	w.dir = dir if dir != "" else folder(name)
	app.init(
		&w.h,
		path,
		kept = fmt.tprintf("%s/history.db", w.dir),
		reports = w.dir,
		thumbs = w.dir,
		made_up = day,
	)
	w.data = app.data_host(&w.h)
	view.model_init(&w.m, path)
	w.faces = view.fonts()
	w.backs = view.fallbacks(w.faces)
	render.headless_init(
		&w.hl,
		view.view,
		&w.m,
		{1280, 820},
		w.faces,
		fallbacks = w.backs,
		data = &w.data,
	)
	ui.probe_frame(&w.p)
}

// close stops the application, and removes its data folder unless keep.
close :: proc(w: ^Window, keep := false) {
	render.headless_destroy(&w.hl)
	view.model_destroy(&w.m)
	app.stop(&w.h)
	delete(w.backs)
	delete(w.faces)
	if !keep {
		os.remove_all(w.dir)
		delete(w.dir, runtime.heap_allocator())
	}
}

// forget removes a data folder close was told to keep.
forget :: proc(dir: string) {
	os.remove_all(dir)
	delete(dir, runtime.heap_allocator())
}

// frames runs n frames a sixtieth of a second apart, so what animates arrives.
frames :: proc(w: ^Window, n := 60) {
	ui.probe_advance(&w.p, n, 1.0 / 60)
}

/*
settle runs frames, taking in what the host answered, until one tags name (or,
with present false, none does), for at most seconds. A finished scan sends
nothing more, so the frame already drawn is looked at first.
*/
settle :: proc(w: ^Window, name: string, present := true, seconds := 60) -> bool {
	deadline := time.tick_now()._nsec + i64(seconds) * i64(time.Second)
	for {
		if ui.probe_tagged(&w.p, name) == present {
			return true
		}
		if time.tick_now()._nsec >= deadline {
			return false
		}
		ui.probe_frame(&w.p)
		time.sleep(2 * time.Millisecond)
	}
}

// settle_said is settle on what a screen reader is told: until it holds text.
settle_said :: proc(w: ^Window, text: string, seconds := 60) -> bool {
	deadline := time.tick_now()._nsec + i64(seconds) * i64(time.Second)
	for {
		if strings.contains(said(w), text) {
			return true
		}
		if time.tick_now()._nsec >= deadline {
			return false
		}
		ui.probe_frame(&w.p)
		time.sleep(2 * time.Millisecond)
	}
}

// said is the accessibility tree of the current frame, as a screen reader
// reads it, in the temporary allocator.
said :: proc(w: ^Window) -> string {
	return ui.probe_semantics(&w.p, context.temp_allocator)
}

// click presses the first area tagged name and lets the host answer it.
click :: proc(w: ^Window, name: string) -> bool {
	frames(w, 2)
	if !ui.probe_click(&w.p, name) {
		return false
	}
	frames(w, 2)
	return true
}

// click_top presses the topmost area tagged name: a dialog's button over a
// toolbar's of the same name.
click_top :: proc(w: ^Window, name: string) -> bool {
	frames(w, 2)
	if !ui.probe_click_top(&w.p, name) {
		return false
	}
	frames(w, 2)
	return true
}

// node is the id of the semantic node whose label begins with prefix, 0 if
// the frame has none.
node :: proc(w: ^Window, prefix: string) -> ops.Area_Id {
	for n in ui.probe_current(&w.p).nodes {
		if strings.has_prefix(n.semantics.label, prefix) {
			return n.id
		}
	}
	return 0
}

/*
row is where the row labelled name is in the panel under the heading labelled
under: a Contents row and the location bar's step can share a name, and a tag
finds the first.
*/
row :: proc(w: ^Window, under, name: string) -> (at: ops.Rect, ok: bool) {
	top: Maybe(ops.Rect)
	for n in ui.probe_current(&w.p).nodes {
		r := n.rect
		if top == nil {
			if n.semantics.label == under {
				top = r
			}
			continue
		}
		if n.semantics.label == name && r.x >= top.?.x && r.y > top.?.y {
			return r, true
		}
	}
	return {}, false
}

// open_row clicks the name of the row labelled name under the heading under,
// near its start: the probe gives a row's button its whole width, whose centre
// is on the share bar.
open_row :: proc(w: ^Window, under, name: string, button := ui.Button.Left) -> bool {
	r := row(w, under, name) or_return
	ui.probe_click_at(&w.p, {r.x + 24, r.y + r.h / 2}, button)
	frames(w, 2)
	return true
}

// reader_does pushes an action as the platform's accessibility bridge does
// when a screen reader asks for it.
reader_does :: proc(w: ^Window, kind: ops.Event_Kind, area: ops.Area_Id) {
	ui.router_push(&w.p.router, {kind = kind, area = area})
	frames(w, 2)
}

// show is the tree said, as a journey's failure message gives it.
show :: proc(w: ^Window) -> string {
	return said(w)
}

/*
keep writes the evidence of a step: <journey>-<n>-<step>.png and .txt, the
picture of the window and the tree a screen reader is told, into the folder
LEITA_JOURNEY_ARTIFACTS names. Nothing is kept when it names none.
*/
keep :: proc(w: ^Window, step: string) {
	out := os.get_env("LEITA_JOURNEY_ARTIFACTS", context.temp_allocator)
	if out == "" {
		return
	}
	_ = os.make_directory_all(out)
	w.steps += 1
	named, _ := strings.replace_all(
		strings.to_lower(step, context.temp_allocator),
		" ",
		"-",
		context.temp_allocator,
	)
	base := fmt.tprintf("%s/%s-%02d-%s", out, w.name, w.steps, named)
	_ = os.write_entire_file(fmt.tprintf("%s.txt", base), said(w))
	frame := ui.probe_current(&w.p)

	image: bl.ImageCore
	bl.image_init(&image)
	defer bl.image_destroy(&image)
	if bl.image_create(&image, i32(w.p.size.x), i32(w.p.size.y), .PRGB32) != 0 {
		return
	}
	render.render(&w.r, frame, &image, w.clear)
	_ = bl.image_write_to_file(
		&image,
		strings.clone_to_cstring(fmt.tprintf("%s.png", base), context.temp_allocator),
		nil,
	)
}
