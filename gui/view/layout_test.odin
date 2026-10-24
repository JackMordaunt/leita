package leita_view

import "core:strings"

import "jm:ui"
import "jm:ui/ops"

// last_tag is the box of the last area drawn whose tag starts with prefix: the
// one on top, as a dialog is over the window it names the same things in.
last_tag :: proc(p: ^ui.Probe, prefix: string) -> (box: ops.Rect, found: bool) {
	for t in ui.probe_current(p).tags {
		if strings.has_prefix(t.name, prefix) {
			box, found = t.bounds, true
		}
	}
	return
}

// below is whether b, drawn, starts at or under a's bottom, a drawn too: nothing
// of the two overlaps.
below :: proc(a, b: ops.Rect) -> bool {
	return a.h > 0 && b.h > 0 && b.y >= a.y + a.h - 0.5
}
