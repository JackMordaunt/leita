/*
Package journal records which directories change on Linux, so a later scan reads
again only those: the change journal macOS and Windows keep for themselves, which
Linux does not.

The recorder (`leita journal run`, record_linux.odin) runs as a system service that
`leita journal on` installs and nothing else does. It marks every local filesystem
with fanotify (FAN_MARK_FILESYSTEM, which needs CAP_SYS_ADMIN: fanotify_mark(2)),
collects the distinct directories that events name, and once a second resolves each
and appends one Changed record for it to the filesystem's log. A C prototype of
this loop, on ext4 under Linux 7.0.14 (aarch64, 2026-10-13), lost no event while
four kernel trees were unpacked and deleted at once, 194,000 events a second at the
peak, and used 0.013% of a core idle over 300 s.

# The log

One file a filesystem, `<DIR>/<fsid>.log`, the fsid statfs(2) reports as 16 hex
digits. The file starts with HEADER: MAGIC, then the mount point the recorder spelt
paths from, a little-endian u16 length and its bytes. Records follow, RECORD_SIZE
bytes each, little-endian, appended in time order: kind u8, time_ns i64 (since the
epoch), hash u64.

- Start: the recorder began; hash is a random generation.
- Heartbeat: every HEARTBEAT, once all events read so far are recorded.
- Changed: hash is FNV-1a 64 of the directory's canonical absolute path, as
  readlink of /proc/self/fd gives it. The log is world-readable and holds no names.
- Overflow: the kernel's queue overflowed, and events were lost; or the log took
  only part of a write, as a full volume does, and records were.
- Stop: the recorder stopped, or the filesystem went away.
- Slept: the machine was suspended; time is when the recorder woke, and hash is the
  time of the last record it appended to this log before, an i64 as a u64. The
  wall clock (CLOCK_REALTIME) runs on through a suspend and CLOCK_MONOTONIC does
  not (clock_gettime(2)), so a gap between them over HEARTBEAT says the machine
  slept. It comes before any other record written after waking.

The recorder drops records older than RETENTION when it starts and once a day.

# Reading it

A scan asks for the window from its cursor's time to now (window). The log covers
the window when it was recording throughout: a record at or before the window's
start, every record after it within twice HEARTBEAT of the one before, the last
within twice HEARTBEAT of now, and no Start, Stop or Overflow inside. A longer gap
is allowed only when a Slept record ends it and spans it. That assumes fanotify's
marks, held in kernel memory with the filesystem, outlast a suspend, and that no
other system writes the filesystem while this one sleeps. Neither was tested: the
OrbStack machine the recorder was tried on was never suspended. A recorder that
died leaves a gap with no Slept, and its next run writes a Start. Covered, the
directories to read again are those of the scan's own last tree whose canonical
path hashes to a Changed record in the window. A directory made since has no path
in that tree, and needs none: making it changed its parent, which the tree has,
and reading the parent again finds the new directory and walks it. A directory
renamed is the same: both parents changed. Not covered, the scan asks each
directory's modification time instead (package changes).

The window ends at the last record, not at now: an event not yet recorded when the
scan asked lands in the next scan's window instead.

btrfs refused a filesystem mark on a subvolume with EXDEV under Linux 7.0.14
(2026-10-13), whether mounted on its own or reached under the top level, and on the
machine tested / and /home were subvolumes. Those are not recorded yet, and
`leita journal status` lists each with the error its mark met. The follow-up is to
mark the top-level subvolume (subvolid=5) on a private mount and map its paths back
through each subvolume's mount root.
*/
package journal

import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// STATE_DIR is leita's own folder of system state; DIR, in it, is where the
// recorder keeps its logs and the scan reads them.
STATE_DIR :: "/var/lib/leita"
DIR       :: STATE_DIR + "/journal"

// logs_here is a test's own folder of logs, set on the test's thread so tests
// running beside it still read DIR; "" for DIR.
@(thread_local)
logs_here: string

