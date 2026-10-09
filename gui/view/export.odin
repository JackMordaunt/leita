package estoile_view

import "jm:ui"
import "jm:ui/design"
import "jm:ui/primer"

import "../command"
import "../query"

/*
Exporting a report of the finished scan. The toolbar's Export opens a dialog
that asks for the format and whether to include what Reclaim finds; its
Export sends that to the host, which writes the file in the user's Documents
folder, under a name of its own so nothing is replaced, and says where in a
notice whose Locate shows it in the file manager.
*/

// export_button is the toolbar's Export, there whenever there is a scan and
// live once it is done, since a report is of a finished scan: shown from the
// start, the toolbar keeps its layout when the scan ends.
@(private)
export_button :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	if prog == nil || prog.generation == 0 {
		return
	}
	state := design.Interaction.Live if prog.state == .Done else .Disabled
	if primer.button(gtx, "Export", leading = .Download, state = state) {
		m.export_open = true
	}
}

// export_dialog asks how to write the report, and sends Export when asked to.
@(private)
export_dialog :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	if !m.export_open || prog == nil {
		return
	}
	cancel, export := false, false
	buttons := [2]primer.Dialog_Button {
		{content = "Cancel", clicked = &cancel},
		{content = "Export", type = .Primary, clicked = &export},
	}
	if primer.dialog(
		gtx,
		&m.export_open,
		"Export report",
		prog.target,
		footer = buttons[:],
		width = .Medium,
	) {
		ui.column(gtx, gap = 16, align = .Start)
		// In Export_Format's order: the selected segment's index is the format.
		formats := [?]primer.Segment {
			{label = "PDF"},
			{label = "HTML"},
			{label = "CSV"},
			{label = "JSON"},
		}
		order := [len(formats)]command.Export_Format{.Pdf, .Html, .Csv, .Json}
		at := 0
		for f, i in order {
			if f == m.export_format {
				at = i
			}
		}
		if primer.form_control(gtx, "Format", caption = FORMAT_CAPTIONS[m.export_format]) {
			if primer.segmented_control(gtx, formats[:], &at, name = "Format") {
				m.export_format = order[at]
			}
		}
		primer.checkbox(
			gtx,
			&m.export_reclaim,
			"Include Reclaim candidates",
			caption = "What can be deleted and made again",
		)
		primer.text(
			gtx,
			"Saved in your Documents folder under a new name; nothing is replaced.",
			.Small,
			color = primer.color(.Fg_Color_Muted),
		)
	}
	if cancel {
		m.export_open = false
	}
	if export {
		m.export_open = false
		ui.command(
			gtx,
			command.Command(
				command.Export {
					generation = m.generation,
					format = m.export_format,
					reclaim = m.export_reclaim,
				},
			),
		)
	}
}

// FORMAT_CAPTIONS say what each format is for.
@(private)
FORMAT_CAPTIONS := [command.Export_Format]string {
	.Pdf  = "Pages to print or attach to a ticket",
	.Html = "One page that opens in any browser",
	.Csv  = "A row per entry, for a spreadsheet",
	.Json = "Every figure, for another program",
}
