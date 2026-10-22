#+build linux
package leita_cli

import "core:strings"
import "core:testing"
import "core:time"

import "../journal"

@(test)
test_journal_dispatch_help_and_unknown :: proc(t: ^testing.T) {
	stdio_shared()
	defer stdio_done()
	for word in ([]string{"help", "-h", "--help"}) {
		b := strings.builder_make(context.temp_allocator)
		testing.expect_value(t, journal_dispatch({}, {word}, strings.to_writer(&b)), EXIT_OK)
		testing.expect_value(t, strings.to_string(b), JOURNAL_USAGE)
	}
	b := strings.builder_make(context.temp_allocator)
	testing.expect_value(t, journal_dispatch({}, {"unknown"}, strings.to_writer(&b)), EXIT_ERROR)
	testing.expect_value(
		t,
		strings.to_string(b),
		"error: no journal command \"unknown\"\n\n" + JOURNAL_USAGE,
	)
}

@(test)
test_journal_status_formats_recorded_and_skipped_filesystems :: proc(t: ^testing.T) {
	rows := make([dynamic]journal.Filesystem_Status, context.temp_allocator)
	append(
		&rows,
		journal.Filesystem_Status {
			mount = "/",
			filesystem = "ext4",
			recorded = true,
			size = 0,
			has_last = true,
			last_written = 5 * i64(time.Second),
		},
		journal.Filesystem_Status{mount = "/home", filesystem = "xfs", recorded = true},
		journal.Filesystem_Status{mount = "/data", filesystem = "btrfs", reason = "not supported"},
	)
	b := strings.builder_make(context.temp_allocator)
	journal_write_status(
		{},
		strings.to_writer(&b),
		{installed = true, active = true, now = 8 * i64(time.Second), filesystems = rows},
	)
	testing.expect_value(
		t,
		strings.to_string(b),
		"recording changes, through leita-journal.service\n" +
		"  /  ext4, recorded, log 0 B, last written 3s ago\n" +
		"  /home  xfs, recorded, log 0 B, nothing yet\n" +
		"  /data  btrfs, not recorded: not supported\n",
	)
}
