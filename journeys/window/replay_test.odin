/*
Package journeys_window checks what the operating system's own input did to the
real window. tools/journeys/window.py starts the window on the made-up disk,
gives it the keyboard through the window system, presses the search shortcut,
types a name and closes it; the window recorded each frame's input as it got it
(JM_UI_RECORD). Here that recording is replayed into the view, which needs no
host: the answers the window had are in the recording. Only the accessibility
tree is checked; the PNG of the last frame is kept for a person to look at.

just window-journey runs both; LEITA_WINDOW_RECORDING names the recording.
*/
package journeys_window

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:ui"
import bl "jm:ui/blend2d"
import "jm:ui/render"

import "../../gui/view"
import "../../synth"

// The keys the operating system delivered reached the window: the search
// shortcut opened the field with the keyboard in it, the name typed is its
// value, and the window found the file it names.
@(test)
the_keys_the_system_sent_reached_the_search :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 2 * time.Minute)
	path := os.get_env("LEITA_WINDOW_RECORDING", context.temp_allocator)
	if !testing.expect(t, path != "", "LEITA_WINDOW_RECORDING names no recording") {
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expectf(t, err == nil, "could not read %s: %v", path, err) {
		return
	}

	m: view.Model
	view.model_init(&m, synth.HOME)
	defer view.model_destroy(&m)

	faces := view.fonts()
	defer delete(faces)
	backs := view.fallbacks(faces)
	defer delete(backs)
	h: render.Headless
	render.headless_init(&h, view.view, &m, {1280, 820}, faces, fallbacks = backs)
	defer render.headless_destroy(&h)

	frames, ok := ui.probe_replay(&h.p, data)
	testing.expectf(t, ok, "the recording stops being one after %d frames", frames)
	said := ui.probe_semantics(&h.p, context.temp_allocator)
	keep(&h, filepath.dir(path), said)

	testing.expectf(
		t,
		strings.contains(said, `text field "Search" value "Docker.raw" focused`),
		"the field holds what was typed, with the keyboard, after %d frames:\n%s",
		frames,
		said,
	)
	testing.expectf(
		t,
		strings.contains(said, `list item "Docker.raw, 32.7 GB, in `),
		"the search found it:\n%s",
		said,
	)
}

// keep writes the last frame replayed beside the recording: replayed.png and
// replayed.txt, the tree a screen reader is told.
keep :: proc(h: ^render.Headless, dir, said: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/replayed.txt", dir), said)

	image: bl.ImageCore
	bl.image_init(&image)
	defer bl.image_destroy(&image)

	if bl.image_create(&image, i32(h.p.size.x), i32(h.p.size.y), .PRGB32) != 0 {
		return
	}

	render.render(&h.r, ui.probe_current(&h.p), &image, h.clear)
	png := strings.clone_to_cstring(fmt.tprintf("%s/replayed.png", dir), context.temp_allocator)
	_ = bl.image_write_to_file(&image, png, nil)
}
