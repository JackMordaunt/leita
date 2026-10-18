#+build linux
package journal

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"

/*
These tests drive the recorder's own procs on a log in a temporary folder, with no
fanotify, so they need no root. The recorder end to end, marks and all, is
survey's test_the_recorder_names_exactly_what_changed, which only root runs.
*/

// A recorder with one filesystem, whose log is begun in a folder of the test's own;
// the log's path is fs.path. recorder_destroy lets it go.
@(private = "file")
recorder_with_log :: proc(t: ^testing.T, name: string) -> (r: Recorder) {
	dir, _ := os.temp_directory(context.temp_allocator)
	logs, _ := filepath.join({dir, fmt.tprintf("leita_recorder_%s", name)}, context.temp_allocator)
	os.remove_all(logs)
	testing.expect(t, os.make_directory_all(logs) == nil, "could not make the logs folder")
	r = Recorder {
		cfg = {logs = strings.clone(logs)},
		write = os.write,
		clock = clocks_now,
		fan = -1,
		mountinfo = -1,
	}
	fs := Recorded_Filesystem {
		point = strings.clone("/mnt/e"),
	}
	fs.path, _ = filepath.join({logs, "log"})
	testing.expect(t, ensure_header(&fs), "could not write the header")
	compact_log(&fs)
	testing.expect(t, fs.log != nil, "could not open the log")
	append(&r.recorded, fs)
	return r
}

@(private = "file")
recorder_with_log_destroy :: proc(r: ^Recorder) {
	os.remove_all(r.cfg.logs)
	delete(r.cfg.logs)
	recorder_destroy(r)
}

// The records of the log at path, in the temp allocator, and whether its length is
// the header and whole records.
@(private = "file")
records_of :: proc(t: ^testing.T, path: string) -> (out: []Record, whole: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	_, at, ok := header_read(data)
	testing.expect(t, ok, "the header did not read")
	list := make([dynamic]Record, context.temp_allocator)
	for i := at; i + RECORD_SIZE <= len(data); i += RECORD_SIZE {
		rec, _ := record_get(data[i:])
		append(&list, rec)
	}
	return list[:], (len(data) - at) % RECORD_SIZE == 0
}

@(private = "file")
kinds_of :: proc(records: []Record) -> []Kind {
	out := make([]Kind, len(records), context.temp_allocator)
	for r, i in records {
		out[i] = r.kind
	}
	return out
}

// What the injected writers have been asked to write, and how they answer: they
// run on the test's own thread.
@(private = "file", thread_local)
writes: int

// short_once writes the first 20 bytes of its first write, a record and a bit, and
// says the volume is full; every later write goes through.
@(private = "file")
short_once :: proc(f: ^os.File, data: []byte) -> (int, os.Error) {
	writes += 1
	if writes > 1 {
		return os.write(f, data)
	}
	n, _ := os.write(f, data[:min(20, len(data))])
	return n, os.Platform_Error(linux.Errno.ENOSPC)
}

// full writes nothing, and says the volume is full.
@(private = "file")
full :: proc(f: ^os.File, data: []byte) -> (int, os.Error) {
	writes += 1
	return 0, os.Platform_Error(linux.Errno.ENOSPC)
}

/*
A write the log takes only part of, as a full volume does, leaves the log cut back
to its last whole record, the records not written after it, and an Overflow, so the
window across the loss is not covered.
*/
@(test)
test_a_short_write_is_cut_back_and_followed_by_an_overflow :: proc(t: ^testing.T) {
	r := recorder_with_log(t, "short")
	defer recorder_with_log_destroy(&r)
	fs := &r.recorded[0]
	mark_all(&r, .Start, 7)
	mark_all(&r, .Heartbeat)

	writes = 0
	r.write = short_once
	for h in ([]u64{1, 2, 3}) {
		append_record(fs, {.Changed, time.to_unix_nanoseconds(time.now()), h})
	}
	write_log(&r, fs)
	testing.expect_value(t, writes, 2)
	testing.expect(t, !fs.broken, "a log that took the Overflow was broken")

	records, whole := records_of(t, fs.path)
	testing.expect(t, whole, "the log was not cut back to a whole record")
	want := []Kind{.Start, .Heartbeat, .Changed, .Changed, .Changed, .Overflow}
	testing.expectf(t, slice.equal(kinds_of(records), want), "records %v", kinds_of(records))
	if len(records) == len(want) {
		testing.expect_value(t, records[2].hash, u64(1))
		testing.expect_value(t, records[4].hash, u64(3))
	}
	_, why := window(fs.path, records[0].time, time.to_unix_nanoseconds(time.now()))
	testing.expect_value(t, why, "the recorder fell behind and lost changes")
}

