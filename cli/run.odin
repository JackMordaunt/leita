/*
leita's command line: what the leita binary is, and what Leita, the window,
runs as when given a flag. run takes the arguments after the program's name
and returns the exit code; each binary's main hands it os.args[1:].
*/
package leita_cli

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"
import "core:time"

import "../history"
import "../home"
import "../human"
import "../journal"
import "../licence"
import "../monitor"
import "../ntfs"
import "../report"
import "../scan"
import "../survey"
import "../term"
import "../version"
import "../walk"

// Largest N files/folders to print.
TOP_N :: 20

/*
USAGE is what -h prints: plain, byte for byte, in a pipe or to an agent; for a
person at a terminal, with the weight term.usage gives its shape. It names
every flag Options has, and a test holds it to that.
*/
USAGE :: `leita (or le) — find out what is using the disk.

Scan
  leita [TARGET]            the largest files and directories of a drive, device,
                            image or directory; your home directory unless named
  leita monitor ...         scheduled scans of the places you watch; leita monitor -h
  leita journal ...         Linux: record which folders change, so a scan reads only
                            those; off until leita journal on; leita journal -h
  leita licence ...         the licence: leita licence add LICENCE keeps one, leita
                            licence remove forgets it, LEITA_LICENCE holds one for a
                            single run; leita licence -h
  leita update [--check]    look for a newer leita, and install it when asked; it
                            never checks on its own; leita update -h
  leita history ...         what leita deleted or changed at your request, newest
                            first; leita history [PLACE] [--since DATE] [--json]
  --live                    draw the answer as it is found rather than once at the end
  --no-history              neither compare with earlier scans of this place nor keep
                            this one
  --whole                   read the place whole, not only what changed since it was
                            last read
Report
  --report FILE             write the scan up as FILE, .csv, .json, .html or .pdf;
                            - writes it to standard output instead of the summary
  --format FORMAT           the report's format, csv, json, html or pdf, whatever its
                            file is called
  --paper a4|letter         the paper a PDF report is laid out on; the locale's unless set
  --top N                   largest directories and files a report lists, 50 unless set
  --reclaim                 include in the report what can be deleted and made again
Alert
  --warn-used N             exit code 2 once the volume is at least N percent used, e.g. 80
  --fail-used N             exit code 3 once the volume is at least N percent used, e.g. 95
  --min-free SIZE           exit code 3 once the volume has less free than SIZE, e.g. 20GB
                            sizes are decimal: 1 GB = 1,000,000,000 bytes; GiB is accepted
                            on input
Read
  --gentle                  leave the disk and cores to other work by reading with
                            fewer threads
  --buffered                read the volume through the system cache rather than around it
  --workers N               MFT readers to run at once
  --walk-workers N          directory readers to run at once
  --chunk BYTES             bytes per volume read
  --no-skip                 read runs of dead MFT records rather than jumping over them
  --min-skip BYTES          shortest run of dead records worth jumping over
Also
  --color auto|always|never decorate the summary; auto does for a person at a terminal,
                            never in a pipe (LEITA_COLOR sets it too)
  --version                 print which leita this is and stop
  Leita, the window, takes the same arguments; with any flag it runs as leita;
  alone or with a path it opens the window

Exit codes: 0 no limit crossed; 1 a bad flag, or a target that could not be scanned;
2 a --warn-used limit crossed; 3 a --fail-used or --min-free limit crossed.
Each scan is kept beside the window's, so the next says what changed.
`

// PROGRAM is the command's name in its messages: the product's.
PROGRAM :: version.NAME

/*
What the command line can set, each said in USAGE, which a test keeps in step.

Read in UNIX style, so `--flag`, `--flag=value` and `--flag value` all work, and `-h`
prints USAGE. A count left at zero means the reader chooses its own, rather than
having a second set of defaults to keep in step here.
*/
Options :: struct {
	target:       string `args:"pos=0"`,
	live:         bool,
	buffered:     bool,
	no_skip:      bool,
	min_skip:     int,
	workers:      int,
	walk_workers: int,
	gentle:       bool,
	chunk:        int,
	report:       string,
	format:       string,
	paper:        string,
	top:          int,
	reclaim:      bool,
	no_history:   bool,
	whole:        bool,
	warn_used:    int,
	fail_used:    int,
	min_free:     string,
	color:        string,
	version:      bool,
}

