package leita_view

import "core:strings"
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
// which closes and asks the save dialog where, in the reports folder, under a
// name for the target and the format chosen, PDF unless another is; then it
// sends the format, whether to include Reclaim, and the path chosen, or no path
// when no save dialog could open.
@(test)
export_asks_for_a_format_and_sends_it :: proc(t: ^testing.T) {
	c: Export_Case
	c.m.export_format = .Pdf
	c.m.generation = 3
	c.prog = {
		generation = 3,
		state      = .Scanning,
		target     = "/data",
		reports    = "/home/me/Documents",
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
	testing.expect(t, !c.m.export_open, "the dialog closed")
	testing.expect(t, sent_export(&h) == nil, "nothing sent before the save dialog answers")
	q, asked := ui.probe_picking(&h.p)
	testing.expect(t, asked, "the save dialog opened")
	testing.expect_value(t, q.kind, ui.Pick_Kind.Save)
	testing.expect_value(t, q.start, "/home/me/Documents")
	testing.expectf(
		t,
		strings.has_prefix(q.name, "leita-report-data-") && strings.has_suffix(q.name, ".json"),
		"%s is named for the target and the format",
		q.name,
	)
	if testing.expect_value(t, len(q.filters), 1) {
		testing.expect_value(t, q.filters[0], ui.Pick_Filter{"JSON data", "json"})
	}

	testing.expect(t, ui.probe_pick(&h.p, "/home/me/mine.json"))
	ui.probe_frame(&h.p)
	want := command.Export {
		generation = 3,
		format     = .Json,
		reclaim    = true,
		path       = command.text_make("/home/me/mine.json"),
	}
	testing.expect_value(t, sent_export(&h), Maybe(command.Export)(want))

	// No save dialog: the same Export, to no path, for the host to name.
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	c.prog.notice.id += 1 // the first export's notice
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(t, ui.probe_click(&h.p, "Export"), "the toolbar's Export")
	ui.probe_advance(&h.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_click_top(&h.p, "Export"), "the dialog's Export")
	testing.expect(t, ui.probe_pick_fail(&h.p))
	ui.probe_frame(&h.p)
	want.path = {}
	testing.expect_value(t, sent_export(&h), Maybe(command.Export)(want))
}

// sent_export is the Export the last frame sent, if it sent one.
@(private = "file")
sent_export :: proc(h: ^render.Headless) -> (sent: Maybe(command.Export)) {
	for cmd in ui.probe_commands(&h.p) {
		if v, ok := ui.command_as(cmd, command.Command); ok {
			if e, is_export := v.(command.Export); is_export {
				sent = e
			}
		}
	}
	return
}

// From the dialog's Export until the host's notice, the toolbar's Export reads
// Exporting… and is heard as a disabled button, and a click on it opens nothing;
// the notice ends it whether the report was saved or not, and whether or not
// the window heard the host begin. A cancelled save dialog ends it with nothing
// sent.
@(test)
export_is_busy_until_its_notice :: proc(t: ^testing.T) {
	c: Export_Case
	c.m.export_format = .Csv
	c.m.generation = 3
	c.prog = {
		generation = 3,
		state = .Done,
		target = "/data",
		notice = {id = 7},
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

	send :: proc(t: ^testing.T, h: ^render.Headless) {
		ui.probe_frame(&h.p)
		testing.expect(t, ui.probe_click(&h.p, "Export"), "the toolbar's Export")
		ui.probe_advance(&h.p, 20, 1.0 / 60)
		testing.expect(t, ui.probe_click_top(&h.p, "Export"), "the dialog's Export")
		ui.probe_advance(&h.p, 20, 1.0 / 60)
	}
	pick :: proc(t: ^testing.T, h: ^render.Headless, path: string) {
		testing.expect(t, ui.probe_pick(&h.p, path), "the save dialog was open")
		ui.probe_advance(&h.p, 2, 1.0 / 60)
	}
	busy :: proc(t: ^testing.T, h: ^render.Headless, c: ^Export_Case, want: bool, why: string) {
		testing.expectf(t, ui.probe_tagged(&h.p, "Exporting…") == want, "busy %v: %s", want, why)
		testing.expectf(t, ui.probe_tagged(&h.p, "Export") == !want, "idle %v: %s", !want, why)
		said := ui.probe_semantics(&h.p, context.temp_allocator)
		testing.expectf(
			t,
			// The report spells the ellipsis as an escape.
			strings.contains(said, `button "Exporting\u2026" disabled`) == want,
			"%s:\n%s",
			why,
			said,
		)
		if want {
			// A second Export cannot be asked for while one runs.
			ui.probe_click(&h.p, "Exporting…")
			ui.probe_advance(&h.p, 20, 1.0 / 60)
			testing.expect(t, !c.m.export_open, "the busy button opens no dialog")
		}
	}

	busy(t, &h, &c, false, "nothing asked for yet")
	send(t, &h)
	busy(t, &h, &c, true, "asking where")
	pick(t, &h, "")
	busy(t, &h, &c, false, "cancelled")
	testing.expect(t, sent_export(&h) == nil, "a cancel sends nothing")

	send(t, &h)
	pick(t, &h, "/home/me/r.csv")
	busy(t, &h, &c, true, "sent, before the host has said anything")
	c.prog.exporting = true
	ui.probe_frame(&h.p)
	busy(t, &h, &c, true, "the host is writing it")
	c.prog.exporting = false
	c.prog.notice = {
		id    = 8,
		saved = true,
		text  = "Saved report to /home/me/Documents/r.csv",
	}
	ui.probe_frame(&h.p)
	busy(t, &h, &c, false, "saved")

	// A failure the window never saw begin ends it as well.
	send(t, &h)
	pick(t, &h, "/home/me/r.csv")
	busy(t, &h, &c, true, "sent again")
	c.prog.notice = {
		id     = 9,
		failed = true,
		text   = "Could not save the report: could not write the report",
	}
	ui.probe_frame(&h.p)
	busy(t, &h, &c, false, "failed")
}
