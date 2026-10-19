package journal

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// SEC is a second in ns, the unit the tests' records are written in.
@(private)
SEC :: i64(time.Second)

// T0 is when the tests' logs begin, ns since the epoch.
@(private = "file")
T0 :: i64(1_760_000_000) * SEC

// A log file holding the header for mount and records, in a folder of its own.
@(private = "file")
log_file :: proc(t: ^testing.T, name, mount: string, records: []Record) -> string {
	dir, _ := os.temp_directory(context.temp_allocator)
	path, _ := filepath.join(
		{dir, fmt.tprintf("leita_journal_%s_%d.log", name, os.get_pid())},
		context.temp_allocator,
	)
	b := make([dynamic]byte, context.temp_allocator)
	append(&b, ..header_make(mount, context.temp_allocator))
	buf: [RECORD_SIZE]byte
	for r in records {
		record_put(buf[:], r)
		append(&b, ..buf[:])
	}
	testing.expect(t, os.write_entire_file(path, b[:]) == nil, "could not write the log")
	return path
}

// Heartbeats every HEARTBEAT from `from` up to and including `to`, ns.
@(private = "file")
beats :: proc(from, to: i64) -> []Record {
	out := make([dynamic]Record, context.temp_allocator)
	for at := from; at <= to; at += i64(HEARTBEAT) {
		append(&out, Record{.Heartbeat, at, 0})
	}
	return out[:]
}

@(private = "file")
joined :: proc(parts: ..[]Record) -> []Record {
	out := make([dynamic]Record, context.temp_allocator)
	for p in parts {
		append(&out, ..p)
	}
	return out[:]
}

// A path's hash is FNV-1a 64 of its bytes, and a child's follows from its parent's.
@(test)
test_a_path_hashes_as_fnv1a :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_path(""), u64(0xcbf29ce484222325))
	testing.expect_value(t, hash_path("a"), u64(0xaf63dc4c8601ec8c))
	testing.expect_value(t, hash_child(hash_path("/mnt/e"), "jt"), hash_path("/mnt/e/jt"))
	testing.expect_value(t, hash_child(hash_path("/"), "home", false), hash_path("/home"))
}

// A header and a record read back as written; a header cut short is refused.
@(test)
test_a_log_reads_back_what_was_written :: proc(t: ^testing.T) {
	head := header_make("/mnt/e", context.temp_allocator)
	mount, size, ok := header_read(head)
	testing.expect(t, ok, "the header did not read back")
	testing.expect_value(t, mount, "/mnt/e")
	testing.expect_value(t, size, len(head))
	_, _, ok = header_read(head[:len(head) - 1])
	testing.expect(t, !ok, "a short header was read")
	_, _, ok = header_read(transmute([]byte)string("LEITAJL0\x00\x00"))
	testing.expect(t, !ok, "another magic was read")
	// A length no mount point has, with as many bytes after it as it says.
	long := make([]byte, len(MAGIC) + 2 + 5000, context.temp_allocator)
	copy(long, MAGIC)
	endian.put_u16(long[len(MAGIC):], .Little, 5000)
	_, _, ok = header_read(long)
	testing.expect(t, !ok, "a header longer than a mount point was read")

	buf: [RECORD_SIZE]byte
	r := Record{.Changed, -5, 0xfedc_ba98_7654_3210}
	record_put(buf[:], r)
	got, ok2 := record_get(buf[:])
	testing.expect(t, ok2, "the record did not read back")
	testing.expect_value(t, got, r)
	_, ok2 = record_get(buf[:len(buf) - 1])
	testing.expect(t, !ok2, "a short record was read")
	_, ok2 = record_get(nil)
	testing.expect(t, !ok2, "an empty record was read")
}

// A log with a heartbeat before the window and every 10 s through it covers it,
// and names the directories that changed in it, not those before.
@(test)
test_a_log_with_no_break_covers_the_window :: proc(t: ^testing.T) {
	records := joined(
		{{.Start, T0, 7}, {.Changed, T0 + 1 * SEC, 1}},
		beats(T0 + 10 * SEC, T0 + 40 * SEC),
		{{.Changed, T0 + 41 * SEC, 2}, {.Changed, T0 + 42 * SEC, 3}},
		beats(T0 + 50 * SEC, T0 + 60 * SEC),
	)
	path := log_file(t, "covered", "/mnt/e", records)
	defer os.remove(path)
	w, why := window(path, T0 + 25 * SEC, T0 + 65 * SEC)
	defer window_destroy(&w)
	testing.expectf(t, why == "", "not covered: %s", why)
	testing.expect_value(t, w.mount, "/mnt/e")
	testing.expect_value(t, w.end, T0 + 60 * SEC)
	testing.expect_value(t, len(w.hashes), 2)
	testing.expect(t, 2 in w.hashes && 3 in w.hashes, "a change in the window is missing")
	testing.expect(t, 1 not_in w.hashes, "a change before the window was named")

	// A window that starts at the Start is covered too.
	w2, why2 := window(path, T0, T0 + 65 * SEC)
	defer window_destroy(&w2)
	testing.expectf(t, why2 == "", "from the start, not covered: %s", why2)
	testing.expect(t, 1 in w2.hashes, "the change after the start is missing")
}

