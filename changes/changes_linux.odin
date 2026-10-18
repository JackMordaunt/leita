#+build linux
package changes

import "core:strings"
import "core:sys/linux"
import "core:time"

import "../journal"

/*
Linux keeps no history of changes that a run started later can read. fanotify
reports a whole filesystem's changes, directory and name, but only to a listener
that is running when they happen, and a filesystem mark needs CAP_SYS_ADMIN
(fanotify_init(2), fanotify_mark(2)); inotify needs no privilege but a watch per
directory, and also reports only while it runs (inotify(7)). A scheduled run that is not
resident between runs has nothing to ask of the system, so the cursor is the time the
place was last read, and the answer comes from one of two places.

Where leita's recorder runs (package journal: `leita journal on`, root, off until
asked) and its log covers the whole time since the cursor, the log names the
directories that changed, and only those are read again. Otherwise, with no
recorder, a filesystem whose mark failed (a btrfs subvolume, under Linux 7.0.14:
package journal), or a break in its log, the answer is a probe: the update asks each
directory whether it changed since (walk.Update.probe). The cursor is the same either
way, so a baseline kept with one serves the other.

SLACK is taken off that time, for a filesystem that stamps coarsely (FAT keeps
two-second times) or a clock that read a little ahead of the one stamping.

A probe cannot see a file written in place in a directory that did not change. The
update asks such a directory's large files their sizes each time and its small ones a
slice at a time (walk.Update); STALE_AFTER bounds how long any other drift can build
up before the place is scanned whole again.
*/
SLACK       :: 2 * time.Second
STALE_AFTER :: 7 * 24 * time.Hour

// A cursor for `place` as it is now, to take before scanning it whole.
now :: proc(place: string) -> (c: Cursor, ok: bool) {
	volume, dir, found := identity_of(place)
	if !found {
		return {}, false
	}
	at := now_ns()
	return {source = .Probe, volume = volume, place = dir, position = at, full = at}, true
}

/*
What to read again in `place` since `c`: the directories the recorder's log says
changed, when it covers the time since, or else a probe; or a rescan when the place
is on another device or filesystem than it was, is another directory, the clock went
back, or the last whole scan is older than STALE_AFTER. The new cursor carries the
last whole scan's time on.
*/
since :: proc(
	place: string,
	c: Cursor,
	allocator := context.allocator,
) -> (
	changed: Change_Set,
	next: Cursor,
	err: Error,
) {
	if c.source != .Probe {
		return rescan("no cursor was kept for this place"), {}, .None
	}
	volume, dir, found := identity_of(place)
	if !found {
		return rescan("the place could not be asked which device it is on"), {}, .None
	}
	if c.volume[0] != volume[0] {
		return rescan("the place is on another device than when it was read"), {}, .None
	}
	if c.volume[1] != volume[1] {
		return rescan("the place's filesystem was made anew since it was read"), {}, .None
	}
	if c.place != dir {
		return rescan("another directory is in the place than when it was read"), {}, .None
	}
	at := now_ns()
	if at < c.position {
		return rescan("the clock reads earlier than when the place was read"), {}, .None
	}
	if at - c.full > i64(STALE_AFTER) {
		return rescan("the place was last scanned whole over 7 days ago"), {}, .None
	}
	next = c
	if set, end, ok := recorded(place, c.position - i64(SLACK), at, allocator); ok {
		next.position = end
		return set, next, .None
	}
	next.position = at
	changed = Change_Set {
		probe   = true,
		since   = c.position - i64(SLACK),
		shallow = make([dynamic]string, allocator),
		deep    = make([dynamic]string, allocator),
	}
	return changed, next, .None
}

/*
recorded is what the recorder's log says changed in `place` from `from` to `to`, ns
since the epoch, when it covers that time without a break: the hashes of the
directories that changed, and when the log's record of the time ends, which is where
the next window begins. Not ok when there is no log for the place's filesystem, it
does not cover the time, or it spells paths from another mount point than the one
the place is on. That must be the same point, not one above it: a header damaged to
name "/" would otherwise speak for every place on the machine.
*/
@(private = "file")
recorded :: proc(
	place: string,
	from, to: i64,
	allocator := context.allocator,
) -> (
	set: Change_Set,
	end: i64,
	ok: bool,
) {
	fsid := journal.fsid_of(place) or_return
	root := journal.canonical(place, allocator) or_return
	mount, mounted := journal.mount_of(root, context.temp_allocator)
	w, why := journal.window(journal.log_path(fsid), from, to, allocator)
	defer delete(w.mount, allocator)
	if why != "" || !mounted || w.mount != mount {
		delete(root, allocator)
		delete(w.hashes)
		return {}, 0, false
	}
	set = Change_Set {
		by_hash = true,
		root    = root,
		hashes  = w.hashes,
		shallow = make([dynamic]string, allocator),
		deep    = make([dynamic]string, allocator),
	}
	return set, w.end, true
}

/*
What the place is on and which directory it is. The device number names the block
device, the partition, not what mkfs writes on it; the filesystem's id from
statfs(2) is taken from the UUID mkfs writes on ext4 and btrfs (ext4_statfs,
btrfs_statfs in the kernel's fs/), but from the device number on XFS
(xfs_fs_statfs). The place's inode and birth time are the directory's own: another
directory renamed onto the place, one made anew there whose inode number was reused,
or an XFS made anew, has others. Mtimes
cannot tell: a restored tree's are older than the cursor. A filesystem that keeps no
birth time gives 0 each time.
*/
@(private = "file")
identity_of :: proc(place: string) -> (volume, dir: [2]u64, ok: bool) {
	cpath := strings.clone_to_cstring(place, context.temp_allocator)
	st: linux.Statx
	if linux.statx(linux.AT_FDCWD, cpath, {}, {.INO, .BTIME}, &st) != .NONE {
		return {}, {}, false
	}
	fsid := journal.fsid_of(place) or_return
	volume[0] = u64(st.dev_major) << 32 | u64(st.dev_minor)
	volume[1] = u64(u32(fsid[0])) << 32 | u64(u32(fsid[1]))
	dir[0] = u64(st.ino)
	if .BTIME in st.mask {
		dir[1] = u64(st.btime.sec) * 1_000_000_000 + u64(st.btime.nsec)
	}
	return volume, dir, true
}
