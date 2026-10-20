package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../command"
import "../query"

@(private = "file")
Licence_Case :: struct {
	m:      Model,
	frames: [dynamic]bool, // what unlocked said before each frame was drawn
}

@(private = "file")
licence_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	c := (^Licence_Case)(user)
	append(&c.frames, unlocked(gtx, &c.m))
	view(gtx, &c.m)
}

// Pro is open on the first frame, before the host can have answered; after it,
// a host that has not answered leaves Pro locked. Export still opens: a CSV of
// this scan is free, and a locked window starts on that format. Once the host
// says Pro is on, Export opens on whatever format was left.
@(test)
no_licence_answer_is_locked_after_the_first_frame :: proc(t: ^testing.T) {
	c: Licence_Case
	c.frames = make([dynamic]bool, context.temp_allocator)
	model_init(&c.m, "/top")
	c.m.settings_read = true
	defer model_destroy(&c.m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, licence_frame, &c, {1000, 700}, fonts)
	defer render.headless_destroy(&h)
	ui.probe_deliver(
		&h.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = "/top"},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	if testing.expect(t, len(c.frames) >= 2) {
		testing.expect(t, c.frames[0], "the first frame is unlocked")
		testing.expect(t, !c.frames[len(c.frames) - 1], "after it, no answer is locked")
	}

	testing.expect(t, choose(&h.p, &c.m, "Export"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, c.m.export_open, "no licence still opens export")
	testing.expect(t, !c.m.licence_open, "and not the licence dialog")
	testing.expect_value(t, c.m.export_format, command.Export_Format.Csv)

	c.m.export_open = false
	c.m.licence_open = false
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	ui.probe_deliver(&h.p, query.Licence{}, query.Licence_Result{unlocked = true, trial_left = 30})
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(t, choose(&h.p, &c.m, "Export"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, c.m.export_open, "unlocked, Export opens")
}