// Whatever breaks the record of a window says so, and names nothing.
@(test)
test_a_break_in_the_log_is_not_covered :: proc(t: ^testing.T) {
	Case :: struct {
		name:    string,
		records: []Record,
		from:    i64,
	}
	now := T0 + 65 * SEC
	cases := []Case {
		{
			"gap",
			joined(beats(T0, T0 + 20 * SEC), beats(T0 + 45 * SEC, T0 + 60 * SEC)),
			T0 + 5 * SEC,
		},
		{
			"overflow",
			joined(
				beats(T0, T0 + 30 * SEC),
				{{.Overflow, T0 + 31 * SEC, 0}},
				beats(T0 + 40 * SEC, T0 + 60 * SEC),
			),
			T0 + 5 * SEC,
		},
		{
			"restart",
			joined(
				beats(T0, T0 + 30 * SEC),
				{{.Start, T0 + 32 * SEC, 9}},
				beats(T0 + 40 * SEC, T0 + 60 * SEC),
			),
			T0 + 5 * SEC,
		},
		{"stopped", joined(beats(T0, T0 + 30 * SEC), {{.Stop, T0 + 31 * SEC, 0}}), T0 + 5 * SEC},
		{"old", beats(T0, T0 + 30 * SEC), T0 + 5 * SEC},
		{"late", beats(T0 + 10 * SEC, T0 + 60 * SEC), T0 + 5 * SEC},
		{
			"stop before",
			joined(
				beats(T0, T0 + 20 * SEC),
				{{.Stop, T0 + 21 * SEC, 0}},
				{{.Start, T0 + 30 * SEC, 3}},
				beats(T0 + 40 * SEC, T0 + 60 * SEC),
			),
			T0 + 25 * SEC,
		},
		{
			"clock back",
			joined(
				beats(T0, T0 + 30 * SEC),
				{{.Changed, T0 + 25 * SEC, 1}},
				beats(T0 + 40 * SEC, T0 + 60 * SEC),
			),
			T0 + 5 * SEC,
		},
	}
	for c in cases {
		path := log_file(
			t,
			strings.concatenate({"break_", c.name}, context.temp_allocator),
			"/",
			c.records,
		)
		w, why := window(path, c.from, now)
		testing.expectf(t, why != "", "%s: covered", c.name)
		testing.expectf(t, len(w.hashes) == 0, "%s: named %d directories", c.name, len(w.hashes))
		window_destroy(&w)
		os.remove(path)
	}
	_, why := window("/no/such/leita/log", T0, now)
	testing.expect(t, why != "", "a log that is not there covered the window")
}

/*
An Overflow, which write_log appends after the records a full volume did not take,
breaks every window across it, and only those: a window that begins after it is
covered again, and names what changed then.
*/
@(test)
test_an_overflow_breaks_only_the_windows_across_it :: proc(t: ^testing.T) {
	records := joined(
		beats(T0, T0 + 20 * SEC),
		{{.Changed, T0 + 21 * SEC, 1}, {.Overflow, T0 + 21 * SEC, 0}},
		beats(T0 + 30 * SEC, T0 + 50 * SEC),
		{{.Changed, T0 + 51 * SEC, 2}},
	)
	path := log_file(t, "after_overflow", "/mnt/e", records)
	defer os.remove(path)
	across, why := window(path, T0 + 5 * SEC, T0 + 55 * SEC)
	defer window_destroy(&across)
	testing.expect_value(t, why, "the recorder fell behind and lost changes")
	after, why2 := window(path, T0 + 35 * SEC, T0 + 55 * SEC)
	defer window_destroy(&after)
	testing.expectf(t, why2 == "", "a window after the overflow was not covered: %s", why2)
	testing.expect(t, 2 in after.hashes && 1 not_in after.hashes, "the wrong changes were named")
}

