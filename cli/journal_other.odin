#+build !linux
package leita_cli

import "core:fmt"
import "core:io"

import "../term"

// JOURNAL_OWN is what leita journal says where the system records changes itself.
JOURNAL_OWN :: "this system records which folders change itself; leita reads that, and needs no recorder"

// journal_dispatch says, for every command, that there is nothing to do here.
@(private)
journal_dispatch :: proc(style: term.Style, args: []string, w: io.Writer) -> int {
	_ = style
	_ = args
	fmt.wprintln(w, JOURNAL_OWN)
	return EXIT_OK
}
