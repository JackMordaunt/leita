package estoile_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../command"
import "../query"

@(private = "file")
Export_Case :: struct {
	m:    Model,
	prog: query.Progress_Result,
}

@(private = "file")
export_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	c := (^Export_Case)(user)
	scheme := primer.theme_scheme(.Light)
	primer.use(&scheme, .Light)
	primer.use_fonts(FONTS)
	if ui.row(gtx, gap = 8) {
		export_button(gtx, &c.m, &c.prog)
	}
	export_dialog(gtx, &c.m, &c.prog)
}

// Export does nothing while the scan runs; once it is done it opens the dialog,
// which sends the format chosen, PDF unless another is, and whether to include
// Reclaim, and closes.
@(test)
export_asks_for_a_format_and_sends_it :: proc(t: ^testing.T) {
	c: Export_Case
	c.m.export_format = .Pdf
	c.m.generation = 3
	c.prog = {
		generation = 3,
		state      = .Scanning,
		target     = "/data",
	}
	defer model_destroy(&c.m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, export_frame, &c, {800, 600}, fonts)
	defer render.headless_destroy(&h)

	ui.probe_click(&h.p, "Export")
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, !c.m.export_open, "a scan still running cannot be exported")

	c.prog.state = .Done
	ui.probe_frame(&h.p)
	testing.expect(t, ui.probe_click(&h.p, "Export"))
	ui.probe_advance(&h.p, 20, 1.0 / 60)
	testing.expect(t, c.m.export_open, "a finished scan can")
	testing.expect(t, ui.probe_tagged(&h.p, "Pages to print or attach to a ticket"), "PDF first")

	testing.expect(t, ui.probe_click(&h.p, "JSON"))
	testing.expect(t, ui.probe_click(&h.p, "Include Reclaim candidates"))
	testing.expect_value(t, c.m.export_format, command.Export_Format.Json)
	testing.expect(t, c.m.export_reclaim, "Reclaim is included")

	testing.expect(t, ui.probe_click_top(&h.p, "Export"), "the dialog's Export")
	sent: Maybe(command.Export)
	for cmd in ui.probe_commands(&h.p) {
		if v, ok := ui.command_as(cmd, command.Command); ok {
			if e, is_export := v.(command.Export); is_export {
				sent = e
			}
		}
	}
	testing.expect_value(
		t,
		sent,
		Maybe(command.Export)(command.Export{generation = 3, format = .Json, reclaim = true}),
	)
	testing.expect(t, !c.m.export_open, "the dialog closed")
}
