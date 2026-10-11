package leita_view

import "core:strings"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

@(private = "file")
Cut_Case :: struct {
	path:  string,
	width: f32,
	cut:   [256]u8,
	len:   int,
}

@(private = "file")
cut_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	c := (^Cut_Case)(user)
	c.len = copy(c.cut[:], middle_cut(gtx, c.path, primer.text_style(.Small), c.width))
}

// A path too long for its line keeps its start and its end, the middle left out.
@(test)
a_long_path_is_cut_in_the_middle :: proc(t: ^testing.T) {
	c := Cut_Case {
		path  = "/home/jfm/Source/Personal/leita/gui/view/sunburst.odin",
		width = 200,
	}
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
	}
	h: render.Headless
	render.headless_init(&h, cut_frame, &c, {400, 100}, fonts)
	defer render.headless_destroy(&h)
	cut := string(c.cut[:c.len])
	testing.expectf(t, strings.has_prefix(cut, "/home/…/"), "it keeps the start: %q", cut)
	testing.expectf(t, strings.has_suffix(cut, "/sunburst.odin"), "it keeps the end: %q", cut)
	testing.expectf(t, len(cut) < len(c.path), "it is shorter: %q", cut)

	// One that fits is left whole.
	c.width = 2000
	ui.probe_frame(&h.p)
	testing.expect_value(t, string(c.cut[:c.len]), c.path)
}
