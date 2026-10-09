package estoile_app

import "core:os"
import "core:strings"
import "core:time"

import "../../history"
import "../../report"
import "../../synth"
import "../command"
import "../files"

/*
Export: a report of the finished scan, written by report.export as the command
line writes one, to the path the person chose in the window's save dialog. It
runs on the desk thread, which owns the tree, so the window goes on drawing while
it is written; the desk answers again once the file is closed, with a notice
saying where it went or why it could not.

A file already at the chosen path is replaced: the platform's save dialog asks
the person before it names one (ui.pick_save says which backend asks how). Without a path, as when no dialog could open, the
report goes to a file of its own in the reports folder (files.reports_folder, or
the one init was given), named for the target and the minute, and never replaces
another: a second export in the same minute gets -2 on its name.

A report is compared with the snapshot the window compares the scan with, so
it shows what changed as the window does.
*/

// export writes the report c asks for.
export :: proc(d: ^Desk, c: command.Export) {
	c := c
	s := d.scan
	if s == nil || c.generation != d.generation || !s.grown || s.state != .Done {
		tell(d, true, "Could not export a report: the scan is not finished")
		return
	}
	chosen := command.text_of(&c.path)
	folder := d.reports
	if chosen == "" && folder == "" {
		tell(
			d,
			true,
			"Could not export a report: there is no Documents folder or home to save it in",
		)
		return
	}

	facts := report.Facts {
		target   = s.fill.target,
		engine   = s.engine,
		started  = s.begun,
		duration = time.Duration(s.seconds * f64(time.Second)),
	}
	if s.disk_total > 0 {
		facts.space = report.Space{s.disk_total, s.disk_free}
	}
	opt := report.Options {
		reclaim = c.reclaim,
		home    = synth.HOME if s.engine == .Synthetic else "",
	}
	if d.compared.id != 0 && d.history != nil {
		if then, err := history.load(d.history, d.compared.id, context.temp_allocator);
		   err == nil {
			opt.previous = report.Snapshot{time.unix(d.compared.taken, 0), then}
		}
	}
	r := report.build(&s.tree, &s.roll, facts, opt)
	defer report.destroy(&r)

	format := FORMATS[c.format]
	path: string
	f: ^os.File
	err: files.Error
	if chosen != "" {
		path = strings.clone(chosen)
		if f, err = files.create_at(path); err != .None {
			tell(d, true, "Could not save the report to %s: %s", path, files.describe(err))
			delete(path)
			return
		}
	} else {
		stem := files.report_stem(r.target, time.now())
		path, f, err = files.create_new(folder, stem, command.EXTENSIONS[c.format])
		if err != .None {
			tell(d, true, "Could not save the report in %s: %s", folder, files.describe(err))
			return
		}
	}
	defer delete(path)
	written := report.export(os.to_writer(f), &r, format, report.paper_of_locale())
	if close_err := os.close(f); close_err != nil && written == .None {
		written = .Write_Failed
	}
	if written != .None {
		os.remove(path)
		tell(d, true, "Could not save the report: %s", report.ERROR_TEXT[written])
		return
	}
	tell(d, false, "Saved report to %s", path)
	d.notice.saved = true
	d.saved[d.notice.id] = strings.clone(path)
}

// reveal shows the file a notice said was saved, if this desk saved it.
reveal :: proc(d: ^Desk, c: command.Reveal) {
	if path, ok := d.saved[c.notice]; ok {
		files.locate(path)
	}
}

@(private)
FORMATS := [command.Export_Format]report.Format {
	.Csv  = .Csv,
	.Json = .Json,
	.Html = .Html,
	.Pdf  = .Pdf,
}
