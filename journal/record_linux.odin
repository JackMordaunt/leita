#+build linux
package journal

import "base:intrinsics"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

// fanotify(7)'s values (include/uapi/linux/fanotify.h), which core:sys/linux lacks.
@(private = "file")
FAN_CLASS_NOTIF :: 0x0
@(private = "file")
FAN_CLOEXEC :: 0x1
@(private = "file")
FAN_NONBLOCK :: 0x2
@(private = "file")
FAN_REPORT_FID :: 0x200
@(private = "file")
FAN_REPORT_DIR_FID :: 0x400
@(private = "file")
FAN_REPORT_NAME :: 0x800
@(private = "file")
FAN_MARK_ADD :: 0x1
@(private = "file")
FAN_MARK_REMOVE :: 0x2
@(private = "file")
FAN_MARK_FILESYSTEM :: 0x100
@(private = "file")
FAN_MODIFY :: u64(0x2)
@(private = "file")
FAN_ATTRIB :: u64(0x4)
@(private = "file")
FAN_CLOSE_WRITE :: u64(0x8)
@(private = "file")
FAN_MOVED_FROM :: u64(0x40)
@(private = "file")
FAN_MOVED_TO :: u64(0x80)
@(private = "file")
FAN_CREATE :: u64(0x100)
@(private = "file")
FAN_DELETE :: u64(0x200)
@(private = "file")
FAN_Q_OVERFLOW :: u64(0x4000)
@(private = "file")
FAN_ONDIR :: u64(0x40000000)
@(private = "file")
FAN_EVENT_INFO_TYPE_FID :: 1
@(private = "file")
FAN_EVENT_INFO_TYPE_DFID_NAME :: 2
@(private = "file")
FAN_EVENT_INFO_TYPE_DFID :: 3

/*
MASK is what the recorder asks to hear of: every change to what a directory holds,
a file's contents and its attributes. A write through mmap sent no FAN_MODIFY on
ext4 under Linux 7.0.14 (2026-10-13); FAN_CLOSE_WRITE caught it when the file was
closed. FAN_Q_OVERFLOW is not asked for: fanotify_mark refused a mask holding it
with EINVAL on the same kernel, and fanotify(7) has the kernel queue it whatever
the mask.
*/
@(private = "file")
MASK ::
	FAN_CREATE |
	FAN_DELETE |
	FAN_MOVED_FROM |
	FAN_MOVED_TO |
	FAN_MODIFY |
	FAN_CLOSE_WRITE |
	FAN_ATTRIB |
	FAN_ONDIR

// The layout of struct fanotify_event_metadata.
@(private = "file")
Event_Metadata :: struct {
	event_len:    u32,
	vers:         u8,
	reserved:     u8,
	metadata_len: u16,
	mask:         u64,
	fd:           i32,
	pid:          i32,
}

// How often pending directories are resolved and recorded.
@(private = "file")
FLUSH_EVERY :: time.Second

// How long the recorder waits for an event before looking at the clock.
@(private = "file")
WAIT_MS :: 250

/*
When the loop last looked at the clock, by the wall clock and by CLOCK_MONOTONIC,
which stops while the machine is suspended (clock_gettime(2)); ns.
*/
@(private = "file")
Clocks :: struct {
	real: i64,
	mono: i64,
}

@(private = "file")
clocks_now :: proc() -> Clocks {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return {time.to_unix_nanoseconds(time.now()), i64(ts.time_sec) * 1e9 + i64(ts.time_nsec)}
}

// How often the recorder drops records older than RETENTION.
@(private = "file")
COMPACT_EVERY :: 24 * time.Hour

/*
What the recorder is to do: write its logs in `logs`, mark only the filesystems
mounted at the points in `only` when it names any (a test's), and stop once `stop`
is set.
*/
Config :: struct {
	logs: string,
	only: []string,
	stop: ^bool,
}