// logs is where a scan reads logs: DIR, unless a test set logs_here.
logs :: proc() -> string {
	return logs_here if logs_here != "" else DIR
}

// MAGIC begins every log, and names its format.
MAGIC :: "LEITAJL1"

// HEARTBEAT is how often the recorder says it is still recording.
HEARTBEAT :: 10 * time.Second

// RETENTION is how long a record is kept.
RETENTION :: 30 * 24 * time.Hour

// RECORD_SIZE is the size of every record in a log: kind, time and hash.
RECORD_SIZE :: 17

// What a record says.
Kind :: enum u8 {
	Start     = 1,
	Heartbeat = 2,
	Changed   = 3,
	Overflow  = 4,
	Stop      = 5,
	Slept     = 6,
}

// One record of a log; time is in ns since the epoch.
Record :: struct {
	kind: Kind,
	time: i64,
	hash: u64,
}

// hash_path is the hash a Changed record carries for the directory at path:
// FNV-1a 64 of its bytes.
hash_path :: proc(path: string) -> u64 {
	return hash.fnv64a(transmute([]byte)path)
}

/*
hash_child is the hash of the path of `name` in the directory whose path hashes to
`dir`: the directory's path, a slash, then the name. Under "/", whose path already
ends in one, `slash` is false.
*/
hash_child :: proc(dir: u64, name: string, slash := true) -> u64 {
	// FNV-1a carries nothing but the hash from one byte to the next, so a path's
	// hash goes on from its parent's.
	h := dir
	if slash {
		h = hash.fnv64a(transmute([]byte)string("/"), h)
	}
	return hash.fnv64a(transmute([]byte)name, h)
}

// log_name is the file a filesystem's log is kept in, under logs().
log_name :: proc(fsid: [2]i32, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%08x%08x.log", u32(fsid[0]), u32(fsid[1]), allocator = allocator)
}

// log_path is where the log of the filesystem fsid names is, in allocator.
log_path :: proc(fsid: [2]i32, allocator := context.temp_allocator) -> string {
	path, _ := filepath.join({logs(), log_name(fsid, context.temp_allocator)}, allocator)
	return path
}

// header_make is a log's header for paths spelt from mount, in allocator.
header_make :: proc(mount: string, allocator := context.allocator) -> []byte {
	n := min(len(mount), int(max(u16)))
	out := make([]byte, len(MAGIC) + 2 + n, allocator)
	copy(out, MAGIC)
	endian.put_u16(out[len(MAGIC):], .Little, u16(n))
	copy(out[len(MAGIC) + 2:], mount[:n])
	return out
}

/*
header_read reads the header that begins data: the mount point the log's paths are
spelt from, borrowed from data, and how many bytes the header takes. Not ok when
data does not begin with a whole header.
*/
header_read :: proc(data: []byte) -> (mount: string, size: int, ok: bool) {
	if len(data) < len(MAGIC) + 2 || string(data[:len(MAGIC)]) != MAGIC {
		return "", 0, false
	}
	n, _ := endian.get_u16(data[len(MAGIC):], .Little)
	size = len(MAGIC) + 2 + int(n)
	if len(data) < size {
		return "", 0, false
	}
	return string(data[len(MAGIC) + 2:size]), size, true
}

// HEADER_MAX is the most bytes of a header open_log reads: MAGIC, the length, and a
// mount point of at most PATH_MAX (4096, limits.h). A log spelt from a longer mount
// point does not open, and a scan there asks each folder instead.
HEADER_MAX :: len(MAGIC) + 2 + 4096

// A log's header, as open_log reads it: the mount point its paths are spelt from,
// and the offset at which its records begin.
Log_Header :: struct {
	mount: string,
	at:    i64,
}