/*
Exit codes a script reads instead of this command's words, so a monitoring
tool can run leita against a drive and act on the result without parsing any
of them: see "Scripts and monitoring" in README.md. A code already in use
keeps its meaning; EXIT_WARN and EXIT_FAIL are new and only returned when
--warn-used, --fail-used or --min-free was asked for.
*/
EXIT_OK    :: 0
EXIT_ERROR :: 1 // a bad flag, a target that could not be scanned, or the like
EXIT_WARN  :: 2 // the scan finished; a --warn-used limit was crossed
EXIT_FAIL  :: 3 // the scan finished; a --fail-used or --min-free limit was crossed

// run is the command line: args is everything after the program's name, and
// what it returns is the exit code.
run :: proc(args: []string) -> int {
	defer free_all(context.temp_allocator)

	// leita monitor ... is monitoring's own command line (package monitor), and
	// leita journal ... the change recorder's (package journal).
	if is_subcommand(args) {
		switch args[0] {
		case "monitor":
			return monitor.run_command_line(args[1:])
		case "journal":
			return journal.run_command_line(args[1:])
		case "licence":
			return licence_command_line(args[1:])
		case "history":
			return history_command_line(args[1:])
		case "update":
			return update_command_line(args[1:])
		}
	}

	// Plain unless a person is watching, decided before the flags are read,
	// so a bad flag and -h are already said their way: --color is found by
	// hand, since core:flags returns Help_Request as it meets -h, wherever it
	// stands (core/flags/parsing.odin), so --color=always -h would never be
	// read.
	mode, _ := term.parse_mode(os.get_env("LEITA_COLOR", context.temp_allocator))
	if word, given := find_color(args); given {
		ok: bool
		if mode, ok = term.parse_mode(word); !ok {
			set_style(.Auto)
			say_error("--color takes auto, always or never, not %q", word)
			return EXIT_ERROR
		}
	}
	set_style(mode)

	opt: Options
	if err := flags.parse(&opt, args, .Unix); err != nil {
		if _, asked_for_help := err.(flags.Help_Request); asked_for_help {
			print_usage()
			return EXIT_OK
		}
		say_flag_error(err)
		return EXIT_ERROR
	}
	if opt.version {
		fmt.println(version_line())
		return 0
	}

	// Each finished scan is kept where the window keeps its own, to compare the
	// next with, and the licence beside it, whether or not this run keeps its scan;
	// LEITA_LICENCE holds one for this run in its place.
	data := history.default_path(context.temp_allocator)
	given := os.get_env(licence.ENV, context.temp_allocator)
	licensee, unlocked, problem := monitor.licence_beside(data, given, time.now())
	if problem != "" {
		say_note("%s", problem)
	}
	return scan_and_say(opt, data, licensee, !unlocked)
}

// is_subcommand says whether args open with a command of its own, monitor,
// journal, licence, history or update, whose command line is the rest; Leita,
// the window, asks before it takes one argument as a path.
is_subcommand :: proc(args: []string) -> bool {
	if len(args) == 0 {
		return false
	}
	switch args[0] {
	case "monitor", "journal", "licence", "history", "update":
		return true
	}
	return false
}

// find_color finds --color among args the way the parser would, as --color=WORD
// or --color WORD, and says whether it was given.
find_color :: proc(args: []string) -> (word: string, given: bool) {
	for a, i in args {
		switch {
		case strings.has_prefix(a, "--color="):
			word, given = a[len("--color="):], true
		case a == "--color" && i + 1 < len(args):
			word, given = args[i + 1], true
		}
	}
	return
}

// set_style decides what each stream may carry; see say.odin.
set_style :: proc(mode: term.Mode) {
	style = term.detect(terminal.is_terminal(os.stdout), mode)
	estyle = term.detect(terminal.is_terminal(os.stderr), mode)
}

// print_usage writes USAGE on standard output, styled for a person.
print_usage :: proc() {
	b := strings.builder_make(context.temp_allocator)
	term.write_usage(&b, style, PROGRAM, USAGE)
	fmt.print(strings.to_string(b))
}