/*
A filesystem the recorder records, and the log it writes. Its mount point is not
kept open: while the recorder held it open, `umount /mnt/e` failed with "target is
busy" (EBUSY) on Linux 7.0.14 (2026-10-13), so a recorded disk could not be ejected.
flush opens it only for as long as it resolves handles.
*/
@(private)
Recorded_Filesystem :: struct {
	mount_id: int,
	device:   string,
	point:    string,
	fstype:   string,
	fsid:     [2]i32,
	log:      ^os.File,
	path:     string,
	buf:      [dynamic]byte, // records to append at the next write
	end:      i64, // where the log's last whole record ends
	broken:   bool, // a write lost records and its Overflow too: see write_log
}

// Log_Writer appends data to a log, as os.write does; a test gives one that fails.
@(private)
Log_Writer :: #type proc(f: ^os.File, data: []byte) -> (n: int, err: os.Error)

@(private)
Recorder :: struct {
	cfg:       Config,
	write:     Log_Writer,
	fan:       linux.Fd,
	mountinfo: linux.Fd,
	own:       u64, // the log folder's hash: its own writes are not recorded
	recorded:  [dynamic]Recorded_Filesystem,
	verdicts:  Verdicts,
	pending:   map[string]struct{}, // fsid and file handle of each directory heard of
	events:    []byte,
}

/*
run records changes until cfg.stop is set, then writes a Stop to every log. It
returns "" once stopped, or why it could not start, in the caller's temp allocator:
fanotify needs root, or CAP_SYS_ADMIN and CAP_DAC_READ_SEARCH (fanotify_init(2),
open_by_handle_at(2)).
*/
run :: proc(cfg: Config) -> (problem: string) {
	// A run lasts as long as the machine is up: what each pass makes in the temp
	// allocator is let go at the end of it, in an arena of the run's own, so the
	// caller's temporaries stay its own.
	said := context.temp_allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return "no memory to record changes with"
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)

	r := Recorder {
		cfg    = cfg,
		write  = os.write,
		events = make([]byte, 256 * 1024),
	}
	defer recorder_destroy(&r)
	perm := os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}
	if err := os.make_directory_all(cfg.logs, perm); err != nil && err != .Exist {
		return fmt.aprintf("cannot make %s: %v", cfg.logs, err, allocator = said)
	}
	if own, ok := canonical(cfg.logs, context.temp_allocator); ok {
		r.own = hash_path(own)
	}
	fan := intrinsics.syscall(
		linux.SYS_fanotify_init,
		uintptr(
			FAN_CLASS_NOTIF |
			FAN_CLOEXEC |
			FAN_NONBLOCK |
			FAN_REPORT_FID |
			FAN_REPORT_DIR_FID |
			FAN_REPORT_NAME,
		),
		0,
	)
	if errno := linux.Errno(-int(fan)); int(fan) < 0 {
		return fmt.aprintf("fanotify_init: %v (it needs root)", errno, allocator = said)
	}
	r.fan = linux.Fd(fan)
	info, info_err := linux.open("/proc/self/mountinfo", {.CLOEXEC})
	if info_err != .NONE {
		return fmt.aprintf("cannot open /proc/self/mountinfo: %v", info_err, allocator = said)
	}
	r.mountinfo = info
	// With nothing to record yet it runs all the same, for a filesystem mounted
	// later; the status says why each was not recorded.
	sync_mounts(&r)
	loop(&r)
	for &fs in r.recorded {
		stop_recording(&r, &fs)
	}
	write_status(&r)
	return ""
}

