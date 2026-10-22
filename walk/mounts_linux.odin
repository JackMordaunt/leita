#+build linux
package walk

import "base:runtime"
import "core:mem"
import "core:sys/linux"
import "core:sys/posix"

import "../scan"

/*
Whether a directory the walk would enter is one it is already inside or reads
elsewhere, either of which is recorded as a mount and not read, and if not, the
directories its own entries are checked against. What a bind of a tree the walk
reads elsewhere looks like is told at stops_at.

Within one mount the directories form a tree, so only a mount can lead back to a
directory above it. A bind of a directory onto one below it (mount --bind /data
/data/sub/loop) keeps the device, so the device test (stops_at) never sees it, and
a walk of /data read all of /data again at sub/loop. So a directory that is the
root of a mount (STATX_ATTR_MOUNT_ROOT, Linux 5.8; an older kernel never says, and
its binds are walked as before) is checked against every directory above it,
found by climbing from the directory listing it. If it is none of them it is
entered, and that chain is carried down with it: a mount can show a tree that
holds a directory above it without being one. The top of a btrfs pool mounted at
/mnt/pool holds @, the subvolume mounted at /, and the walk stops at /mnt/pool/@
rather than reading / again. Below the mount a directory is checked only against
the chain: within the one mount none of those between it and the mount can be it,
and the next mount down climbs again.

Kept only below a mount the walk entered, so the path almost every directory takes
asks nothing more. A scan of this machine's / enters three, the btrfs subvolumes
mounted at /home, /var/log and /var/cache/pacman/pkg (2026-10-17).
*/
@(private)
enter :: proc(
	w: ^Worker,
	dir: linux.Fd,
	above: ^Ancestor,
	st: linux.Statx,
) -> (
	mount: bool,
	below: ^Ancestor,
	ok: bool,
) {
	id := File_Id {
		device = statx_device(st),
		inode  = u64(st.ino),
	}
	mounted := .MOUNT_ROOT in st.attributes
	path := above
	// Following links, the chain already holds every directory on the way down
	// (follow_link).
	if mounted && !w.follow {
		path = climb(w, dir) or_return
	}
	if on_path(path, id) || mounted && walked_elsewhere(w, st) {
		return true, nil, true
	}
	if !mounted && !w.follow {
		return false, path, true
	}
	below = push(w, id, path) or_return
	return false, below, true
}

/*
Whether a symlink the walk was told to follow is followed, and the chain the
directory it leads to is read with.

Nothing else stopped a loop of links but the length of a path: a/to_b leading to
b and b/to_a back to a were read inside each other until the path passed what the
kernel accepts, each directory at the bottom marked unread, and every second link
in a directory doubled the reads at each level: the 13 entries of the loop test
became 426 (2026-10-18). So while following links the walk keeps every directory
on the way down, from the start's own ancestors (climb) on, and a link to one of
them is recorded as the link it is and not followed, as find -L refuses one. A
directory reached both by its name and through a link is still read at both, as
following links has always counted it. A link statx cannot follow, or that leads
to something other than a directory, is queued as before, and reading it says why
it was not read (mark_unread).
*/
@(private)
follow_link :: proc(
	w: ^Worker,
	dir: linux.Fd,
	name: cstring,
	above: ^Ancestor,
) -> (
	follow: bool,
	below: ^Ancestor,
	ok: bool,
) {
	st: linux.Statx
	errno := stat_entry(statx_compat, dir, name, {.NO_AUTOMOUNT}, {.TYPE, .INO}, &st)
	if errno != .NONE || !linux.S_ISDIR(st.mode) {
		return true, above, true
	}
	id := File_Id {
		device = statx_device(st),
		inode  = u64(st.ino),
	}
	if on_path(above, id) {
		return false, nil, true
	}
	below = push(w, id, above) or_return
	return true, below, true
}

/*
The directory open as `dir` and every directory above it, as far as the process's
root, whose ".." is itself. ".." from the root of a mount leads up out of the
mount, to the parent of the directory it is mounted on, so the climb comes back
out of every mount the walk went down through.

Bounded at CLIMB_LIMIT directories, the most a path the walk can open has room
for, so a ".." that never reaches the root still ends. A ".." that cannot be
opened ends the chain early, which leaves only what lies above it unchecked.
*/
@(private)
climb :: proc(w: ^Worker, dir: linux.Fd) -> (path: ^Ancestor, ok: bool) {
	at := dir
	defer if at != dir {
		linux.close(at)
	}
	end := &path
	last: File_Id
	for _ in 0 ..< CLIMB_LIMIT {
		st: linux.Statx
		if statx_compat(at, "", {.EMPTY_PATH}, {.INO}, &st) != .NONE {
			break
		}
		id := File_Id {
			device = statx_device(st),
			inode  = u64(st.ino),
		}
		if path != nil && id == last {
			break
		}
		end^ = push(w, id, nil) or_return
		end = &end^.up
		last = id
		up, errno := linux.openat(at, "..", {.PATH, .DIRECTORY, .CLOEXEC})
		if errno != .NONE {
			break
		}
		if at != dir {
			linux.close(at)
		}
		at = up
	}
	return path, true
}

/*
Whether this walk reads the directory at the root of the mount `st` describes
somewhere else: shown at or under the walk's start through another mount of the
same filesystem (scan.shown_elsewhere), and found there when asked, so a place
since covered by another mount, or gone, does not count. The mount table is read
only here, for a mount the walk would otherwise enter.
*/
@(private)
walked_elsewhere :: proc(w: ^Worker, st: linux.Statx) -> bool {
	if .MNT_ID not_in st.mask {
		return false
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	t := w.writer.tree
	given, real: Path
	start, start_ok := terminate(scan.name_of(t, t.root), &given)
	if !start_ok || posix.realpath(start, raw_data(real[:])) == nil {
		return false
	}
	for s in scan.shown_elsewhere(st.mnt_id, string(cstring(&real[0])), context.temp_allocator) {
		path, path_ok := terminate(s.path, &given)
		if !path_ok {
			continue
		}
		there: linux.Statx
		if statx_compat(linux.AT_FDCWD, path, {.NO_AUTOMOUNT}, {.INO, .MNT_ID}, &there) != .NONE {
			continue
		}
		if there.mnt_id == s.mount && statx_device(there) == statx_device(st) && there.ino == st.ino {
			return true
		}
	}
	return false
}

// The longest path the walk opens (Path) over the two bytes of the shortest
// directory name and its separator.
@(private)
CLIMB_LIMIT :: len(Path) / 2

// Whether `id` is one of the directories on `path`.
@(private)
on_path :: proc(path: ^Ancestor, id: File_Id) -> bool {
	for a := path; a != nil; a = a.up {
		if a.id == id {
			return true
		}
	}
	return false
}

// A chain that is `up` with `id` below it, made in this worker's arena (Scratch).
@(private)
push :: proc(w: ^Worker, id: File_Id, up: ^Ancestor) -> (a: ^Ancestor, ok: bool) {
	err: mem.Allocator_Error
	a, err = new(Ancestor, mem.dynamic_arena_allocator(&w.scratch.ancestry))
	if err != nil {
		w.err = .Out_Of_Memory
		return nil, false
	}
	a^ = {id, up}
	return a, true
}