// Records after the window belong to the next one; a record cut short at the end,
// as a write stopped in the middle leaves, is not read.
@(test)
test_a_window_ends_at_its_last_record :: proc(t: ^testing.T) {
	records := joined(
		beats(T0, T0 + 30 * SEC),
		{{.Changed, T0 + 31 * SEC, 5}},
		beats(T0 + 40 * SEC, T0 + 50 * SEC),
	)
	path := log_file(t, "end", "/", records)
	defer os.remove(path)
	w, why := window(path, T0 + 5 * SEC, T0 + 35 * SEC)
	defer window_destroy(&w)
	testing.expectf(t, why == "", "not covered: %s", why)
	testing.expect_value(t, w.end, T0 + 31 * SEC)
	testing.expect(t, 5 in w.hashes, "the last change was not named")

	data, _ := os.read_entire_file(path, context.temp_allocator)
	torn := make([]byte, len(data) + 9, context.temp_allocator)
	copy(torn, data)
	testing.expect(t, os.write_entire_file(path, torn) == nil)
	w2, why2 := window(path, T0 + 5 * SEC, T0 + 55 * SEC)
	defer window_destroy(&w2)
	testing.expectf(t, why2 == "", "a torn last record broke the log: %s", why2)
	testing.expect_value(t, w2.end, T0 + 50 * SEC)
}

// Compaction drops what is older than it is asked to keep, and leaves a log that
// reads as before for what it kept.
@(test)
test_compaction_drops_old_records :: proc(t: ^testing.T) {
	records := joined(
		{{.Start, T0, 1}, {.Changed, T0 + SEC, 8}},
		beats(T0 + 10 * SEC, T0 + 60 * SEC),
	)
	path := log_file(t, "compact", "/mnt/e", records)
	defer os.remove(path)
	dropped, err := compact(path, T0 + 30 * SEC)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, dropped, 4)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	mount, at, ok := header_read(data)
	testing.expect(t, ok && mount == "/mnt/e", "the header was not kept")
	testing.expect_value(t, (len(data) - at) / RECORD_SIZE, 4)
	rec, ok2 := record_get(data[at:])
	testing.expect(t, ok2, "the kept record did not read")
	testing.expect_value(t, rec.time, T0 + 30 * SEC)
	w, why := window(path, T0 + 5 * SEC, T0 + 65 * SEC)
	defer window_destroy(&w)
	testing.expect(t, why != "", "a window older than the log was covered")
	w2, why2 := window(path, T0 + 35 * SEC, T0 + 65 * SEC)
	defer window_destroy(&w2)
	testing.expectf(t, why2 == "", "what was kept is not covered: %s", why2)
}

// mountinfo reads with its escapes undone; what is never recorded is said, quietly
// or with why. A mount made read-only over a writable filesystem, as the service's
// ProtectSystem=strict makes every mount it sees, is still recorded.
@(test)
test_mounts_are_read_and_judged :: proc(t: ^testing.T) {
	text :=
		"36 1 8:1 / / ro,relatime shared:1 - ext4 /dev/sda1 rw\n" +
		"40 36 0:22 / /proc rw - proc proc rw\n" +
		"41 36 8:2 / /mnt/my\\040disk ro,relatime - xfs /dev/sda2 ro\n" +
		"42 36 0:50 / /net rw master:2 - nfs4 srv:/x rw\n" +
		"43 36 0:30 /@home /home rw - btrfs /dev/sdb rw\n" +
		"garbage\n"
	mounts := mounts_parse(text)
	defer mounts_destroy(mounts)
	testing.expect_value(t, len(mounts), 5)
	testing.expect_value(t, mounts[2].point, "/mnt/my disk")
	testing.expect_value(t, mounts[4].root, "/@home")
	testing.expect_value(t, mounts[0].device, "8:1")
	want := []struct {
		try: bool,
		why: string,
	} {
		{true, ""},
		{false, ""},
		{false, "the filesystem is read-only"},
		{false, "a network filesystem, which another machine can change"},
		{true, ""},
	}
	for m, i in mounts {
		try, why := judge(m)
		testing.expectf(t, try == want[i].try, "%s: try %v", m.point, try)
		testing.expectf(t, why == want[i].why, "%s: why %q", m.point, why)
	}
}