// loop reads events until told to stop: resolving each second, a heartbeat each
// HEARTBEAT, a compaction each day, and the mounts again whenever they change.
@(private = "file")
loop :: proc(r: ^Recorder) {
	last_flush, last_beat, last_compact := time.now(), time.now(), time.now()
	looked := clocks_now()
	for !sync.atomic_load(r.cfg.stop) {
		fds := [2]linux.Poll_Fd{{fd = r.fan, events = {.IN}}, {fd = r.mountinfo, events = {.PRI}}}
		n, _ := linux.poll(fds[:], WAIT_MS)
		// Before anything is written: the Slept record must end the gap it explains.
		clocks := clocks_now()
		if (clocks.real - looked.real) - (clocks.mono - looked.mono) > i64(HEARTBEAT) {
			mark_all(r, .Slept, u64(looked.real))
		}
		looked = clocks
		if n > 0 && .IN in fds[0].revents {
			read_events(r)
		}
		if n > 0 && fds[1].revents & {.PRI, .ERR} != {} {
			flush(r)
			sync_mounts(r)
		}
		now := time.now()
		if time.diff(last_flush, now) >= FLUSH_EVERY {
			flush(r)
			last_flush = now
		}
		if time.diff(last_beat, now) >= HEARTBEAT {
			flush(r)
			mark_all(r, .Heartbeat)
			last_beat = now
		}
		if time.diff(last_compact, now) >= COMPACT_EVERY {
			for &fs in r.recorded {
				compact_log(&fs)
			}
			last_compact = now
		}
		free_all(context.temp_allocator)
	}
	read_events(r)
	flush(r)
}

@(private)
recorder_destroy :: proc(r: ^Recorder) {
	for &fs in r.recorded {
		forget(&fs)
	}
	delete(r.recorded)
	verdicts_destroy(&r.verdicts)
	for k in r.pending {
		delete(k)
	}
	delete(r.pending)
	delete(r.events)
	if r.fan > 0 {
		linux.close(r.fan)
	}
	if r.mountinfo > 0 {
		linux.close(r.mountinfo)
	}
}

@(private)
forget :: proc(fs: ^Recorded_Filesystem) {
	if fs.log != nil {
		os.close(fs.log)
	}
	delete(fs.device)
	delete(fs.point)
	delete(fs.fstype)
	delete(fs.path)
	delete(fs.buf)
	fs^ = {}
}

/*
read_events reads what the kernel has queued, keeping each directory an event
names once: its parent's handle for an entry made, gone, moved or changed, and a
directory's own handle for a change to its attributes.
*/
@(private = "file")
read_events :: proc(r: ^Recorder) {
	// The descriptor does not block: a read with nothing queued, or one a signal
	// cut short, returns, and the loop polls again.
	for {
		n, err := linux.read(r.fan, r.events)
		if err != .NONE || n <= 0 {
			return
		}
		at := 0
		for at + size_of(Event_Metadata) <= n {
			md := (^Event_Metadata)(&r.events[at])
			if md.event_len < size_of(Event_Metadata) || at + int(md.event_len) > n {
				break
			}
			take_event(r, r.events[at:at + int(md.event_len)], md)
			at += int(md.event_len)
		}
		// One read drains a queue that fits the buffer; poll says if more came.
		if n < len(r.events) / 2 {
			return
		}
	}
}

@(private = "file")
take_event :: proc(r: ^Recorder, event: []byte, md: ^Event_Metadata) {
	if md.mask & FAN_Q_OVERFLOW != 0 {
		flush(r)
		mark_all(r, .Overflow)
		return
	}
	at := int(md.metadata_len)
	for at + 4 <= len(event) {
		kind := event[at]
		size := int(u16(event[at + 2]) | u16(event[at + 3]) << 8)
		if size < 4 || at + size > len(event) {
			return
		}
		info := event[at:at + size]
		at += size
		dir := kind == FAN_EVENT_INFO_TYPE_DFID_NAME || kind == FAN_EVENT_INFO_TYPE_DFID
		own := kind == FAN_EVENT_INFO_TYPE_FID && md.mask & FAN_ONDIR != 0
		if !(dir || own) || len(info) < 4 + 8 + 8 {
			continue
		}
		// struct fanotify_event_info_fid (include/uapi/linux/fanotify.h): the
		// 4-byte header, the 8-byte fsid, then struct file_handle
		// (open_by_handle_at(2)), whose first u32 is how many bytes of handle
		// follow its 8-byte head.
		hbytes := int(
			u32(info[12]) | u32(info[13]) << 8 | u32(info[14]) << 16 | u32(info[15]) << 24,
		)
		end := 12 + 8 + hbytes
		if end > len(info) {
			continue
		}
		key := string(info[4:end])
		if key not_in r.pending {
			r.pending[strings.clone(key)] = {}
		}
	}
}

