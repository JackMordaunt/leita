#+build linux
package changes

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "../journal"

// An empty folder of logs, read on this test's thread instead of journal.DIR, so
// a recorder running on the machine does not answer the test.
@(private = "file")
no_logs :: proc(t: ^testing.T, name: string) -> string {
	dir, _ := os.temp_directory(context.temp_allocator)
	logs, _ := filepath.join(
		{dir, fmt.tprintf("leita_changes_logs_%s", name)},
		context.temp_allocator,
	)
	os.remove_all(logs)
	testing.expect(t, os.make_directory_all(logs) == nil, "could not make the logs folder")
	journal.logs_here = logs
	return logs
}

// A cursor taken now asks for a probe from just before it, and carries on when the
// place was last scanned whole.
@(test)
test_a_linux_cursor_asks_for_a_probe :: proc(t: ^testing.T) {
	logs := no_logs(t, "probe")
	defer os.remove_all(logs)
	defer journal.logs_here = ""
	place, _ := os.temp_directory(context.temp_allocator)
	c, ok := now(place)
	testing.expect(t, ok, "no cursor for the temp directory")
	set, next, err := since(place, c)
	defer change_set_destroy(&set)
	testing.expect_value(t, err, Error.None)
	testing.expectf(t, !set.rescan, "rescan: %s", set.why)
	testing.expect(t, set.probe, "no probe")
	testing.expect_value(t, set.since, c.position - i64(SLACK))
	testing.expect(t, next.position >= c.position, "the cursor went back")
	testing.expect_value(t, next.full, c.full)
}

// What leaves a cursor unusable says so, and why.
@(test)
test_a_linux_cursor_that_cannot_be_trusted_rescans :: proc(t: ^testing.T) {
	place, _ := os.temp_directory(context.temp_allocator)
	c, ok := now(place)
	testing.expect(t, ok, "no cursor for the temp directory")

	moved := c
	moved.volume[0] += 1
	stale := c
	stale.full -= i64(STALE_AFTER) + 1
	ahead := c
	ahead.position += i64(STALE_AFTER)
	for bad in ([]Cursor{{}, moved, stale, ahead}) {
		set, _, err := since(place, bad)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, set.rescan && set.why != "", "%v: no rescan", bad)
	}
}

/*
mkfs on the same partition keeps its device number, and a restored image's
directories can be older than the cursor, so a probe would find nothing changed: the
filesystem's id, or the place's inode or birth time, differing says the tree was
replaced.
*/
@(test)
test_a_linux_cursor_rescans_a_filesystem_made_anew :: proc(t: ^testing.T) {
	place, _ := os.temp_directory(context.temp_allocator)
	c, ok := now(place)
	testing.expect(t, ok, "no cursor for the temp directory")
	remade := c
	remade.volume[1] += 1
	restored := c
	restored.place[0] += 1
	reborn := c
	reborn.place[1] += 1
	for bad in ([]Cursor{remade, restored, reborn}) {
		set, _, err := since(place, bad)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, set.rescan && set.why != "", "%v: no rescan", bad)
	}
}

// Another directory renamed onto the place keeps its own, older stamps: the place's
// inode differs, and the place is scanned whole.
@(test)
test_a_directory_renamed_onto_the_place_rescans :: proc(t: ^testing.T) {
	dir, _ := os.temp_directory(context.temp_allocator)
	place, _ := filepath.join({dir, "leita_changes_renamed_place"}, context.temp_allocator)
	other, _ := filepath.join({dir, "leita_changes_renamed_other"}, context.temp_allocator)
	os.remove_all(place)
	os.remove_all(other)
	testing.expect(t, os.make_directory(place) == nil, "could not make the place")
	testing.expect(t, os.make_directory(other) == nil, "could not make the other")
	defer os.remove_all(place)
	defer os.remove_all(other)
	c, ok := now(place)
	testing.expect(t, ok, "no cursor for the place")
	testing.expect(t, os.rename(other, place) == nil, "could not rename onto the place")
	set, _, err := since(place, c)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, set.why, "another directory is in the place than when it was read")
}

