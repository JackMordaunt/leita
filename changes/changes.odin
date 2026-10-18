/*
Package changes asks the operating system what changed in a place since a cursor: the
seam an incremental scan stands on.

A full scan of a place takes a cursor first, with `now`. A later scan of the same
place hands that cursor to `since`, which answers with the directories that changed
and a new cursor, or says the place must be scanned whole and why. Every cursor is
taken before anything is read, so a change that lands while a scan runs is reported
again next time rather than lost: reading a directory twice costs a little, missing
one makes the scan wrong.

Where the answer comes from depends on the platform, and nothing above this package
needs to know which:

- Windows reads the volume's USN change journal (NTFS and ReFS), through the
  unprivileged read Windows 10 1709 added (changes_windows.odin says what that
  needs, and what is not yet shown).
- macOS replays the volume's FSEvents history from an event id (changes_darwin.odin).
- Linux has no journal that outlives a listener. Where leita's own recorder runs
  (package journal, installed only on request) its log names the directories that
  changed, by a hash of each path; elsewhere the answer is a probe: the update asks
  every directory whether it changed since the cursor's time (changes_linux.odin).

An answer is never stale without saying so: whatever leaves a cursor unusable, a
journal that wrapped or was recreated, another volume mounted in the place, history
lost, comes back as `rescan` with the reason, and the caller scans the place whole.
*/
package changes

import "core:time"

// Where a cursor came from, so a cursor of one kind is never read as another.
Source :: enum u8 {
	None, // no cursor: nothing is known about what changed
	Usn, // Windows' change journal
	Fsevents, // macOS' event history
	Probe, // Linux: a time to compare directories' stamps with
}

/*
How far a place's changes have been read. Plain data, so it can be kept beside the
tree it belongs to and read back on another run.
*/
Cursor :: struct {
	source:   Source,
	// What the place was on: Windows' volume serial number, the FSEvents store's
	// UUID, or on Linux the device number and the filesystem's id. Another one
	// means another volume, or the same partition made anew.
	volume:   [2]u64,
	// Which directory the place was: its inode and birth time on Linux, its file id
	// on Windows. Another one means another tree was put where the place was read.
	place:    [2]u64,
	journal:  u64, // Windows: which journal; a new one has another id
	position: i64, // the journal's next USN, the next event id, or the time in ns
	full:     i64, // when the place was last scanned whole, in ns since the epoch
	updates:  u64, // how many updates since then, which walk.Update.turn follows
}

/*
What changed in a place since a cursor.

`shallow` are directories whose own entries changed: each is read again, and what
under it did not change is kept. `deep` are directories under which anything may
have changed, read again whole. With `probe`, there was no journal to ask, and every
directory is to be asked whether it changed at or after `since`, ns since the epoch.
With `by_hash`, leita's recorder named the directories that changed by a hash of each
one's path (package journal): each directory of the place whose path, `root` then
names joined by slashes, hashes to one in `hashes` is read again, as if shallow.
Paths are the place's own spelling of them: the place as given, then names joined by
the platform's separator.
*/
Change_Set :: struct {
	rescan:  bool,
	//review:ignore odin-destroy-incomplete why is always a string constant
	why:     string, // why the place must be scanned whole; a constant, never freed
	shallow: [dynamic]string,
	deep:    [dynamic]string,
	probe:   bool,
	since:   i64,
	by_hash: bool,
	root:    string, // the place as the recorder spells it, for by_hash
	hashes:  map[u64]struct{},
}

change_set_destroy :: proc(c: ^Change_Set) {
	for p in c.shallow {
		delete(p, c.shallow.allocator)
	}
	for p in c.deep {
		delete(p, c.deep.allocator)
	}
	delete(c.root, c.shallow.allocator)
	delete(c.shallow)
	delete(c.deep)
	delete(c.hashes)
	c^ = {}
}

Error :: enum {
	None,
	Out_Of_Memory,
}

// A place that cannot be updated, and why, as `since` answers it.
@(private)
rescan :: proc(why: string) -> Change_Set {
	return {rescan = true, why = why}
}

@(private)
now_ns :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now())
}

/*
Whether `path` is `place` or under it, comparing as the platform's paths compare:
letters folded on Windows and macOS, whose filesystems ignore case by default.
Separators both ways on Windows.
*/
under :: proc(place, path: string) -> (rest: string, ok: bool) {
	trimmed := place
	for len(trimmed) > 1 && is_separator(trimmed[len(trimmed) - 1]) {
		trimmed = trimmed[:len(trimmed) - 1]
	}
	if len(path) < len(trimmed) || !same_text(path[:len(trimmed)], trimmed) {
		return "", false
	}
	rest = path[len(trimmed):]
	if rest == "" {
		return "", true
	}
	if !is_separator(rest[0]) && !is_separator(trimmed[len(trimmed) - 1]) {
		return "", false
	}
	for len(rest) > 0 && is_separator(rest[0]) {
		rest = rest[1:]
	}
	return rest, true
}

@(private)
is_separator :: proc(c: byte) -> bool {
	when ODIN_OS == .Windows {
		return c == '\\' || c == '/'
	} else {
		return c == '/'
	}
}

@(private)
same_text :: proc(a, b: string) -> bool {
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		if len(a) != len(b) {
			return false
		}
		for i in 0 ..< len(a) {
			x, y := a[i], b[i]
			if 'A' <= x && x <= 'Z' {
				x += 'a' - 'A'
			}
			if 'A' <= y && y <= 'Z' {
				y += 'a' - 'A'
			}
			if x != y {
				return false
			}
		}
		return true
	} else {
		return a == b
	}
}
