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
// snapshots. Names say nothing about retained bytes. Purgeable space is what
// macOS itself estimates it can free on demand (darwin_purgeable); when the
// system gives no figure it stays unknown.
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
	purgeable, known := darwin_purgeable(string(cstring(&st.mntonname[0])))
	scan.note_retention(t, {snapshots = state, purgeable = purgeable, purgeable_known = known})
}

/*
darwin_purgeable is the space macOS expects to clear on the volume at root by
purging. CFURL.h in the macOS 11.3 SDK defines the important-usage capacity as
"Total available capacity in bytes for "Important" resources, including space
expected to be cleared by purging non-essential and cached resources", and the
plain capacity as "Total free space in bytes"; the gap between the two is that
purge. Both keys are available through CoreFoundation on the macOS 11 floor,
but a resource value can be unavailable, and the two reads are not atomic.

It is the system's estimate, not a measurement of any file; the walk never
charges it to one. No figure, a figure that is not a positive-or-zero 64-bit
number, or an important-usage capacity below the plain one (the two disagree,
or space was taken between the reads) is unknown, never 0.
*/
@(private)
darwin_purgeable :: proc(root: string) -> (purgeable: u64, known: bool) {
	url := CFURLCreateFromFileSystemRepresentation(nil, raw_data(root), len(root), true)
	if url == nil {
		return
	}
	defer CFRelease(url)

	available := cf_url_i64(url, kCFURLVolumeAvailableCapacityKey) or_return
	important := cf_url_i64(url, kCFURLVolumeAvailableCapacityForImportantUsageKey) or_return
	return darwin_purgeable_capacity(available, important)
}

// Separate capacity samples may disagree while another process writes to
// the volume. Unknown must not become a wrapped byte count or a known zero.
@(private)
darwin_purgeable_capacity :: proc(available, important: i64) -> (purgeable: u64, known: bool) {
	if available < 0 || important < available {
		return
	}
	return u64(important - available), true
}

// cf_url_i64 is url's numeric resource value for key, false when there is none.
@(private = "file")
cf_url_i64 :: proc(url: rawptr, key: rawptr) -> (n: i64, ok: bool) {
	value: rawptr
	if !CFURLCopyResourcePropertyForKey(url, key, &value, nil) || value == nil {
		return
	}
	defer CFRelease(value)

	if CFGetTypeID(value) != CFNumberGetTypeID() {
		return
	}
	if !CFNumberGetValue(value, CF_NUMBER_SINT64, &n) {
		return
	}
	return n, true
}

// kCFNumberSInt64Type in <CoreFoundation/CFNumber.h>.
@(private = "file")
CF_NUMBER_SINT64 :: 4

foreign import core_foundation "system:CoreFoundation.framework"

// <CoreFoundation/CFURL.h>: the important-usage key is API_AVAILABLE(macos(10.13)),
// the plain capacity key API_AVAILABLE(macos(10.6)).
@(private = "file", default_calling_convention = "c")
foreign core_foundation {
	kCFURLVolumeAvailableCapacityKey:                  rawptr
	kCFURLVolumeAvailableCapacityForImportantUsageKey: rawptr
	CFURLCreateFromFileSystemRepresentation :: proc(allocator: rawptr, path: [^]u8, length: int, directory: b8) -> rawptr ---
	CFURLCopyResourcePropertyForKey         :: proc(url: rawptr, key: rawptr, value: ^rawptr, err: ^rawptr) -> b8 ---
	CFGetTypeID                             :: proc(cf: rawptr) -> uint ---
	CFNumberGetTypeID                       :: proc() -> uint ---
	CFNumberGetValue                        :: proc(number: rawptr, type: int, value: rawptr) -> b8 ---
	CFRelease                               :: proc(cf: rawptr) ---
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
