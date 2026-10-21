#+build linux
package leita_cli

import "core:c/libc"
import "core:fmt"
import "core:io"
import "core:sync"
import "core:sys/linux"
import "core:time"

import "../human"
import "../journal"
import "../term"

// JOURNAL_NEEDS_ROOT says how to turn the recorder on without root.
JOURNAL_NEEDS_ROOT ::
	"the recorder is a system service, so this needs root: run sudo leita journal on, " +
	"or turn on Record changes in Leita's Monitoring"

// journal_dispatch carries out the journal command args names, saying how it went on w.
@(private)
journal_dispatch :: proc(style: term.Style, args: []string, w: io.Writer) -> int {
	verb := args[0] if len(args) > 0 else "status"
	switch verb {
	case "on":
		if linux.geteuid() != 0 {
			journal_errorf(style, w, JOURNAL_NEEDS_ROOT)
			return EXIT_ERROR
		}
		if problem := journal.switch_on(); problem != "" {
			journal_errorf(style, w, "%s", problem)
			return EXIT_ERROR
		}
		fmt.wprintfln(
			w,
			"recording changes: %s runs %s journal run",
			journal.SERVICE,
			journal.service_binary(),
		)
		return EXIT_OK
	case "off":
		if linux.geteuid() != 0 {
			journal_errorf(
				style,
				w,
				"the recorder is a system service, so this needs root: run sudo leita journal off",
			)
			return EXIT_ERROR
		}
		if problem := journal.switch_off(); problem != "" {
			journal_errorf(style, w, "%s", problem)
			return EXIT_ERROR
		}
		if journal.packaged() {
			fmt.wprintln(w, "not recording changes: the recorder is off and its logs are removed")
		} else {
			fmt.wprintln(
				w,
				"not recording changes: the recorder, its service and its logs are removed",
			)
		}
		return EXIT_OK
	case "status":
		journal_say_status(style, w)
		return EXIT_OK
	case "run":
		return journal_run_until_signalled(style, w)
	case "-h", "--help", "help":
		journal_print_usage(style, w)
		return EXIT_OK
	}
	journal_errorf(style, w, "no journal command %q", verb)
	fmt.wprintln(w)
	journal_print_usage(style, w)
	return EXIT_ERROR
}

// journal_stopping is set by SIGTERM or SIGINT, for the recorder to stop at.
@(private = "file")
journal_stopping: bool

@(private = "file")
journal_on_signal :: proc "c" (_: libc.int) {
	sync.atomic_store(&journal_stopping, true)
}

// journal_run_until_signalled records into DIR until the service is stopped.
@(private = "file")
journal_run_until_signalled :: proc(style: term.Style, w: io.Writer) -> int {
	libc.signal(libc.SIGTERM, journal_on_signal)
	libc.signal(libc.SIGINT, journal_on_signal)
	if problem := journal.run({logs = journal.DIR, stop = &journal_stopping}); problem != "" {
		journal_errorf(style, w, "%s", problem)
		return EXIT_ERROR
	}
	return EXIT_OK
}

journal_say_status :: proc(style: term.Style, w: io.Writer) {
	journal_write_status(style, w, journal.service_status())
}

journal_write_status :: proc(style: term.Style, w: io.Writer, s: journal.Service_Status) {
	switch {
	case !s.installed:
		fmt.wprintln(w, "not recording changes; sudo leita journal on starts the recorder")
	case s.active:
		fmt.wprintfln(w, "recording changes, through %s", journal.SERVICE)
	case:
		fmt.wprintfln(
			w,
			"%s is installed but not running: systemctl status %s says why",
			journal.SERVICE,
			journal.SERVICE,
		)
	}
	for row in s.filesystems {
		if row.recorded {
			age := "nothing yet"
			if row.has_last {
				age = fmt.tprintf(
					"last written %ds ago",
					(s.now - row.last_written) / i64(time.Second),
				)
			}
			fmt.wprintfln(
				w,
				"  %s  %s, %s, log %s, %s",
				term.painted(style, {.Bold}, row.mount),
				row.filesystem,
				"recorded",
				human.bytes(u64(row.size)),
				age,
			)
		} else {
			fmt.wprintfln(
				w,
				"  %s  %s, not recorded: %s",
				term.painted(style, {.Bold}, row.mount),
				row.filesystem,
				row.reason,
			)
		}
	}
}
