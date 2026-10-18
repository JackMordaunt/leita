/*
leita: find out what is using the disk.

Usage:
	leita [drive-or-image] [flags]     -h lists the flags
	leita ~/src --report usage.html    the same, written up as a report too
	leita monitor -h                   scheduled scans of the places watched
	leita journal -h                   Linux: record which folders change, for faster scans

Reads the volume's MFT directly and prints the largest files and directories. Reading
a live volume needs an elevated prompt. The command line itself is package cli,
which Leita, the window, runs too.
*/
package main

import "core:debug/trace"
import "core:os"

@(require) import "jm:debug"

import "appid"
import "cli"

main :: proc() {
	os.exit(run())
}

// run wraps the command line in the debug allocator, whose report is deferred
// and so must run before the process exits.
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
	return cli.run(os.args[1:])
}
