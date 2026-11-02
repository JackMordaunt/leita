#+build !linux
package leita_cli

import "core:fmt"
import "core:io"

import "../term"

// JOURNAL_OWN is what leita journal says where the system records changes itself.
when ODIN_OS == .Darwin || ODIN_OS == .Windows {
	JOURNAL_OWN :: "this system records which folders change itself; leita reads that, and needs no recorder"
} else {
	JOURNAL_OWN :: "native change history and the change recorder are unavailable on this platform; leita reads the whole tree on every scan"
}

// journal_dispatch says, for every command, that there is nothing to do here.
@(private)
journal_dispatch :: proc(style: term.Style, args: []string, w: io.Writer) -> int {
	verb := args[0] if len(args) > 0 else "status"
	switch verb {
	case "help", "-h", "--help":
		journal_print_usage(style, w)
		return EXIT_OK
	case "status", "off", "on", "run":
		fmt.wprintln(w, JOURNAL_OWN)
		when ODIN_OS != .Darwin && ODIN_OS != .Windows {
			if verb == "on" || verb == "run" {return EXIT_ERROR}
		}
		return EXIT_OK
	}
	journal_errorf(style, w, "no journal command %q", verb)
	return EXIT_ERROR
}