/*
say_flag_error says what was wrong with the command line in words, and where
the flags are listed, rather than the "[flags.Parse_Error.Reason] message" line
flags.print_errors writes (core/flags/util.odin). A help request is not an
error and is answered before this.
*/
say_flag_error :: proc(err: flags.Error) {
	switch e in err {
	case flags.Parse_Error:
		say_error("%s", e.message)
	case flags.Validation_Error:
		say_error("%s", e.message)
	case flags.Open_File_Error:
		say_error("cannot open %s: %v", e.filename, e.errno)
	case flags.Help_Request:
		return
	}
	fmt.eprintfln("%s -h lists what it takes", PROGRAM)
}

/*
scan_and_say scans what opt names and says what it found: a summary on the
terminal, a report as well or instead when one is asked for. kept is the history
store the scan is compared with and kept in, "" for none; --no-history makes it
none whatever it is. licensee is whose licence leita runs under, "" for none,
and locked says the trial is over without one, so no report is written.
*/
scan_and_say :: proc(opt: Options, kept := "", licensee := "", locked := false) -> int {
	// Checked before anything is read, so a mistake costs nothing.
	format, format_err := report_format(opt)
	if format_err != "" {
		say_error("%s", format_err)
		return 1
	}
	if opt.report != "" && locked {
		say_error(
			"reports need a licence now the 30-day trial has ended; add one with leita licence add, or in Leita, the window, under Licence in its settings",
		)
		return 1
	}
	if opt.report != "" && opt.live {
		say_error("a report is written from a finished scan, not a live one")
		return 1
	}
	paper := report.paper_of_locale()
	if opt.paper != "" {
		ok: bool
		if paper, ok = report.paper_named(opt.paper); !ok {
			say_error("no paper %q: use a4 or letter", opt.paper)
			return 1
		}
		if format != .Pdf || opt.report == "" {
			say_error("--paper lays out a PDF report; name one with --report")
			return 1
		}
	}
	if opt.warn_used < 0 || opt.warn_used > 100 {
		say_error("--warn-used is a percent, 0 to 100, not %d", opt.warn_used)
		return EXIT_ERROR
	}
	if opt.fail_used < 0 || opt.fail_used > 100 {
		say_error("--fail-used is a percent, 0 to 100, not %d", opt.fail_used)
		return EXIT_ERROR
	}
	min_free: u64
	if opt.min_free != "" {
		ok: bool
		if min_free, ok = human.parse_bytes(opt.min_free); !ok {
			say_error("cannot read --min-free %q: a size such as 20GB or 20GiB", opt.min_free)
			return EXIT_ERROR
		}
	}
	// A report on standard output is the whole of it; the summary would corrupt it.
	quiet := opt.report == "-"

	target_str := opt.target
	if target_str == "" {
		who := home.user(context.temp_allocator)
		target_str = who.dir if who.dir != "" else "/"
	}
	opts := ntfs.Read_Options {
		chunk_size = opt.chunk,
		io_mode    = .Buffered if opt.buffered else .Unbuffered,
		// Negative reads every record; zero leaves the reader its own default.
		min_skip   = -1 if opt.no_skip else opt.min_skip,
		workers    = opt.workers,
	}

	target, engine, resolve_err := scan.resolve(target_str)
	if resolve_err != nil {
		say_error("cannot scan %s: %v", target_str, resolve_err)
		return 1
	}
	defer scan.target_destroy(&target)
	wcfg := walk.Config {
		workers = opt.walk_workers,
		media   = target.media,
		pace    = .Gentle if opt.gentle else .Full,
	}

	if !quiet {
		fmt.println(head_line(target, engine.engine, opts.io_mode))
		if engine.engine == .Walk {
			fmt.printfln("%s %d readers at %v pace", dim("walk:"), walk.width(wcfg), wcfg.pace)
		}
	}

	if engine.permission_would_help {
		when ODIN_OS == .Windows {
			say_note("this volume reads far faster from an administrator prompt")
		} else {
			say_note(
				"this volume reads far faster with permission to open %s directly",
				target.volume,
			)
		}
	}

	if engine.engine == .None {
		say_error("nothing here can be scanned")
		return 1
	}

	t: scan.Tree
	if err := scan.tree_init(&t, walk.width(wcfg)); err != nil {
		say_error("%v", err)
		return 1
	}
	defer scan.tree_destroy(&t)

	// The table outlives the tree, whose names are borrowed from it. With history on,
	// the place's whole tree is kept beside it, shared with the window and the monitor,
	// and the next scan reads only what changed since.
	kept := "" if opt.no_history else kept
	f := survey.Fill {
		target = target,
		engine = engine.engine,
		opts   = opts,
		wcfg   = wcfg,
		tree   = &t,
		whole  = opt.whole,
	}
	defer survey.fill_destroy(&f)
	// In the heap, not the temp allocator: a live scan's draw loop frees that every
	// frame while its reader still reads and writes the baseline.
	if kept != "" {
		f.baseline = history.baseline_path(kept, scan.location(target, context.temp_allocator))
	}
	defer delete(f.baseline)

	if opt.live {
		return run_live(&f)
	}

	started := time.now()
	start := time.tick_now()
	survey.fill_run(&f)
	if fill_report(&f) {
		return 1
	}
	elapsed := time.tick_since(start)

	if !quiet {
		if engine.engine == .Mft {
			print_native(&f.table, elapsed)
		}
		fmt.println()
		label(
			"tree",
			"%d slots, %d used, read in %.0f ms",
			t.count,
			t.nodes_done,
			time.duration_milliseconds(elapsed),
		)
		say_how_read(&f)
		print_accounting(&t)
	}
	say_unread(&t)
	if !quiet && scan.has_snapshot_volume(&t) {
		say_retention(&t)
	}

	// The same charging the live scan does, run once over a tree nobody is still
	// filling. A node left uncharged here has an ancestor that never resolved, and
	// another pass would not change that. Reclaim walks directories' children,
	// which only a linked rollup lists, as is keeping a scan.
	roll := survey.Rollup {
		linked = opt.reclaim || kept != "",
	}
	defer survey.rollup_destroy(&roll)
	survey.rollup_advance(&roll, &t)

	if !quiet {
		print_largest(&t, &roll, .files)
		print_largest(&t, &roll, .directories)
	}
	space := report.space_of(&f)
	disk: history.Disk
	if sp, ok := space.?; ok {
		disk = {sp.total, sp.free}
	}
	k := keep_scan(kept, &t, &roll, engine.engine, disk)
	say_kept(k, survey.total(&roll, t.root) if t.root < roll.seen else 0, quiet)

	thresholds_set := opt.warn_used > 0 || opt.fail_used > 0 || min_free > 0
	th, _, known := report.threshold_of(
		space,
		opt.warn_used,
		opt.fail_used,
		min_free,
		context.temp_allocator,
	)
	if thresholds_set && !known {
		say_error("cannot check thresholds: this target's free space is unknown")
		return EXIT_ERROR
	}
	if thresholds_set {
		say_threshold(th)
	}

	if opt.report == "" {
		return exit_code(th.verdict)
	}

	facts := report.Facts {
		target   = target,
		engine   = engine.engine,
		started  = started,
		duration = elapsed,
		space    = space,
	}
	r := report.build(
		&t,
		&roll,
		facts,
		{
			top = opt.top,
			reclaim = opt.reclaim,
			previous = k.previous,
			licensee = licensee,
			warn_used = opt.warn_used,
			fail_used = opt.fail_used,
			min_free = min_free,
		},
	)
	defer report.destroy(&r)
	if code := write_report(&r, opt.report, format, paper); code != 0 {
		return code
	}
	return exit_code(th.verdict)
}