/*
A log that cannot take even the Overflow is broken: nothing more goes in it, the
changes buffered for it are let go, and the next mark begins it again with a Start
once it can be written, so no window across the loss is covered.
*/
@(test)
test_a_log_that_takes_nothing_begins_again :: proc(t: ^testing.T) {
	r := recorder_with_log(t, "full")
	defer recorder_with_log_destroy(&r)
	fs := &r.recorded[0]
	mark_all(&r, .Start, 7)

	writes = 0
	r.write = full
	append_record(fs, {.Changed, time.to_unix_nanoseconds(time.now()), 1})
	write_log(&r, fs)
	testing.expect(t, fs.broken, "a log that took nothing was not broken")
	testing.expect_value(t, len(fs.buf), 0)
	mark_all(&r, .Heartbeat)
	testing.expect(t, fs.broken, "a log that still takes nothing was begun again")
	records, whole := records_of(t, fs.path)
	testing.expect(t, whole, "the log was not cut back to a whole record")
	testing.expectf(t, slice.equal(kinds_of(records), []Kind{.Start}), "records %v", kinds_of(records))

	r.write = os.write
	append_record(fs, {.Changed, time.to_unix_nanoseconds(time.now()), 2})
	write_log(&r, fs)
	mark_all(&r, .Heartbeat)
	mark_all(&r, .Heartbeat)
	testing.expect(t, !fs.broken, "a log that can be written again stayed broken")
	records, _ = records_of(t, fs.path)
	want := []Kind{.Start, .Start, .Heartbeat}
	testing.expectf(t, slice.equal(kinds_of(records), want), "records %v", kinds_of(records))
	_, why := window(fs.path, records[0].time, time.to_unix_nanoseconds(time.now()))
	testing.expect_value(t, why, "the recorder started again since the place was last read")
}

// The test's clock, read on the test's thread: it reads what the test last set.
@(private = "file", thread_local)
set_clock: Clocks

@(private = "file")
test_clock :: proc() -> Clocks {
	return set_clock
}

/*
The recorder's own loop, turned with a clock that shows an hour's suspend after
twelve seconds of recording, writes a Slept that carries the time of the last record
before it, and the window across the suspend is covered. The turns are the loop's
less its poll, which only waits.
*/
@(test)
test_the_loop_writes_a_slept_cover_accepts :: proc(t: ^testing.T) {
	r := recorder_with_log(t, "slept")
	defer recorder_with_log_destroy(&r)
	r.clock = test_clock
	from := time.to_unix_nanoseconds(time.now())
	set_clock = {from, 0}
	mark_all(&r, .Start, 7)
	turns := turns_begin(&r)
	for s in 1 ..= 12 {
		set_clock = {from + i64(s) * SEC, i64(s) * SEC}
		take_turn(&r, &turns, false, false)
	}
	set_clock = {from + 3612 * SEC, 13 * SEC}
	take_turn(&r, &turns, false, false)
	set_clock = {from + 3614 * SEC, 15 * SEC}
	take_turn(&r, &turns, false, false)

	records, _ := records_of(t, r.recorded[0].path)
	want := []Kind{.Start, .Heartbeat, .Slept, .Heartbeat}
	testing.expectf(t, slice.equal(kinds_of(records), want), "records %v", kinds_of(records))
	if len(records) != len(want) {
		return
	}
	testing.expect_value(t, records[1].time, from + 10 * SEC)
	testing.expect_value(t, records[2].time, from + 3612 * SEC)
	testing.expect_value(t, slept_from(records[2]), records[1].time)
	w, why := window(r.recorded[0].path, from, from + 3614 * SEC)
	defer window_destroy(&w)
	testing.expectf(t, why == "", "the suspend was not covered: %s", why)
	testing.expect_value(t, w.end, from + 3612 * SEC)
}

// A place's mount point is the one its own mount is at, not the root above it.
@(test)
test_a_place_is_on_its_own_mount :: proc(t: ^testing.T) {
	root, ok := mount_of("/", context.temp_allocator)
	testing.expect(t, ok && root == "/", "/ is not on /")
	procs, ok2 := mount_of("/proc/self", context.temp_allocator)
	testing.expect(t, ok2 && procs == "/proc", "/proc/self is not on /proc")
	_, ok3 := mount_of("/no/such/leita/place", context.temp_allocator)
	testing.expect(t, !ok3, "a place that is not there has a mount")
}
