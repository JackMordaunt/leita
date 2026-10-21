package main

import "../../appid"
import "../../cli"
import "../../gui"
import "core:debug/trace"
import "core:os"
import "core:strings"
@(require) import "jm:debug"

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
without_psn drops arguments with the -psn_ prefix so launch does not treat them
as command-line flags. The remaining arguments keep their order in args' storage.
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
	os.exit(run())
}

run :: proc() -> int {
	when ODIN_DEBUG {
		da: debug.Allocator
		debug.init(&da, context.allocator)
		defer debug.destroy(&da)
		defer debug.report(&da)
		context.allocator = debug.allocator(&da)
	}
	context.assertion_failure_proc = trace.assertion_failure_proc
	appid.set()
	defer free_all(context.temp_allocator)
	args := without_psn(os.args[1:])
	if launch(args) == .Terminal {
		attach_console()
		cli.running_as = .Window
		return cli.run(args)
	}
	path := args[0] if len(args) > 0 else (os.user_home_dir(context.temp_allocator) or_else "/")
	gui.run(path)
	return 0
}
