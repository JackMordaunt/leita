package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/primer"

@(private = "file")
Label_Case :: struct {
	name:      string,
	room:      f32,
	width:     f32,
	truncated: bool,
	lines:     int,
}

@(private = "file")
label_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	c := (^Label_Case)(user)
	st := primer.text_style(.Small)
	para := tree_label(gtx, c.name, st, gtx.font, c.room)
	c.width, c.truncated, c.lines = para.width, para.truncated, len(para.lines)
}

// A box's name wider than the box is cut to one line that fits, with an
// ellipsis, rather than clipped mid-letter at the box's edge; one that fits is
// left whole.
@(test)
a_box_label_too_wide_ends_in_an_ellipsis :: proc(t: ^testing.T) {
	for name in ([2]string{"Final Cut Pro.app", "com.docker.docker"}) {
		c := Label_Case {
			name = name,
			room = 40,
		}
		p: ui.Probe
		ui.probe_init(&p, label_frame, &c, {200, 100})
		ui.probe_frame(&p)
		ui.probe_destroy(&p)
		testing.expectf(t, c.truncated, "%s is cut", name)
		testing.expectf(t, c.lines == 1, "%s keeps to one line, got %d", name, c.lines)
		testing.expectf(t, c.width <= c.room, "%s fits: %v in %v", name, c.width, c.room)
	}
	c := Label_Case {
		name = "bin",
		room = 200,
	}
	p: ui.Probe
	ui.probe_init(&p, label_frame, &c, {200, 100})
	defer ui.probe_destroy(&p)

	ui.probe_frame(&p)
	testing.expect(t, !c.truncated, "a name that fits is whole")
}