// APFS snapshot names are volume facts. Their presence cannot be converted to
// bytes held by a particular file, and purgeable space has no measured number.
say_retention :: proc(t: ^scan.Tree) {
	r := scan.retention_of(t)
	names := scan.snapshot_names_of(t)
	switch r.snapshots {
	case .None:
		label("snapshots", "none on this APFS volume")
	case .Present:
		label("snapshots", "%d on this APFS volume", len(names))
	case .Unchecked:
		label("snapshots", "list incomplete or unavailable")
	}
	for name in names {
		label("snapshot", "%s", human.shown(name))
	}
	if r.purgeable_known {
		label("purgeable", "%s", human.bytes(r.purgeable))
	} else {
		label("purgeable", "unknown")
	}
}

// say_how_read says whether a scan with a baseline read its place whole or only
// what changed; a scan without one reads whole and says nothing of it.
say_how_read :: proc(f: ^survey.Fill) {
	if f.baseline == "" {
		return
	}
	label("read", "%s", survey.how_read(f.how == .Updated, f.why, f.reread, f.taken, f.by))
}

// exit_code is what a verdict reads back as, for a script to test.
exit_code :: proc(v: report.Verdict) -> int {
	#partial switch v {
	case .Warn:
		return EXIT_WARN
	case .Fail:
		return EXIT_FAIL
	}
	return EXIT_OK
}

