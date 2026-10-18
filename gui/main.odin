/*
Leita: see what is using the disk, as the scan finds it.

	Leita                  scan the home directory in the window
	Leita PATH             scan a directory, drive or image in the window
	Leita -h               leita's command line, help and reports included
	Leita monitor ...      monitoring's command line, as leita monitor
	Leita journal ...      the change recorder's, as leita journal: the window runs
	                       it under pkexec to turn the recorder on or off
	Leita licence ...      the licence's, as leita licence
	Leita update ...       looks for a newer release and installs it, as leita
	                       update does, but replaces the window

Leita takes the same arguments as leita, and launch decides which it is from
them: alone or with one path it opens the window; with any argument that starts
with "-", or with monitor, journal, licence, history or update, it is leita, whose exit code it
exits with. So a flag the window has no use for, --report say, still does what
leita does, and -h is help rather than a folder named -h. A Mac with only the
app can therefore run reports from the terminal: Leita ~ --report usage.pdf.

On Windows a release is built for the GUI subsystem, so that starting the window
opens no console behind it. Its command line prints into the console of the
terminal that started it (attach_console), but a terminal does not wait for a
GUI program, so a script that needs its exit code or its output in order runs
leita.exe, or start /wait.

The window is jm:ui in Primer. Its pieces are gui's packages:

	query    the reads the window may need, and their results   (leaf)
	command  what the window may ask the application to do      (leaf)
	app      the host: the pipeline, the desk and the reader     (io)
	view     the window: shapes in, commands out                 (ui)

This is the window around app.
*/
package main

import "core:debug/trace"
import "core:os"
import "core:strings"

@(require) import "jm:debug"
import "jm:ui/shell"

import "../appid"
import "../cli"
import "../history"
import "app"
@(require) import "leaks"
import "msg"
import "view"

// Launch is what Leita runs as, decided by launch from its arguments.
Launch :: enum {
	Window, // the window, on the home directory or the one path given
	Terminal, // leita's command line, as the leita binary is
}

/*
launch decides what Leita is from the arguments after its name: nothing, or one
argument that does not start with "-", opens the window; anything else is
leita's command line, which says what is wrong with two paths as leita does.
*/
launch :: proc(args: []string) -> Launch {
	switch {
	case len(args) == 0:
		return .Window
	case cli.is_subcommand(args):
		return .Terminal
	case len(args) == 1 && !strings.has_prefix(args[0], "-"):
		return .Window
	}
	return .Terminal
}

/*
without_psn is args without a -psn_<n>_<m> argument, the process serial number
LaunchServices has given an app opened from Finder: older macOS always did, and
an app may still be handed one. It is not the person's: kept, it would be a
flag, and a flag makes Leita the command line, which would refuse it instead of
opening the window. The rest keep their order, in args' own storage.
*/
without_psn :: proc(args: []string) -> []string {
	n := 0
	for a in args {
		if !strings.has_prefix(a, "-psn_") {
			args[n] = a
			n += 1
		}
	}
	return args[:n]
}

main :: proc() {
	when ODIN_DEBUG {
		da: debug.Allocator
		debug.init(&da, context.allocator)
		defer debug.destroy(&da)
		defer debug.report(&da)
		context.allocator = debug.allocator(&da)
	}
	context.assertion_failure_proc = trace.assertion_failure_proc
	appid.set()

	args := without_psn(os.args[1:])
	if launch(args) == .Terminal {
		attach_console()
		// leita update replaces the file this is: the window's, not the command line's.
		cli.running_as = .Window
		code := cli.run(args)
		free_all(context.temp_allocator)
		os.exit(code)
	}

	path := args[0] if len(args) > 0 else (os.user_home_dir(context.temp_allocator) or_else "/")

	h := new(app.Host)
	defer free(h)
	// Each finished scan is kept, to compare the next with.
	kept := history.default_path()
	defer delete(kept)
	app.init(h, path, shell.wake, kept)

	m: view.Model
	view.model_init(&m, path, msg.system_locale())
	defer view.model_destroy(&m)

	faces := view.fonts()
	defer delete(faces)
	scripts := view.fallbacks(faces)
	defer delete(scripts)

	shell.run(
		{
			title = view.window_title(path),
			width = 1280,
			height = 820,
			min_width = 640,
			min_height = 420,
			ui = view.view,
			user = &m,
			fonts = faces,
			fallbacks = scripts,
			clear = {255, 255, 255, 255},
			data = app.data_host(h),
		},
	)
	app.stop(h)
	free_all(context.temp_allocator)
}
