package leita_cli

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:terminal"

import "../term"

JOURNAL_USAGE :: `leita journal — record which folders change, so a scan reads only those.

  leita journal on          start the recorder, a system service, installing it
                            first unless a package did; needs root: run it under sudo
  leita journal off         stop the recorder and remove its logs, and the service
                            too unless a package installed it
  leita journal status      whether the recorder runs, which filesystems it records
                            and which it cannot, and how fresh each log is
  leita journal run         record changes until stopped: what the service runs

Linux keeps no record of what changed while nothing was listening, so without the
recorder a scan asks every folder when it last changed. Nothing is recorded until
leita journal on. The logs, in /var/lib/leita/journal, hold a hash of each folder
that changed and when, not its name. btrfs subvolumes are not recorded yet.
On macOS and Windows the system records changes itself, and this does nothing.
`

journal_command_line :: proc(args: []string) -> int {
	mode, _ := term.parse_mode(os.get_env("LEITA_COLOR", context.temp_allocator))
	style := term.detect(terminal.is_terminal(os.stdout), mode)
	return journal_dispatch(style, args, os.to_writer(os.stdout))
}

// journal_print_usage writes JOURNAL_USAGE on w: plain, byte for byte; for a person, with weight.
@(private)
journal_print_usage :: proc(style: term.Style, w: io.Writer) {
	b := strings.builder_make(context.temp_allocator)
	term.write_usage(&b, style, "leita journal", JOURNAL_USAGE)
	fmt.wprint(w, strings.to_string(b))
}

// journal_errorf says what went wrong on w, the prefix in bold for a person.
@(private)
journal_errorf :: proc(style: term.Style, w: io.Writer, format: string, args: ..any) {
	fmt.wprintfln(w, "%s %s", term.painted(style, {.Bold}, "error:"), fmt.tprintf(format, ..args))
}