// say_threshold writes th's verdict to standard error as a single line, one of
// the limits crossed per line below it, never to standard output: a report on
// "-" writes JSON there, and a plain scan's summary should not grow a line that
// is silent unless asked for. Ok says nothing, since the exit code already does.
say_threshold :: proc(th: report.Threshold) {
	if th.verdict == .Ok {
		return
	}
	fmt.eprintfln(
		"%s %s",
		term.painted(estyle, {.Bold}, fmt.tprintf("%s:", report.VERDICT_KEYS[th.verdict])),
		human.shown(strings.join(th.reasons, "; ", context.temp_allocator)),
	)
}

/*
The format a report is written in: what --format names, else what the report's
file is called. A message saying what is wrong otherwise, or for no report at
all, nothing.
*/
report_format :: proc(opt: Options) -> (report.Format, string) {
	if opt.format != "" {
		f, ok := report.format_named(opt.format)
		if !ok {
			return {}, fmt.tprintf("no report format %q: use csv, json, html or pdf", opt.format)
		}
		if opt.report == "" {
			return {}, "--format says how to write a report; name one with --report"
		}
		return f, ""
	}
	if opt.report == "" {
		if opt.top != 0 || opt.reclaim {
			return {}, "--top and --reclaim shape a report; name one with --report"
		}
		return {}, ""
	}
	if opt.report == "-" {
		return {}, "a report on standard output needs --format csv, json, html or pdf"
	}
	f, ok := report.format_of(opt.report)
	if !ok {
		return {}, fmt.tprintf("cannot tell the format of %s from its name: end it .csv, .json, .html or .pdf, or give --format", opt.report)
	}
	return f, ""
}

// Write the report to path, or standard output for "-". A report that could
// not be written whole is not left behind half written.
write_report :: proc(
	r: ^report.Report,
	path: string,
	format: report.Format,
	paper: report.Paper,
) -> int {
	if path == "-" {
		if err := report.export(os.to_writer(os.stdout), r, format, paper); err != nil {
			say_error("%s", report.ERROR_TEXT[err])
			return 1
		}
		return 0
	}
	file, open_err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil {
		say_error("cannot write %s: %v", path, open_err)
		return 1
	}
	w := os.to_writer(file)
	err := report.export(w, r, format, paper)
	if close_err := os.close(file); close_err != nil && err == nil {
		err = .Write_Failed
	}
	if err != nil {
		os.remove(path)
		say_error("%s: %s", report.ERROR_TEXT[err], path)
		return 1
	}
	fmt.println()
	label("report", "%s, %s", path, report.FORMAT_NAMES[format])
	return 0
}

// Say what went wrong, if anything did.
fill_report :: proc(f: ^survey.Fill) -> bool {
	if msg := survey.problem(f); msg != "" {
		say_error("%s", msg)
		return true
	}
	return false
}

Kind :: enum {
	files,
	directories,
}

// Whether a node lies under the scan root. Unknown until a climb decides;
// Outside only once a climb has ended on a different root.
@(private = "file")
Under_State :: enum u8 {
	Unknown,
	Inside,
	Outside,
}