/*
open_log opens the log at path to read, and reads its header, the mount point in
allocator, and how many whole records follow it. Not ok, and f nil, when the log
cannot be opened or does not begin with a whole header. The caller closes f.
*/
open_log :: proc(
	path: string,
	allocator := context.temp_allocator,
) -> (
	f: ^os.File,
	header: Log_Header,
	count: i64,
	ok: bool,
) {
	open_err: os.Error
	f, open_err = os.open(path)
	if open_err != nil {
		return nil, {}, 0, false
	}
	head: [HEADER_MAX]byte
	n, _ := os.read_at(f, head[:], 0)
	mount, at, header_ok := header_read(head[:max(n, 0)])
	size, size_err := os.file_size(f)
	if !header_ok || size_err != nil {
		os.close(f)
		return nil, {}, 0, false
	}
	header = {strings.clone(mount, allocator), i64(at)}
	return f, header, (size - i64(at)) / RECORD_SIZE, true
}

// record_put writes r into the first RECORD_SIZE bytes of buf.
record_put :: proc(buf: []byte, r: Record) {
	buf[0] = u8(r.kind)
	endian.put_i64(buf[1:], .Little, r.time)
	endian.put_u64(buf[9:], .Little, r.hash)
}

// record_get reads the record in the first RECORD_SIZE bytes of buf. Not ok when
// buf is shorter than a record: a short buffer is refused rather than read off its end.
record_get :: proc(buf: []byte) -> (r: Record, ok: bool) {
	if len(buf) < RECORD_SIZE {
		return {}, false
	}
	t, _ := endian.get_i64(buf[1:], .Little)
	h, _ := endian.get_u64(buf[9:], .Little)
	return {kind = Kind(buf[0]), time = t, hash = h}, true
}

/*
What a log says of a window of time it covers: the mount point its paths are spelt
from, when the window ends, the last record's time, and the hashes of the
directories that changed in it.
*/
Window :: struct {
	mount:  string,
	end:    i64,
	hashes: map[u64]struct{},
}

window_destroy :: proc(w: ^Window) {
	delete(w.mount, w.hashes.allocator)
	delete(w.hashes)
	w^ = {}
}

/*
window reads the log at path for what changed from `from` to `to`, ns since the
epoch. why is "" when the log covers that window, and otherwise says in words why
it does not; w is then empty. A record cut short at the end, as a write the
machine stopped in the middle of leaves, is not read.
*/
window :: proc(
	path: string,
	from, to: i64,
	allocator := context.allocator,
) -> (
	w: Window,
	why: string,
) {
	f, head, count, ok := open_log(path)
	if !ok && !os.exists(path) {
		return {}, "no changes are recorded for this filesystem"
	}
	if !ok {
		return {}, "the record of changes cannot be read"
	}
	defer os.close(f)
	first := last_at_or_before(f, head.at, count, from)
	if first < 0 {
		return {}, "changes were not recorded when the place was last read"
	}
	body := make([]byte, (count - first) * RECORD_SIZE, context.temp_allocator)
	if !read_full(f, body, head.at + first * RECORD_SIZE) {
		return {}, "the record of changes cannot be read"
	}
	records := make([]Record, count - first, context.temp_allocator)
	for &r, i in records {
		got: bool
		r, got = record_get(body[i * RECORD_SIZE:])
		if !got {
			return {}, "the record of changes cannot be read"
		}
	}
	end, gap := cover(records, from, to)
	if gap != "" {
		return {}, gap
	}
	w.mount = strings.clone(head.mount, allocator)
	w.end = end
	w.hashes = make(map[u64]struct{}, allocator)
	for r in records {
		if r.time > end {
			break
		}
		if r.kind == .Changed && r.time >= from {
			w.hashes[r.hash] = {}
		}
	}
	return w, ""
}

// read_full fills buf from f at offset, and says whether it could.
@(private)
read_full :: proc(f: ^os.File, buf: []byte, offset: i64) -> bool {
	done := 0
	for done < len(buf) {
		n, err := os.read_at(f, buf[done:], offset + i64(done))
		if n <= 0 || (err != nil && err != .EOF) {
			return false
		}
		done += n
	}
	return true
}

