/*
Package journeys_gui holds the window's user stories: each test is one story a
person comes to Leita with, walked end to end the way they would, on the made-up
disk, in each Scenario it names (SCENARIOS: the theme, a small window, a
translated window). A disk the made-up one cannot be, empty, shut to Leita or
changing while it is read, is a real folder made for the story (disk_test.odin).

A story runs the real host, desk and reader on their own threads, and the real
view in a probe in place of a window. What it checks is what a screen reader is
told (ui.probe_semantics, the tree AccessKit hands the platform): labels, the
sizes said, which item is selected, where the keyboard is. Pixels are never
compared: a PNG of each step is kept only for a person to look at.

just journeys runs these after the command line's. LEITA_JOURNEY_ARTIFACTS names
a folder each story keeps its evidence in, a PNG and the accessibility tree of
every step it names; unset, nothing is kept.

The made-up disk is the oracle: the same entries and sizes each run of a day
(synth), so a size said is checked exactly.
*/
package journeys_gui

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:i18n"
import "jm:ui"
import bl "jm:ui/blend2d"
import "jm:ui/ops"
import "jm:ui/render"

import "../../gui/app"
import "../../gui/msg"
import "../../gui/view"
import "../../scan"
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
	words:    msg.Strings, // the scenario's language, which the story's checks are in
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

// Scenario is how a story's window is set up: its name, as the story's
// evidence is named, its size, its theme, and its language.
Scenario :: struct {
	name:   string,
	size:   ops.Size,
	dark:   bool,
	locale: i18n.Locale,
}

// LIGHT is the window as it opens (gui/main.odin), the scenario a story that
// names none runs in.
LIGHT :: Scenario{"light", {1280, 820}, false, .English}

// DARK is the same window in the dark theme.
DARK :: Scenario{"dark", {1280, 820}, true, .English}

// SMALL is the window at its minimum size (gui/main.odin).
SMALL :: Scenario{"small", {640, 420}, false, .English}

// GERMAN is the window in German, as a person whose system is in German opens
// it: what it says is checked in German (tr, trf).
GERMAN :: Scenario{"german", {1280, 820}, false, .German}

// SCENARIOS are the setups every story that loops over them runs in.
SCENARIOS := [?]Scenario{LIGHT, DARK, SMALL, GERMAN}

// tr is key's text in the language of w's scenario, as the window says it.
tr :: proc(w: ^Window, key: msg.Msg) -> string {
	return msg.tr(&w.words, key)
}

// trf is key's text in the language of w's scenario with args filled in, in
// the temporary allocator.
trf :: proc(w: ^Window, key: msg.Msg, args: ..i18n.Arg) -> string {
	return msg.trf(&w.words, key, ..args)
}

/*
open starts the application on path, scanning the made-up disk of day, keeping
its history, settings and licence in dir ("" for a folder of its own, removed
by close), set up as scenario says. Two windows given one dir are two runs on
one machine. A day of REAL scans path itself, a folder on this disk; the walk
then calls after_list with after_list_data after each directory it lists. A
licence key is exchanged at activate_url; updates are looked for at
release_base, signed by update_key, to replace update_exe (app.init).
*/
open :: proc(
	w: ^Window,
	t: ^testing.T,
	name: string,
	day: int,
	dir := "",
	path := HOME,
	scenario := LIGHT,
	made_up_clock: synth.Clock = {},
	after_list: proc(path: string, data: rawptr) = nil,
	after_list_data: rawptr = nil,
	activate_url := "",
	release_base := "",
	update_key: []byte = nil,
	update_exe := "",
) {
	w.name = name if scenario.name == LIGHT.name else fmt.tprintf("%s-%s", name, scenario.name)
	w.dir = dir if dir != "" else folder(name)
	app.init(
		&w.h,
		path,
		kept = fmt.tprintf("%s/history.db", w.dir),
		reports = w.dir,
		thumbs = w.dir,
		made_up = day if day != REAL else nil,
		made_up_clock = made_up_clock,
		after_list = after_list,
		after_list_data = after_list_data,
		activate_url = activate_url,
		release_base = release_base,
		update_key = update_key,
		update_exe = update_exe,
	)
	w.data = app.data_host(&w.h)
	msg.init(&w.words, scenario.locale)
	view.model_init(&w.m, path, scenario.locale)
	w.m.dark = scenario.dark
	w.faces = view.fonts()
	w.backs = view.fallbacks(w.faces)
	render.headless_init(
		&w.hl,
		view.view,
		&w.m,
		scenario.size,
		w.faces,
		fallbacks = w.backs,
		data = &w.data,
	)
	ui.probe_frame(&w.p)
}

// REAL is the day open is given to scan a real folder, not the made-up disk.
REAL :: -1

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

/*
real_folder is a new, empty folder for a story that scans this disk, named for
name and this process, as the scan names it: the temp directory with its links
resolved (macOS's /var is /private/var), joined with the platform's separator
and, on Windows, as scan.location stores it. Remove it with os.remove_all.
*/
real_folder :: proc(t: ^testing.T, name: string) -> string {
	tmp, tmp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, tmp_err == nil, "no temp directory")
	info, stat_err := os.stat(tmp, context.temp_allocator)
	testing.expect(t, stat_err == nil, "the temp directory is not there")
	root := within(
		strings.trim_right(info.fullpath, `/\`),
		fmt.tprintf("leita_story_%s_%d", name, os.get_pid()),
	)
	os.remove_all(root)
	testing.expectf(t, os.make_directory(root) == nil, "could not make %s", root)
	when ODIN_OS == .Windows {
		named, _, err := scan.resolve(root)
		if err == nil {
			defer scan.target_destroy(&named)

			if got := scan.location(named, context.temp_allocator); got != "" {
				root = got
			}
		}
	}
	return root
}

// escaped is s as the accessibility tree quotes it: each backslash doubled, as
// a Windows path's are.
escaped :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, `\`, `\\`, context.temp_allocator)
	return out
}

// within is the path of names below dir, joined as the scan joins them.
within :: proc(dir: string, names: ..string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, dir)
	for name in names {
		strings.write_string(&sb, scan.SEPARATOR)
		strings.write_string(&sb, name)
	}
	return strings.to_string(sb)
}

// write_file makes a file of size bytes at path, and fails the story when it
// cannot.
write_file :: proc(t: ^testing.T, path: string, size: int) {
	body := make([]byte, size, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
}

// make_folder makes the folder at path, and fails the story when it cannot.
make_folder :: proc(t: ^testing.T, path: string) {
	testing.expectf(t, os.make_directory(path) == nil, "could not make %s", path)
}