// One ranking pass's memory of that. The chain grows with the tree: a fixed
// cap both dropped a file past it and remembered those ancestors as outside,
// so every sibling under them was dropped too. rank holds one for the pass,
// and the summary prints that same ranking.
@(private = "file")
Under :: struct {
	t:     ^scan.Tree,
	roll:  ^survey.Rollup,
	known: []Under_State,
	chain: [dynamic]u32,
}

@(private = "file")
under_open :: proc(t: ^scan.Tree, roll: ^survey.Rollup) -> Under {
	// Not the temp allocator: a live scan ranks every pass, as fast as it
	// can, with nothing in that loop ever resetting it.
	return {
		t = t,
		roll = roll,
		known = make([]Under_State, roll.seen),
		chain = make([dynamic]u32, 0, 16),
	}
}

@(private = "file")
under_close :: proc(u: ^Under) {
	delete(u.known)
	delete(u.chain)
}

// True when i is the scan root or lies under it. The MFT reader loads the
// whole volume even when asked for a subtree, rooting the tree below the
// volume's own root rather than at it, so without this a subtree's ranking
// would include whatever the rest of the volume holds, root among them.
// A climb that stops short — a parent the rollup has not seen, or a cycle —
// remembers nothing: those nodes stay unknown, and a later sibling is
// classified from its own walk.
@(private = "file")
under_root :: proc(u: ^Under, i: u32) -> bool {
	clear(&u.chain)
	cur := i
	state := Under_State.Unknown
	root := u.t.root
	for {
		if cur == root {
			state = .Inside
			break
		}
		if u.known[cur] != .Unknown {
			state = u.known[cur]
			break
		}
		parent := scan.node(u.t, cur).parent
		// Ended on a root, and it is not the scan's: the chain is outside.
		if parent == cur {
			state = .Outside
			append(&u.chain, cur)
			break
		}
		if parent >= u.roll.seen || len(u.chain) >= int(u.roll.seen) {
			return false
		}
		append(&u.chain, cur)
		cur = parent
	}
	for j := len(u.chain) - 1; j >= 0; j -= 1 {
		u.known[u.chain[j]] = state
	}
	return state == .Inside
}

// The largest files or directories under the scan root, largest first, and how
// many were kept. Directories when kind is left out: the live scan ranks those
// every pass, and the summary prints both through here.
rank :: proc(t: ^scan.Tree, roll: ^survey.Rollup, top: []Sized, kind := Kind.directories) -> int {
	count := 0
	u := under_open(t, roll)
	defer under_close(&u)
	// Bounded by what the rollup has seen rather than the tree: a reader may hand out
	// more slots while this runs, and those have not been charged yet.
	for i in 0 ..< roll.seen {
		n := scan.node(t, i)
		flags := scan.node_flags(n)
		if .Used not_in flags {
			continue
		}
		bytes: u64
		switch kind {
		case .files:
			if .Directory in flags || .Extra_Name in flags {
				continue
			}
			bytes = n.disk
		case .directories:
			if .Directory not_in flags || i == t.root {
				continue
			}
			bytes = survey.total(roll, i)
		}
		// Climb before dropping an empty one, so a later sibling of it still
		// finds the ancestors already classified.
		if !under_root(&u, i) || bytes == 0 {
			continue
		}
		top_n(top, &count, Sized{bytes = bytes, record = i})
	}
	return count
}

// print_accounting says what the scan knows about snapshots and delayed purge.
// It does not turn a charged size into a frees figure. "none" is not proof.
print_accounting :: proc(t: ^scan.Tree) {
	ret := scan.retention_of(t)
	switch ret.snapshots {
	case .Present:
		fmt.println("  A snapshot may still hold deleted data. A charged size is not what deletion frees.")
	case .None:
		fmt.println("  No snapshot was found. A charged size is still not what deletion frees.")
	case .Unchecked:
		fmt.println("  Whether a snapshot retains deleted data was not checked. A charged size is not what deletion frees.")
	}
	if scan.is_scan_order(t) || scan.is_logical(t) {
		fmt.println("  These charged sizes are estimates, not what deletion frees.")
	}
	if ret.purgeable_known {
		fmt.printfln("  The volume may still purge %s later.", human.bytes(ret.purgeable))
	}
}

