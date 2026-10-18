#+build darwin
package walk

import "core:c"
import "core:mem"
import "core:strings"
import "core:sys/posix"

import "../scan"

foreign import libc "system:System"

// Ask the physical volume root, including Data when the scanned path is reached
// through a firmlink. Snapshot enumeration is read-only and includes Time Machine
// snapshots. Names say nothing about retained bytes. No public purgeable byte
// counter is assumed; the volume's purgeable measurement stays unknown.
@(private)
darwin_retention :: proc(path: string, t: ^scan.Tree) {
	st, ok := scan.stat_fs(path)
	if !ok || string(cstring(&st.fstypename[0])) != "apfs" {
		return
	}
	scan.note_snapshot_volume(t)
	names, state := darwin_snapshots(string(cstring(&st.mntonname[0])), t.allocator)
	defer {
		for name in names {
			delete(name, t.allocator)
		}
		delete(names)
	}
	if !scan.note_snapshot_names(t, names[:]) {
		state = .Unchecked
	}
	scan.note_retention(t, {snapshots = state})
}

// A complete empty enumeration means None. Any syscall, parse, allocation, or
// bound failure means Unchecked; a partial list must never assert None.
@(private)
darwin_snapshots :: proc(
	root: string,
	allocator: mem.Allocator,
) -> (
	names: [dynamic]string,
	state: scan.Snapshot_State,
) {
	path: Path
	cpath, ok := terminate(root, &path)
	if !ok {
		return
	}
	fd := posix.open(cpath, {.DIRECTORY, .CLOEXEC})
	if fd < 0 {
		return
	}
	defer posix.close(fd)
	request := Attr_List {
		bitmapcount = ATTR_BIT_MAP_COUNT,
		commonattr  = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME,
	}
	names = make([dynamic]string, allocator)
	buf: [32 * mem.Kilobyte]u8
	for {
		count := fs_snapshot_list(c.int(fd), &request, raw_data(buf[:]), len(buf), 0)
		if count < 0 {
			return
		}
		if count == 0 {
			state = .None if len(names) == 0 else .Present
			return
		}
		at := 0
		for _ in 0 ..< count {
			e, length, parsed := parse_entry(buf[at:])
			if !parsed || e.darwin.failed || len(names) >= 100_000 {
				return
			}
			at += length
			name, err := strings.clone(e.name, allocator)
			if err != nil {
				return
			}
			if _, append_err := append(&names, name); append_err != nil {
				delete(name, allocator)
				return
			}
		}
	}
}

// Public since macOS 10.12: <sys/snapshot.h>. Libc implements it through
// getattrlistbulk with FSOPT_LIST_SNAPSHOT, preserving the directory cursor.
@(private = "file", default_calling_convention = "c")
foreign libc {
	fs_snapshot_list :: proc(fd: c.int, attrs: ^Attr_List, buf: rawptr, n: uint, flags: u32) -> c.int ---
}