// A log for the filesystem place is on, in logs, its paths spelt from mount:
// heartbeats every 10 s from 40 s before the cursor to 1 s ago, with `extra`
// records among them.
@(private = "file")
write_log :: proc(t: ^testing.T, logs, place, mount: string, c: Cursor, extra: []journal.Record) {
	fsid, ok := journal.fsid_of(place)
	testing.expect(t, ok, "no fsid for the place")
	records := make([dynamic]journal.Record, context.temp_allocator)
	now := now_ns()
	beat := i64(journal.HEARTBEAT)
	for at := c.position - 40 * i64(time.Second); at < now - i64(time.Second); at += beat {
		append(&records, journal.Record{.Heartbeat, at, 0})
	}
	append(&records, journal.Record{.Heartbeat, now - i64(time.Second), 0})
	append(&records, ..extra)
	// In time order, as the recorder appends them.
	for i in 1 ..< len(records) {
		for j := i; j > 0 && records[j].time < records[j - 1].time; j -= 1 {
			records[j], records[j - 1] = records[j - 1], records[j]
		}
	}
	b := make([dynamic]byte, context.temp_allocator)
	append(&b, ..journal.header_make(mount, context.temp_allocator))
	buf: [journal.RECORD_SIZE]byte
	for r in records {
		journal.record_put(buf[:], r)
		append(&b, ..buf[:])
	}
	path, _ := filepath.join({logs, journal.log_name(fsid)}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, b[:]) == nil, "could not write the log")
}

// With a log that covers the time since the cursor, since names what changed by
// hash, from the place's canonical path, and the next window begins where the
// log's record ends.
@(test)
test_a_covered_log_names_what_changed :: proc(t: ^testing.T) {
	logs := no_logs(t, "covered")
	defer os.remove_all(logs)
	defer journal.logs_here = ""
	place, _ := os.temp_directory(context.temp_allocator)
	root, canon := journal.canonical(place, context.temp_allocator)
	testing.expect(t, canon, "no canonical path for the temp directory")
	c, ok := now(place)
	testing.expect(t, ok, "no cursor for the temp directory")
	c.position -= 15 * i64(time.Second)
	sub := journal.hash_path(fmt.tprintf("%s/sub", root))
	before := journal.hash_path(fmt.tprintf("%s/before", root))
	changed := []journal.Record {
		{.Changed, c.position - 30 * i64(time.Second), before},
		{.Changed, c.position + 1, sub},
	}
	write_log(t, logs, place, "/", c, changed)

	set, next, err := since(place, c)
	defer change_set_destroy(&set)
	testing.expect_value(t, err, Error.None)
	testing.expectf(t, !set.rescan, "rescan: %s", set.why)
	testing.expect(t, set.by_hash && !set.probe, "the log was not used")
	testing.expect_value(t, set.root, root)
	testing.expect(t, sub in set.hashes, "the change in the window was not named")
	testing.expect(t, before not_in set.hashes, "a change before the window was named")
	testing.expect(
		t,
		next.position < now_ns() && next.position > c.position,
		"the next window does not begin at the log's end",
	)
	testing.expect_value(t, next.full, c.full)
}

// A log with a break in it, one that is not recording now, and one that spells
// paths from a mount the place is not under all leave the place to a probe.
@(test)
test_a_log_that_does_not_cover_falls_back_to_a_probe :: proc(t: ^testing.T) {
	logs := no_logs(t, "fallback")
	defer os.remove_all(logs)
	defer journal.logs_here = ""
	place, _ := os.temp_directory(context.temp_allocator)
	c, ok := now(place)
	testing.expect(t, ok, "no cursor for the temp directory")
	c.position -= 15 * i64(time.Second)
	Case :: struct {
		name:  string,
		mount: string,
		extra: []journal.Record,
	}
	cases := []Case {
		{"overflow", "/", {{.Overflow, c.position + 1, 0}}},
		{"restart", "/", {{.Start, c.position + 1, 4}}},
		{"another mount", "/leita/nowhere", {}},
	}
	for k in cases {
		write_log(t, logs, place, k.mount, c, k.extra)
		set, next, err := since(place, c)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, set.probe && !set.by_hash, "%s: no probe", k.name)
		testing.expectf(t, next.position >= c.position, "%s: the cursor went back", k.name)
		change_set_destroy(&set)
	}

	// A log whose last heartbeat is half a minute old: the recorder is not running.
	write_log(t, logs, place, "/", c, {})
	fsid, _ := journal.fsid_of(place)
	path, _ := filepath.join({logs, journal.log_name(fsid)}, context.temp_allocator)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	_, at, _ := journal.header_read(data)
	testing.expect(t, os.write_entire_file(path, data[:at + 3 * journal.RECORD_SIZE]) == nil)
	set, _, _ := since(place, c)
	defer change_set_destroy(&set)
	testing.expect(t, set.probe && !set.by_hash, "a stale log was used")
}