print_largest :: proc(t: ^scan.Tree, roll: ^survey.Rollup, kind: Kind) {
	top: [TOP_N]Sized
	count := rank(t, roll, top[:], kind)
	say_heading(fmt.tprintf("largest %v", kind), count)
	// Every path starts with the scanned place; dim, it lets the tail that
	// differs stand out. The place itself, among the directories, stays whole.
	root := scan.path(t, t.root, context.temp_allocator)
	for s in top[:count] {
		// Each row's path is let go with the row.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		path := scan.path(t, s.record, context.temp_allocator)
		if len(path) > len(root) && strings.has_prefix(path, root) {
			path = strings.concatenate(
				{dim(root), human.shown(path[len(root):])},
				context.temp_allocator,
			)
		} else {
			path = human.shown(path)
		}
		extra := ""
		// A directory row is a charged rollup. freed_of is one node, so it is
		// not what deleting the folder frees. Files are ranked by their charge.
		if kind != .directories {
			line := scan.delete_line(t, s.record, s.bytes)
			if line.has_frees {
				extra = fmt.tprintf("  deleting frees %s", human.bytes(line.frees))
			} else if line.unknown {
				extra = "  deleting frees an unknown amount"
			}
		}
		fmt.printfln("  %10s  %s%s", human.bytes(s.bytes), path, extra)
	}
}

// What only the NTFS reader knows, kept because the tree cannot carry it.
print_native :: proc(m: ^ntfs.Mft, elapsed: time.Duration) {

	files: u64
	allocated: u64
	for e in m.entries {
		if .In_Use not_in e.flags {
			continue
		}
		allocated += e.allocated
		if .Directory not_in e.flags {
			files += 1
		}
	}
	volume_bytes := m.boot.total_sectors * u64(m.boot.bytes_per_sector)
	fmt.println()
	label(
		"volume",
		"%s, %d B clusters, %d B records",
		human.bytes(volume_bytes),
		m.boot.bytes_per_cluster,
		m.boot.record_size,
	)
	label(
		"mft",
		"%d slots, %d records, %d unreadable, read in %.0f ms",
		m.stats.records,
		m.stats.records_read,
		m.stats.records_bad,
		time.duration_milliseconds(elapsed),
	)
	label(
		"in use",
		"%d files, %d directories, %d extra hard links",
		files,
		m.stats.directories,
		len(m.links),
	)
	label("attributed", "%s summed from every file run list", human.bytes(allocated))

	/*
	$Bitmap counts allocated clusters without consulting a single file, so comparing it
	against the sum above checks the run list decoding. The two should agree closely;
	a wide gap means clusters are allocated that no file claims, which is a parsing bug
	rather than missing disk space.
	*/
	on_disk := m.stats.allocated_clusters * u64(m.boot.bytes_per_cluster)
	if on_disk > 0 {
		label("on disk", "%s marked allocated in $Bitmap", human.bytes(on_disk))
		if on_disk >= allocated {
			gap := on_disk - allocated
			label(
				"unclaimed",
				"%s (%.2f%%) allocated but charged to no file",
				human.bytes(gap),
				100 * f64(gap) / f64(on_disk),
			)
		} else {
			label(
				"overcount",
				"%s more attributed than $Bitmap reports allocated",
				human.bytes(allocated - on_disk),
			)
		}
	}
	if m.stats.resident_files > 0 {
		label(
			"resident",
			"%d files hold %s inside their MFT records, charged to $MFT",
			m.stats.resident_files,
			human.bytes(m.stats.resident_bytes),
		)
	}
}

Sized :: struct {
	bytes:  u64,
	record: u32,
}

// Keep the N largest candidates in descending order without sorting the whole table.
// Most candidates fail the first comparison, so the scan stays linear.
@(private = "file")
top_n :: proc(top: []Sized, count: ^int, cand: Sized) {
	if count^ == len(top) && cand.bytes <= top[len(top) - 1].bytes {
		return
	}
	i := count^ if count^ < len(top) else len(top) - 1
	for i > 0 && top[i - 1].bytes < cand.bytes {
		top[i] = top[i - 1]
		i -= 1
	}
	top[i] = cand
	if count^ < len(top) {
		count^ += 1
	}
}