/*
flush resolves each directory heard of since the last flush once, through its
filesystem's mount point, and appends a Changed record of its path's hash to that
filesystem's log. A directory gone since is not recorded: its parent was, when it
went. A filesystem whose mount point cannot be opened, or holds another filesystem
now, is let go as an unmounted one is, and the mounts are judged again.
*/
@(private = "file")
flush :: proc(r: ^Recorder) {
	now := time.to_unix_nanoseconds(time.now())
	dropped := false
	for i := len(r.recorded) - 1; i >= 0; i -= 1 {
		fs := &r.recorded[i]
		if !resolve(r, fs, now) {
			drop(r, i)
			dropped = true
			continue
		}
		write_log(r, fs)
	}
	for key in r.pending {
		delete(key)
	}
	clear(&r.pending)
	if dropped {
		sync_mounts(r)
	}
}

/*
resolve appends a Changed record to fs's log for each pending directory of it. It
opens fs's mount point only when one is pending, and closes it before returning. An
unmount while it is open still fails with EBUSY, for as long as resolving one
second's directories takes. It is false when the mount point cannot be opened or
holds another filesystem.
*/
@(private = "file")
resolve :: proc(r: ^Recorder, fs: ^Recorded_Filesystem, now: i64) -> bool {
	id := transmute([8]byte)fs.fsid
	dir := linux.Fd(-1)
	defer if dir >= 0 {
		linux.close(dir)
	}
	for key in r.pending {
		if key[:8] != string(id[:]) {
			continue
		}
		if dir < 0 {
			fsid: [2]i32
			err: linux.Errno
			dir, fsid, err = open_point(fs.point)
			if err != .NONE || fsid != fs.fsid {
				return false
			}
		}
		fd := intrinsics.syscall(
			linux.SYS_open_by_handle_at,
			uintptr(dir),
			uintptr(raw_data(key[8:])),
			uintptr(transmute(u32)linux.Open_Flags{.PATH, .CLOEXEC}),
		)
		if int(fd) < 0 {
			continue
		}
		path, ok := fd_path(linux.Fd(fd), context.temp_allocator)
		linux.close(linux.Fd(fd))
		if !ok || strings.has_suffix(path, " (deleted)") {
			continue
		}
		if h := hash_path(path); h != r.own {
			append_record(fs, {.Changed, now, h})
		}
	}
	return true
}