/*
A FUSE filesystem, whatever its kind, is not tried unless its mount point is listed,
and says why; sshfs is a network one, and fusectl one not worth listing.
*/
@(test)
test_fuse_is_skipped_unless_listed :: proc(t: ^testing.T) {
	text :=
		"60 36 0:60 / /run/user/1000/doc rw - fuse.portal portal rw,user_id=1000\n" +
		"61 36 8:33 / /media/win rw - fuseblk /dev/sdc1 rw,user_id=0\n" +
		"62 36 0:62 / /mnt/fuse rw - fuse myfs rw,user_id=1000\n" +
		"63 36 0:63 / /mnt/ssh rw - fuse.sshfs host:/ rw,user_id=1000\n" +
		"64 36 0:64 / /sys/fs/fuse/connections rw - fusectl fusectl rw\n"
	mounts := mounts_parse(text)
	defer mounts_destroy(mounts)
	testing.expect_value(t, len(mounts), 5)
	fuse :: "a FUSE filesystem, whose program could keep the recorder waiting"
	want := []string {
		fuse,
		fuse,
		fuse,
		"a network filesystem, which another machine can change",
		"",
	}
	for m, i in mounts {
		try, why := judge(m)
		testing.expectf(t, !try, "%s: tried", m.point)
		testing.expectf(t, why == want[i], "%s: why %q", m.point, why)
	}
	for m in mounts[:3] {
		try, why := judge(m, {m.point})
		testing.expectf(t, try && why == "", "%s listed: not tried, %q", m.point, why)
	}
	try, _ := judge(mounts[0], {"/mnt/fuse"})
	testing.expect(t, !try, "a FUSE mount was tried when another was listed")
}

/*
What the recorder does with each mount table, less the marks: forget what has gone
or changed, then judge each mount not tried yet, recording what judge allows. It
returns the mounts tried this time, by point.
*/
@(private = "file")
judge_table :: proc(j: ^Verdicts, text: string, recorded: []string) -> []string {
	mounts := mounts_parse(text, context.temp_allocator)
	verdicts_prune(j, mounts, recorded)
	tried := make([dynamic]string, context.temp_allocator)
	for m in mounts {
		if !verdicts_try(j, m) {
			continue
		}
		append(&tried, m.point)
		if try, why := judge(m); try {
			verdicts_record(j, m)
		} else if why != "" {
			verdicts_skip(j, m, why)
		}
	}
	return tried[:]
}

// A disk unplugged leaves no status line behind and is tried again when plugged in,
// under a new mount id; a filesystem remounted read-write is tried again under the
// same id; a mount gone whose device stays recorded is not judged again.
@(test)
test_mounts_gone_or_changed_are_judged_again :: proc(t: ^testing.T) {
	j: Verdicts
	defer verdicts_destroy(&j)
	root :: "36 1 8:1 / / rw - ext4 /dev/sda1 rw\n"
	usb :: "50 36 8:17 / /media/usb rw - ext4 /dev/sdb1 ro\n"
	bind :: "51 36 8:1 /srv /srv rw - ext4 /dev/sda1 rw\n"

	testing.expect_value(t, len(judge_table(&j, root + usb + bind, {})), 3)
	testing.expect_value(t, len(j.skipped), 1)
	testing.expect_value(t, len(judge_table(&j, root + usb + bind, {"8:1"})), 0)

	judge_table(&j, root + bind, {"8:1"})
	testing.expect_value(t, len(j.skipped), 0)
	testing.expect(t, "8:17" not_in j.devices, "an unplugged disk stayed judged")
	plugged :: "60 36 8:17 / /media/usb rw - ext4 /dev/sdb1 ro\n"
	testing.expect_value(t, len(judge_table(&j, root + bind + plugged, {"8:1"})), 1)
	testing.expect_value(t, len(j.skipped), 1)

	remounted :: "60 36 8:17 / /media/usb rw - ext4 /dev/sdb1 rw\n"
	testing.expect_value(t, len(judge_table(&j, root + bind + remounted, {"8:1"})), 1)
	testing.expect_value(t, len(j.skipped), 0)
	testing.expect(t, "8:17" in j.devices, "a filesystem remounted read-write was not recorded")

	testing.expect_value(t, len(judge_table(&j, root + remounted, {"8:1", "8:17"})), 0)
	testing.expect(t, "8:1" in j.devices, "a recorded device was forgotten when a bind mount went")

	reused :: "51 36 7:0 / /mnt/e rw - ext4 /dev/loop0 rw\n"
	testing.expect_value(t, len(judge_table(&j, root + remounted + reused, {"8:1", "8:17"})), 1)
	testing.expect(t, "7:0" in j.devices, "a mount given a gone mount's id was not tried")
}