/*
last_at_or_before is the index of the last of the count records from offset `at`
whose time is at or before t, found by halving, or -1 when the first is after it.
Records are appended in time order.
*/
@(private)
last_at_or_before :: proc(f: ^os.File, at, count, t: i64) -> i64 {
	lo, hi := i64(0), count - 1
	found := i64(-1)
	buf: [RECORD_SIZE]byte
	for lo <= hi {
		mid := lo + (hi - lo) / 2
		if !read_full(f, buf[:], at + mid * RECORD_SIZE) {
			return -1
		}
		rec, got := record_get(buf[:])
		if !got {
			return -1
		}
		if rec.time <= t {
			found = mid
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return found
}

/*
cover says whether records, beginning with the last at or before `from`, show the
recorder recording from `from` to `to` without a break, and when the record of it
ends: the last record's time at or before `to`. why is "" when they do, and says
why not otherwise. Records after `to` belong to a later window.
*/
cover :: proc(records: []Record, from, to: i64) -> (end: i64, why: string) {
	if len(records) == 0 || records[0].time > from {
		return 0, "changes were not recorded when the place was last read"
	}
	prev := records[0]
	if prev.kind == .Stop {
		return 0, "the recorder was stopped when the place was last read"
	}
	most := 2 * i64(HEARTBEAT)
	for r in records[1:] {
		if r.time > to {
			break
		}
		switch {
		case r.time < prev.time:
			return 0, "the clock went back while changes were recorded"
		case r.time - prev.time > most && !(r.kind == .Slept && slept_from(r) <= prev.time):
			return 0, "the recorder missed a heartbeat"
		}
		#partial switch r.kind {
		case .Start:
			return 0, "the recorder started again since the place was last read"
		case .Stop:
			return 0, "the recorder stopped since the place was last read"
		case .Overflow:
			return 0, "the recorder fell behind and lost changes"
		}
		prev = r
	}
	if to - prev.time > most {
		return 0, "the recorder is not running"
	}
	return prev.time, ""
}

/*
slept_from is when the recorder last wrote before the machine went to sleep, by a
Slept record: the time of the last record it appended to the log before. From then
until the machine slept the recorder was running, and what it heard in that time is
recorded after the Slept: that rests on the assumption, untested, that fanotify's
queue outlasts a suspend as its marks do (the package's doc). A Slept that carries a
later time than the record before it in the log says a record the recorder appended
is missing, and its gap is not covered.
*/
slept_from :: proc(r: Record) -> i64 {
	return i64(r.hash)
}

/*
compact rewrites the log at path without its records from before `before`, ns
since the epoch: a new file beside it, renamed over it. A record cut short at the
end is dropped with them.
*/
compact :: proc(path: string, before: i64) -> (dropped: int, err: os.Error) {
	data := os.read_entire_file(path, context.temp_allocator) or_return
	_, at, ok := header_read(data)
	if !ok {
		return 0, .Invalid_File
	}
	out := make([dynamic]byte, 0, len(data), context.temp_allocator)
	append(&out, ..data[:at])
	for i := at; i + RECORD_SIZE <= len(data); i += RECORD_SIZE {
		rec, got := record_get(data[i:])
		if !got {
			break
		}
		if rec.time < before {
			dropped += 1
			continue
		}
		append(&out, ..data[i:i + RECORD_SIZE])
	}
	fresh := fmt.tprintf("%s.new", path)
	os.write_entire_file(fresh, out[:], Permissions_Log) or_return
	if rename_err := os.rename(fresh, path); rename_err != nil {
		os.remove(fresh)
		return 0, rename_err
	}
	return dropped, nil
}

// Permissions_Log is a log's mode, 0644: anyone may read which hashes changed.
Permissions_Log :: os.Permissions_Read_All + {.Write_User}