/*
open_point opens the mount point at point to resolve handles through, and says
which filesystem it holds. The descriptor is -1 when err is not .NONE. It is not
O_PATH: through an O_PATH descriptor open_by_handle_at resolved no handle on Linux
7.0.14 (2026-10-13), and the log held no Changed record.
*/
@(private = "file")
open_point :: proc(point: string) -> (dir: linux.Fd, fsid: [2]i32, err: linux.Errno) {
	dir, err = linux.open(
		strings.clone_to_cstring(point, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	if err != .NONE {
		return -1, {}, err
	}
	st: linux.Stat_FS
	if err = linux.fstatfs(dir, &st); err != .NONE {
		linux.close(dir)
		return -1, {}, err
	}
	return dir, st.fsid, .NONE
}

// drop stops recording r.recorded[i] and forgets it, so its device is judged again.
@(private = "file")
drop :: proc(r: ^Recorder, i: int) {
	fs := &r.recorded[i]
	stop_recording(r, fs)
	verdicts_forget(&r.verdicts, fs.device)
	forget(fs)
	ordered_remove(&r.recorded, i)
}

/*
mark_all appends a record of kind, carrying hash, to every log, and writes it. A
broken log is begun again with a Start instead, which breaks every window across it
as the record would have.
*/
@(private)
mark_all :: proc(r: ^Recorder, kind: Kind, hash := u64(0)) {
	now := time.to_unix_nanoseconds(time.now())
	for &fs in r.recorded {
		if fs.broken {
			restart_log(r, &fs, now)
			continue
		}
		append_record(&fs, {kind, now, hash})
		write_log(r, &fs)
	}
}

@(private)
append_record :: proc(fs: ^Recorded_Filesystem, rec: Record) {
	// record_put writes RECORD_SIZE bytes and does not check the length. This
	// buffer is that long, so the write stays inside it.
	buf: [RECORD_SIZE]byte
	record_put(buf[:], rec)
	append(&fs.buf, ..buf[:])
}

/*
write_log appends fs's buffered records to its log. A log that takes only part of
them, as a full volume does, is cut back to its last whole record, and an Overflow
follows the records not written, so no window across the loss is covered. When even
that cannot be written the log is broken: what it would have held is let go, and
nothing more is written until a Start begins it again (mark_all). Until then no
heartbeat follows its last record, and cover soon says the recorder is not running.
*/
@(private)
write_log :: proc(r: ^Recorder, fs: ^Recorded_Filesystem) {
	if fs.broken {
		clear(&fs.buf)
		return
	}
	if len(fs.buf) == 0 || fs.log == nil {
		return
	}
	if put_records(r, fs) {
		return
	}
	append_record(fs, {.Overflow, time.to_unix_nanoseconds(time.now()), 0})
	if !fs.broken && put_records(r, fs) {
		return
	}
	fs.broken = true
	clear(&fs.buf)
}

/*
put_records writes fs's buffer to its log and says whether all of it went. What was
written is taken off the buffer and the rest kept. Part of a record written is cut
off the log, since every record appended after it would be read askew; the log is
broken when it cannot be cut.
*/
@(private = "file")
put_records :: proc(r: ^Recorder, fs: ^Recorded_Filesystem) -> bool {
	n, err := r.write(fs.log, fs.buf[:])
	done := clamp(n, 0, len(fs.buf)) / RECORD_SIZE * RECORD_SIZE
	fs.end += i64(done)
	remove_range(&fs.buf, 0, done)
	if err == nil && len(fs.buf) == 0 {
		return true
	}
	if os.truncate(fs.log, fs.end) != nil {
		fs.broken = true
	}
	return false
}

/*
restart_log begins fs's broken log again with a Start at now, once it can be cut
back to its last whole record. What was lost while it was broken is in no window a
scan trusts: each across the Start is refused.
*/
@(private = "file")
restart_log :: proc(r: ^Recorder, fs: ^Recorded_Filesystem, now: i64) {
	if fs.log == nil || os.truncate(fs.log, fs.end) != nil {
		return
	}
	fs.broken = false
	clear(&fs.buf)
	append_record(fs, {.Start, now, generation()})
	write_log(r, fs)
}

// generation is a random hash for a Start, which tells one run's log from the next.
@(private = "file")
generation :: proc() -> u64 {
	gen: [8]byte
	linux.getrandom(gen[:], {})
	return transmute(u64)gen
}

/*
sync_mounts reads the mounts again: a filesystem recorded whose mount is gone gets
a Stop, since what happens to it unmounted is not seen, and its device is judged
again; what else has gone or changed is judged again too (verdicts_prune). Each
mount not judged before is marked if it can be.
*/
@(private = "file")
sync_mounts :: proc(r: ^Recorder) {
	text := read_mountinfo(r.mountinfo)
	mounts := mounts_parse(text, context.temp_allocator)
	for i := len(r.recorded) - 1; i >= 0; i -= 1 {
		fs := &r.recorded[i]
		if _, here := mount_by_id(mounts, fs.mount_id); !here {
			drop(r, i)
		}
	}
	devices := make([dynamic]string, context.temp_allocator)
	for fs in r.recorded {
		append(&devices, fs.device)
	}
	verdicts_prune(&r.verdicts, mounts, devices[:])
	for m in mounts {
		if !verdicts_try(&r.verdicts, m) {
			continue
		}
		if len(r.cfg.only) > 0 && !listed(r.cfg.only, m.point) {
			continue
		}
		try_mount(r, m, mounts)
	}
	write_status(r)
}

// read_mountinfo is the whole of /proc/self/mountinfo, read from its start through
// fd, which then waits for the next change; in the temp allocator.
@(private = "file")
read_mountinfo :: proc(fd: linux.Fd) -> string {
	out := make([dynamic]byte, context.temp_allocator)
	buf: [16 * 1024]byte
	at := i64(0)
	for {
		n, err := linux.pread(fd, buf[:], at)
		if err != .NONE || n <= 0 {
			break
		}
		append(&out, ..buf[:n])
		at += i64(n)
	}
	return string(out[:])
}

/*
try_mount marks the filesystem mounted at m, unless it is not one to record, was
recorded or skipped already through another mount, or has a mount of its whole
elsewhere that is tried instead. A mount of one folder of a filesystem is not
recorded: the recorder could not spell paths outside that folder. Each filesystem
is listed in the status once, by the first mount of it tried.
*/
@(private = "file")
try_mount :: proc(r: ^Recorder, m: Mount, mounts: []Mount) {
	try, why := judge(m)
	if !try {
		if why != "" {
			verdicts_skip(&r.verdicts, m, why)
		}
		return
	}
	if m.device in r.verdicts.devices {
		return
	}
	if m.root != "/" {
		for other in mounts {
			if other.device == m.device && other.root == "/" {
				return
			}
		}
	}
	point := strings.clone_to_cstring(m.point, context.temp_allocator)
	if errno := fan_mark(r.fan, FAN_MARK_ADD | FAN_MARK_FILESYSTEM, point); errno != .NONE {
		verdicts_skip(&r.verdicts, m, mark_problem(m, errno))
		return
	}
	if m.root != "/" {
		fan_mark(r.fan, FAN_MARK_REMOVE | FAN_MARK_FILESYSTEM, point)
		verdicts_skip(&r.verdicts, m, "only one folder of it is mounted")
		return
	}
	fs, problem := start_recording(r, m)
	if problem != "" {
		fan_mark(r.fan, FAN_MARK_REMOVE | FAN_MARK_FILESYSTEM, point)
		verdicts_skip(&r.verdicts, m, problem)
		return
	}
	verdicts_record(&r.verdicts, m)
	append(&r.recorded, fs)
}

@(private = "file")
fan_mark :: proc(fan: linux.Fd, flags: uint, path: cstring) -> linux.Errno {
	when size_of(uintptr) == 8 {
		ret := intrinsics.syscall(
			linux.SYS_fanotify_mark,
			uintptr(fan),
			uintptr(flags),
			uintptr(MASK),
			transmute(uintptr)int(linux.AT_FDCWD),
			uintptr(rawptr(path)),
		)
	} else {
		ret := intrinsics.syscall(
			linux.SYS_fanotify_mark,
			uintptr(fan),
			uintptr(flags),
			uintptr(MASK & 0xffff_ffff),
			uintptr(MASK >> 32),
			transmute(uintptr)int(linux.AT_FDCWD),
			uintptr(rawptr(path)),
		)
	}
	if int(ret) < 0 {
		return linux.Errno(-int(ret))
	}
	return .NONE
}

// mark_problem says why a filesystem could not be marked, for the status.
@(private = "file")
mark_problem :: proc(m: Mount, errno: linux.Errno) -> string {
	#partial switch errno {
	case .EXDEV:
		if m.fstype == "btrfs" {
			return "a btrfs subvolume, which fanotify cannot mark whole (EXDEV); not recorded yet"
		}
		return "fanotify cannot mark it whole (EXDEV)"
	case .ENODEV, .EOPNOTSUPP:
		return "it cannot say which folder changed"
	}
	return fmt.tprintf("fanotify_mark: %v", errno)
}

/*
start_recording opens the log of the filesystem mounted at m, marked already, and
appends a Start with a new generation. A log whose paths were spelt from another
mount point is begun again: its hashes would not match this one's.
*/
@(private = "file")
start_recording :: proc(r: ^Recorder, m: Mount) -> (fs: Recorded_Filesystem, problem: string) {
	dir, fsid, err := open_point(m.point)
	if err != .NONE {
		return {}, fmt.tprintf("cannot open it: %v", err)
	}
	linux.close(dir)
	fs = Recorded_Filesystem {
		mount_id = m.id,
		device   = strings.clone(m.device),
		point    = strings.clone(m.point),
		fstype   = strings.clone(m.fstype),
		fsid     = fsid,
	}
	fs.path, _ = filepath.join({r.cfg.logs, log_name(fsid)})
	if !ensure_header(&fs) {
		forget(&fs)
		return {}, "its log cannot be written"
	}
	compact_log(&fs)
	if fs.log == nil {
		forget(&fs)
		return {}, "its log cannot be written"
	}
	append_record(&fs, {.Start, time.to_unix_nanoseconds(time.now()), generation()})
	write_log(r, &fs)
	return fs, ""
}

/*
ensure_header makes sure fs's log begins with a header for its mount point: written
anew when there is none, or when it names another.
*/
@(private)
ensure_header :: proc(fs: ^Recorded_Filesystem) -> bool {
	if f, head, _, ok := open_log(fs.path); ok {
		os.close(f)
		if head.mount == fs.point {
			return true
		}
	}
	return(
		os.write_entire_file(
			fs.path,
			header_make(fs.point, context.temp_allocator),
			Permissions_Log,
		) ==
		nil \
	)
}

/*
compact_log drops fs's records older than RETENTION, then opens its log to append,
cut back to its last whole record: one torn by a write the machine stopped in the
middle of would leave every record appended after it read askew.
*/
@(private)
compact_log :: proc(fs: ^Recorded_Filesystem) {
	if fs.log != nil {
		os.close(fs.log)
		fs.log = nil
	}
	before := time.to_unix_nanoseconds(time.now()) - i64(RETENTION)
	compact(fs.path, before)
	f, head, count, ok := open_log(fs.path)
	if !ok {
		return
	}
	os.close(f)
	fs.end = head.at + count * RECORD_SIZE
	log, err := os.open(fs.path, {.Write, .Append}, Permissions_Log)
	if err != nil {
		return
	}
	if os.truncate(log, fs.end) != nil {
		os.close(log)
		return
	}
	fs.log = log
}

// stop_recording appends a Stop to fs's log: what happens next is not seen.
@(private = "file")
stop_recording :: proc(r: ^Recorder, fs: ^Recorded_Filesystem) {
	append_record(fs, {.Stop, time.to_unix_nanoseconds(time.now()), 0})
	write_log(r, fs)
}

// STATUS is the file in the log folder that says what is recorded and what not.
STATUS :: "status"

/*
write_status writes which filesystems are recorded, and which are not and why, to
STATUS in the log folder: a line each, tab-separated, "recorded", the mount point,
the type and the log's name, or "skipped", the mount point, the type and why.
*/
@(private = "file")
write_status :: proc(r: ^Recorder) {
	b := strings.builder_make(context.temp_allocator)
	for fs in r.recorded {
		fmt.sbprintf(&b, "recorded\t%s\t%s\t%s\n", fs.point, fs.fstype, filepath.base(fs.path))
	}
	for s in r.verdicts.skipped {
		fmt.sbprintf(&b, "skipped\t%s\t%s\t%s\n", s.point, s.fstype, s.why)
	}
	path, _ := filepath.join({r.cfg.logs, STATUS}, context.temp_allocator)
	fresh := fmt.tprintf("%s.new", path)
	if os.write_entire_file(fresh, strings.to_string(b), Permissions_Log) == nil {
		os.rename(fresh, path)
	}
}