// A recording let go while its mount is still listed, as flush lets go one whose
// mount point no longer holds it, is tried again with the same table.
@(test)
test_a_recording_let_go_while_mounted_is_judged_again :: proc(t: ^testing.T) {
	j: Verdicts
	defer verdicts_destroy(&j)
	table :: "36 1 8:1 / / rw - ext4 /dev/sda1 rw\n50 36 7:0 / /mnt/e rw - ext4 /dev/loop0 rw\n"

	testing.expect_value(t, len(judge_table(&j, table, {})), 2)
	testing.expect_value(t, len(judge_table(&j, table, {"8:1", "7:0"})), 0)
	verdicts_forget(&j, "7:0")
	tried := judge_table(&j, table, {"8:1"})
	testing.expect_value(t, len(tried), 1)
	testing.expect(t, len(tried) == 1 && tried[0] == "/mnt/e", "the let-go mount was not tried")
	testing.expect(t, "7:0" in j.devices, "the let-go filesystem was not recorded again")
}

/*
A machine asleep for an hour leaves a gap a Slept record explains: the window
across it is covered, and names what changed on both sides. The same gap with no
Slept, with a Slept that carries a later time than the record before it, as one
does when a record the recorder appended is missing, or with a Start after waking,
as a recorder that died while the machine slept writes, is not.
*/
@(test)
test_a_suspend_is_covered_only_by_a_slept_record :: proc(t: ^testing.T) {
	HOUR :: 3600 * SEC
	before := joined(beats(T0, T0 + 20 * SEC), {{.Changed, T0 + 21 * SEC, 1}})
	after := joined(
		{{.Changed, T0 + HOUR + 1 * SEC, 2}},
		beats(T0 + HOUR + 5 * SEC, T0 + HOUR + 45 * SEC),
	)
	// What the recorder writes: the time of the last record before the Slept.
	slept := Record{.Slept, T0 + HOUR, u64(T0 + 21 * SEC)}
	from, to := T0 + 5 * SEC, T0 + HOUR + 50 * SEC

	path := log_file(t, "slept", "/mnt/e", joined(before, {slept}, after))
	defer os.remove(path)
	w, why := window(path, from, to)
	defer window_destroy(&w)
	testing.expectf(t, why == "", "a suspend was not covered: %s", why)
	testing.expect(t, 1 in w.hashes && 2 in w.hashes, "a change beside the suspend is missing")

	lost := Record{.Slept, T0 + HOUR, u64(T0 + 22 * SEC)}
	restarted := joined({{.Start, T0 + HOUR + 1 * SEC, 9}}, after)
	Case :: struct {
		name:    string,
		records: []Record,
		want:    string,
	}
	cases := []Case {
		{"bare gap", joined(before, after), "the recorder missed a heartbeat"},
		{"a record lost", joined(before, {lost}, after), "the recorder missed a heartbeat"},
		{
			"died asleep",
			joined(before, {slept}, restarted),
			"the recorder started again since the place was last read",
		},
	}
	for c in cases {
		p := log_file(t, fmt.tprintf("slept_%s", c.name), "/mnt/e", c.records)
		defer os.remove(p)
		bad, bad_why := window(p, from, to)
		defer window_destroy(&bad)
		testing.expectf(t, bad_why == c.want, "%s: %q", c.name, bad_why)
		testing.expectf(t, len(bad.hashes) == 0, "%s: named changes", c.name)
	}
}

// A log opens with its header read and its whole records counted, a torn last one
// left out; a log that is missing, or does not begin with a whole header, does not
// open, and window says which of the two it was.
@(test)
test_a_log_opens_only_with_a_whole_header :: proc(t: ^testing.T) {
	path := log_file(t, "open", "/mnt/e", {{.Start, T0, 7}, {.Heartbeat, T0 + 10 * SEC, 0}})
	defer os.remove(path)
	torn, _ := os.open(path, {.Write, .Append})
	os.write(torn, []byte{1, 2, 3})
	os.close(torn)
	f, head, count, ok := open_log(path)
	testing.expect(t, ok && f != nil, "a whole log did not open")
	if f != nil {
		os.close(f)
	}
	testing.expect_value(t, head.mount, "/mnt/e")
	testing.expect_value(t, head.at, i64(len(MAGIC) + 2 + len("/mnt/e")))
	testing.expect_value(t, count, i64(2))

	short := log_file(t, "short", "/mnt/e", {})
	defer os.remove(short)
	testing.expect(t, os.write_entire_file(short, transmute([]byte)string("LEITAJL1\x06")) == nil)
	f, _, _, ok = open_log(short)
	testing.expect(t, !ok && f == nil, "a log with half a header opened")
	_, why := window(short, T0, T0 + 10 * SEC)
	testing.expect_value(t, why, "the record of changes cannot be read")

	_, why = window(fmt.tprintf("%s.missing", path), T0, T0 + 10 * SEC)
	testing.expect_value(t, why, "no changes are recorded for this filesystem")
}
