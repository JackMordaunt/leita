#+build linux, darwin
package leita_files

import "base:runtime"

import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

/*
Look is what the system says of an entry, not following a link: what it is, where
it lives, and what deleting it gives back.
*/
@(private)
Look :: struct {
	directory:  bool,
	regular:    bool,
	device:     u64,
	inode:      u64,
	// The id of the mount it is reached through, where the system says; else 0.
	mount:      u64,
	// The system's own word that it is the top of a mount, or an automount point.
	mount_root: bool,
	links:      u64,
	disk:       u64, // blocks in 512 byte units, whatever the filesystem builds them from
	mode:       posix.mode_t, // the permission bits alone
}

// Bounds is the mount a tree lies on, which nothing deleted may leave, and the
// mount points the mount table has under the tree, by device and inode.
@(private)
Bounds :: struct {
	device: u64,
	mount:  u64,
	points: map[[2]u64]struct{},
}

// is_link is whether path is a symbolic link, as lstat says. Reclaim asks as
// well as delete_tree, so a link to a directory is never offered.
is_link :: proc(path: string) -> bool {
	st: posix.stat_t
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return posix.lstat(cpath, &st) == .OK && posix.S_ISLNK(st.st_mode)
}

// owner is the user id that owns path, not following a link, as lstat says.
owner :: proc(path: string) -> (uid: u32, ok: bool) {
	st: posix.stat_t
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if posix.lstat(cpath, &st) != .OK {
		return 0, false
	}
	return u32(st.st_uid), true
}

/*
remove_tree deletes the directory at path and everything in it, through
descriptors: each directory is opened relative to the one holding it with
O_NOFOLLOW, and each entry unlinked through its parent's, so a name swapped for a
link while the delete runs leads nowhere. It counts what it leaves as delete_tree
does, and gives back the bytes of what it unlinked.

The tree must lie on the same mount as the folder holding it, or it is refused with
Mount_Point: a disk mounted at node_modules is another volume's. Inside, an entry on
another device or mount, or one the mount table names as a mount point (a bind of
the same filesystem keeps the device), is counted as left and not entered.
*/
@(private)
remove_tree :: proc(path: string) -> (failed: int, freed: u64, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	name := filepath.base(path)
	if name == "" || name == "." || name == ".." || strings.contains_rune(name, '/') {
		// openat ignores the folder it is given for a name that starts at /.
		return 0, 0, .Not_Directory
	}
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	holder := filepath.dir(path)
	parent := posix.open(
		strings.clone_to_cstring(holder, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	if parent == -1 {
		return 0, 0, .Missing
	}
	defer posix.close(parent)
	around, around_err := look_self(parent)
	at, at_err := look(parent, cname)
	switch {
	case around_err != .NONE || at_err != .NONE:
		return 0, 0, .Missing
	case !at.directory:
		// A link put in its place since delete_tree asked.
		return 0, 0, .Not_Directory
	}
	bounds := Bounds {
		device = around.device,
		mount  = around.mount,
		points = mount_points(path),
	}
	if crosses(&bounds, at) {
		return 0, 0, .Mount_Point
	}
	bounds.device, bounds.mount = at.device, at.mount
	failed, freed = remove_dir(parent, cname, at, &bounds)
	return failed, freed, .None
}

// crosses is whether the entry e lies outside the mount b is: on another device or
// mount, or a mount point itself.
@(private)
crosses :: proc(b: ^Bounds, e: Look) -> bool {
	switch {
	case e.device != b.device, e.mount_root:
		return true
	case b.mount != 0 && e.mount != b.mount:
		return true
	}
	return [2]u64{e.device, e.inode} in b.points
}

/*
remove_dir deletes the directory called name in the directory parent, which was
seen as at, and everything in it within b. A directory it cannot open, or that is
no longer the one seen, is counted as left. One that stays is given back its mode.
*/
@(private)
remove_dir :: proc(
	parent: posix.FD,
	name: cstring,
	at: Look,
	b: ^Bounds,
) -> (
	failed: int,
	freed: u64,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	OWNER :: posix.S_IRWXU
	changed := false
	fd := posix.openat(parent, name, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if fd == -1 && posix.errno() == .EACCES && at.mode & OWNER != OWNER {
		// Its owner cannot list it. fchmodat follows a link, but one put here
		// since the look is still never entered: the open refuses to follow it.
		changed = posix.fchmodat(parent, name, at.mode + OWNER, {}) == .OK
		fd = posix.openat(parent, name, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	}
	if fd == -1 {
		return 1, 0
	}
	defer posix.close(fd)
	self, self_err := look_self(fd)
	if self_err != .NONE || self.device != at.device || self.inode != at.inode {
		// Not the directory looked at: another was put in its place since.
		return 1, 0
	}
	if at.mode & OWNER != OWNER && !changed {
		changed = posix.fchmod(fd, at.mode + OWNER) == .OK
	}
	defer if changed && failed > 0 {
		posix.fchmod(fd, at.mode)
	}

	names, listed := list(fd)
	if !listed {
		return 1, 0
	}
	for entry in names {
		e, err := look(fd, entry)
		switch {
		case err == .ENOENT:
			// Gone since the listing, so nothing to delete.
			continue
		case err != .NONE:
			failed += 1
		case crosses(b, e):
			failed += 1
		case e.directory:
			f, gave := remove_dir(fd, entry, e, b)
			failed, freed = failed + f, freed + gave
		case posix.unlinkat(fd, entry, {}) == .OK:
			freed += held_alone(e)
		case posix.errno() != .ENOENT:
			failed += 1
		}
	}
	if failed > 0 {
		// Kept because it holds what is counted already.
		return
	}
	if posix.unlinkat(parent, name, {.REMOVEDIR}) != .OK && posix.errno() != .ENOENT {
		failed = 1
	}
	return
}

// list is the names in the directory fd, but . and .., read whole before any is
// deleted: a directory changed while it is read may skip or repeat a name.
@(private)
list :: proc(fd: posix.FD) -> (names: []cstring, ok: bool) {
	own := posix.dup(fd)
	if own == -1 {
		return nil, false
	}
	// closedir closes the descriptor it lists, and fd is still wanted after.
	dir := posix.fdopendir(own)
	if dir == nil {
		posix.close(own)
		return nil, false
	}
	defer posix.closedir(dir)
	// The names go one after another into one buffer, each ending in a NUL, and
	// are pointed at once it has stopped growing.
	text := make([dynamic]u8, context.temp_allocator)
	for {
		posix.set_errno(.NONE)
		ent := posix.readdir(dir)
		if ent == nil {
			break
		}
		name := string(cstring(&ent.d_name[0]))
		if name == "." || name == ".." {
			continue
		}
		append(&text, name)
		append(&text, 0)
	}
	if posix.errno() != .NONE {
		return nil, false
	}
	out := make([dynamic]cstring, context.temp_allocator)
	start := 0
	for c, i in text {
		if c == 0 {
			append(&out, cstring(&text[start]))
			start = i + 1
		}
	}
	return out[:], true
}

/*
held_alone is the space deleting the entry e gives back, as the scan charged it: a
regular file's blocks, and nothing for anything else, which the walk charges
nothing. A file with another name keeps its blocks until the last name goes, so it
gives back nothing until it is down to one; a tree holding both names frees them
once, as the scan charged them once.
*/
@(private)
held_alone :: proc(e: Look) -> u64 {
	return e.disk if e.regular && e.links == 1 else 0
}
