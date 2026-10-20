package leita_view

import "core:strings"
import "core:time"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../command"
import "../files"
import "../msg"
import "../query"

/*
Exporting a report of the finished scan. Export in the settings menu opens a dialog
that asks for the format and whether to include what Reclaim finds; its
Export opens the platform's save dialog in the reports folder, the user's
Documents, with a name for the target and the minute, filtered to the format.
The path chosen goes to the host, which writes the file and says where in a
notice whose Locate shows it in the file manager. A cancel ends the export with
nothing said. Where no save dialog can open, the host saves in the reports
folder under a name of its own, so nothing is replaced.
*/

// export_item is the settings menu's Export, there whenever there is a scan
// and live once it is done, since a report is of a finished scan. While a
// report is written it reads Exporting… with a spinner for its icon, and is
// heard as loading; choosing it then does nothing, so one export runs at a
// time. Returns true on the frame it is chosen.
@(private)
export_item :: proc(menu: ^primer.Action_Menu, m: ^Model, prog: ^query.Progress_Result) -> bool {
	if prog == nil || prog.generation == 0 {
		return false
	}
	busy := exporting(m, prog)
	return primer.action_menu_item(
		menu,
		tr(.Exporting) if busy else tr(.Export),
		leading = .Download,
		disabled = prog.state != .Done,
		loading = busy,
	)
}

// export_show opens the export dialog. A CSV or JSON of this scan is free, so
// the dialog opens with no licence; a locked window starts on CSV rather than
// on a PDF or HTML report it will refuse.
@(private)
export_show :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if !unlocked(gtx, m) && !basic_export(m.export_format) {
		m.export_format = .Csv
	}
	m.export_open = true
}

// basic_export is a CSV or JSON of this scan, which does not need Pro.
@(private)
basic_export :: proc(format: command.Export_Format) -> bool {
	return format == .Csv || format == .Json
}

// exporting is whether a report asked for is still being written: while the
// save dialog asks where, from the frame Export is sent until the host says it
// is writing it, then for as long as it says so. Every export ends in a notice,
// which also ends the wait, should it be over before the window heard it begin.
@(private)
exporting :: proc(m: ^Model, prog: ^query.Progress_Result) -> bool {
	if sent, waiting := m.export_sent.?; waiting && (prog.exporting || prog.notice.id != sent) {
		m.export_sent = nil
	}
	return prog.exporting || m.export_sent != nil || m.export_picking
}

// export_dialog asks how to write the report, then where, and sends Export once
// the save dialog answers with a path, or could not open.
@(private)
export_dialog :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	for e in ui.events(gtx, EXPORT_PICK) {
		#partial switch e.kind {
		case .Picked:
			// A path too long for the command would be cut short and name
			// another file: the host names one in the reports folder instead.
			m.export_picking = false
			if e.text != "" && prog != nil {
				send_export(gtx, m, prog, e.text if len(e.text) <= command.MAX_PATH else "")
			}
		case .Pick_Failed:
			// No dialog to ask with: the host names a new file in the
			// reports folder instead.
			m.export_picking = false
			if prog != nil {
				send_export(gtx, m, prog, "")
			}
		}
	}
	if !m.export_open || prog == nil {
		return
	}
	cancel, export := false, false
	buttons := [2]primer.Dialog_Button {
		{content = tr(.Cancel), clicked = &cancel},
		{content = tr(.Export), type = .Primary, clicked = &export},
	}
	if primer.dialog(
		gtx,
		&m.export_open,
		tr(.Export_Report),
		safe(gtx, prog.target),
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
		if primer.form_control(gtx, tr(.Format), caption = tr(FORMAT_CAPTIONS[m.export_format])) {
			if primer.segmented_control(gtx, formats[:], &at, name = tr(.Format)) {
				m.export_format = order[at]
			}
		}
		primer.checkbox(
			gtx,
			&m.export_reclaim,
			tr(.Include_Reclaim),
			caption = tr(.Include_Reclaim_Caption),
		)
		primer.text(gtx, tr(.Export_Next), .Small, color = primer.color(.Fg_Color_Muted))
	}
	if cancel {
		m.export_open = false
	}
	if export {
		// PDF and HTML are Pro. Refusing here, before the save dialog, is what
		// the person sees; the host refuses the same command if it arrives anyway.
		if !unlocked(gtx, m) && !basic_export(m.export_format) {
			m.export_open = false
			licence_show(m, msg.Msg.Reports_Locked)
			return
		}
		m.export_open = false
		m.export_picking = true
		name := strings.concatenate(
			{files.report_stem(prog.target, time.now()), command.EXTENSIONS[m.export_format]},
			context.temp_allocator,
		)
		filter := [1]ui.Pick_Filter{format_filter(m.export_format)}
		ui.pick_save(gtx, EXPORT_PICK, name, prog.reports, filter[:])
	}
}

// send_export sends the Export the dialog was set to, to path, or to a new file
// in the reports folder when path is empty.
@(private)
send_export :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result, path: string) {
	m.export_sent = prog.notice.id
	ui.command(
		gtx,
		command.Command(
			command.Export {
				generation = m.generation,
				format = m.export_format,
				reclaim = m.export_reclaim,
				path = command.text_make(path),
			},
		),
	)
}

// EXPORT_PICK is the area the save dialog answers: no widget's, so a constant
// rather than a claimed id.
@(private)
EXPORT_PICK :: ops.Area_Id(0x6c65_6974_6170_696b) // "leitapik"

// format_filter is what the save dialog offers for format: its name in the
// language in use, and its extensions.
@(private)
format_filter :: proc(format: command.Export_Format) -> ui.Pick_Filter {
	return {tr(FORMAT_NAMES[format]), FORMAT_EXTENSIONS[format]}
}

// FORMAT_NAMES name each format in the save dialog, and FORMAT_EXTENSIONS are
// the extensions it filters to.
@(private)
FORMAT_NAMES := [command.Export_Format]msg.Msg {
	.Pdf  = .Format_Pdf,
	.Html = .Format_Html,
	.Csv  = .Format_Csv,
	.Json = .Format_Json,
}

@(private)
FORMAT_EXTENSIONS := [command.Export_Format]string {
	.Pdf  = "pdf",
	.Html = "html;htm",
	.Csv  = "csv",
	.Json = "json",
}

// FORMAT_CAPTIONS say what each format is for.
@(private)
FORMAT_CAPTIONS := [command.Export_Format]msg.Msg {
	.Pdf  = .Caption_Pdf,
	.Html = .Caption_Html,
	.Csv  = .Caption_Csv,
	.Json = .Caption_Json,
}
