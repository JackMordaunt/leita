package leita_app

import "core:os"
import "core:strings"
import "core:time"

import "../../history"
import "../../licence"
import "../../report"
import "../../synth"
import "../command"
import "../files"

/*
Export: a report of the finished scan, written by report.save as the command
line writes one, to the path the person chose in the window's save dialog. It
runs on the desk thread, which owns the tree, so the window goes on drawing while
it is written; the desk answers again once the file is closed, with a notice
saying where it went or why it could not.

A file already at the chosen path is replaced, once the new report is written
whole, so a save that fails keeps it: the platform's save dialog asks
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
		tell(d, true, .Export_Unfinished)
		return
	}
	// CSV and JSON of this scan are free. PDF and HTML are Pro, and so is
	// attaching an earlier scan: a free export leaves that off.
	grant := licence.Licence{}
	if d.licensed {
		grant = d.licence
	}
	pro := licence.entitled_to_pro(grant, d.first_use, time.now())
	if !pro && !report.basic_export(FORMATS[c.format]) {
		tell(d, true, .Reports_Locked)
		return
	}
	chosen := command.text_of(&c.path)
	folder := d.reports
	if chosen == "" && folder == "" {
		tell(d, true, .Export_No_Folder)
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
		user    = {synth.HOME, ""} if s.engine == .Synthetic else {},
	}
	if d.licensed {
		opt.licensee = d.licence.licensee
	}
	if pro && d.compared.id != 0 && d.history != nil {
		if then, err := history.load(d.history, d.compared.id, context.temp_allocator);
		   err == nil {
			opt.previous = report.Snapshot{time.unix(d.compared.taken, 0), then}
		}
	} else if !pro && d.compared.id != 0 {
		// The scan is kept either way. The file must not say there was none.
		opt.earlier_kept = true
	}
	if _, comparing := opt.previous.?;
	   opt.licensee == "" && report.basic_export(FORMATS[c.format]) && !comparing {
		opt.free_export = true
	}
	r := report.build(&s.tree, &s.roll, facts, opt)
	defer report.destroy(&r)

	format := FORMATS[c.format]
	path: string
	if chosen != "" {
		path = strings.clone(chosen)
	} else {
		// The name is claimed, empty, so no other save takes it; report.save
		// then writes the report beside it and renames it over.
		stem := files.report_stem(r.target, time.now())
		f: ^os.File
		err: files.Error
		path, f, err = files.create_new(folder, stem, command.EXTENSIONS[c.format])
		if err != .None {
			tell(d, true, .Save_Failed_In, folder, say(d, FILE_ERRORS[err]))
			return
		}
		os.close(f)
	}
	defer delete(path)
	// A failed save keeps the file a chosen path held before, and gives back
	// a name it claimed.
	written, open_err := report.save(path, &r, format, report.paper_of_locale())
	if written != .None && chosen == "" {
		os.remove(path)
	}
	if open_err != nil && chosen != "" {
		tell(d, true, .Save_Failed_To, path, say(d, FILE_ERRORS[files.open_error(open_err)]))
		return
	}
	if written != .None {
		tell(d, true, .Save_Failed, say(d, REPORT_ERRORS[written]))
		return
	}
	tell(d, false, .Saved, path)
	d.notice.saved = true
	d.saved[d.notice.id] = strings.clone(path)
}

// reveal shows the file a notice said was saved, if this desk saved it.
reveal :: proc(d: ^Desk, c: command.Reveal) {
	if path, ok := d.saved[c.notice]; ok {
		errand_keep(d.errands, files.locate(path))
	}
}

@(private)
FORMATS := [command.Export_Format]report.Format {
	.Csv  = .Csv,
	.Json = .Json,
	.Html = .Html,
	.Pdf  = .Pdf,
}
