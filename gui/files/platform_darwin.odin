#+build darwin
package leita_files

import "base:intrinsics"
import "base:runtime"

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import "core:sys/posix"

import "../../scan"

foreign import libc "system:System"

SEPARATOR  :: "/"
SEPARATORS :: "/"

@(private = "file")
RENAME_EXCL :: 0x00000004

@(private = "file", objc_class = "NSFileManager")
File_Manager :: struct {
	using _: NS.Object,
}

@(private = "file", default_calling_convention = "c")
foreign libc {
	renameatx_np :: proc(from_dir: posix.FD, from: cstring, to_dir: posix.FD, to: cstring, flags: c.uint) -> c.int ---
	@(link_name = FSTATFS)
	fstatfs :: proc(fd: posix.FD, buf: ^scan.Stat_FS) -> c.int ---
}

// fstatfs takes struct statfs as scan.Stat_FS lays it out, statfs64's: the fstatfs
// symbol on arm64, fstatfs$INODE64 on x86_64.
when ODIN_ARCH == .amd64 {
	@(private = "file")
	FSTATFS :: "fstatfs$INODE64"
} else {
	@(private = "file")
	FSTATFS :: "fstatfs"
}

/*
fchmod_nofollow changes the mode of name in dir without following a symbolic link.
AT_SYMLINK_NOFOLLOW is that refusal. If the call fails, the caller leaves the
directory unopened: there is no fallback that follows a link.
*/
@(private)
fchmod_nofollow :: proc(dir: posix.FD, name: cstring, mode: posix.mode_t) -> bool {
	return posix.fchmodat(dir, name, mode, {.SYMLINK_NOFOLLOW}) == .OK
}

// open_dir_at opens the directory name in parent, close on exec and, unless follow
// is set, without following a link.
@(private)
open_dir_at :: proc(parent: posix.FD, name: cstring, follow := false) -> (fd: posix.FD, err: posix.Errno) {
	flags: posix.O_Flags = {.DIRECTORY, .CLOEXEC} if follow else {.DIRECTORY, .NOFOLLOW, .CLOEXEC}
	fd = posix.openat(parent, name, flags)
	if fd == -1 {
		err = posix.errno()
	}
	return
}

/*
rename_noreplace renames from to to, failing with Exists rather than replacing
whatever is at to. Each folder is opened without following a link (open_directory),
and renameatx_np(2)'s RENAME_EXCL does the check and the rename as one step inside
those descriptors. A symbolic link in either folder's path is Not_Directory.
*/
rename_noreplace :: proc(from, to: string) -> Error {
	from_dir, from_name := filepath.split(from)
	to_dir, to_name := filepath.split(to)
	// A name is at most NAME_MAX, 255 bytes, so each buffer holds one and its NUL.
	f, t: [256]u8
	if !plain_name(from_name) || !plain_name(to_name) || len(from_name) >= len(f) || len(to_name) >= len(t) {
		return .Bad_Name
	}
	copy(f[:], from_name)
	copy(t[:], to_name)

	from_fd, ferr := open_directory(from_dir)
	if ferr != .None {
		return ferr
	}
	defer posix.close(from_fd)

	to_fd, terr := open_directory(to_dir)
	if terr != .None {
		return terr
	}
	defer posix.close(to_fd)

	if renameatx_np(from_fd, cstring(&f[0]), to_fd, cstring(&t[0]), RENAME_EXCL) != 0 {
		return errno_error(posix.errno())
	}
	return .None
}

// plain_name is whether name names an entry in a folder, not the folder itself.
@(private = "file")
plain_name :: proc(name: string) -> bool {
	return name != "" && name != "." && name != ".." && !strings.contains_rune(name, '/')
}

// trash moves path to the Trash, where the Finder keeps it.
trash :: proc(path: string) -> Error {
	_, err := trash_to(path, context.temp_allocator)
	return err
}

/*
trash_to is trash, saying where in the Trash the entry went, which need not be
under its old name.

The folder holding path is opened without following a link (open_directory), so a
path reaching the entry through a symbolic link is Not_Directory. A folder swapped
for a link after that check must not redirect the move either, so the move never
looks the folder up by its path again:

  - NSFileManager moves it, as the Finder does, and records where it came from for
    Put Back. It is given the entry under /.vol/<device>/<folder's inode>, which the
    kernel resolves by the folder's id, not its path: the entry that leaves is the
    one in the folder that was checked, wherever that folder is by then, and Put
    Back names where that is (seen on macos-latest, CI run 40183550843).
  - On a volume without those ids (/.vol does not reach the folder: FAT, exFAT,
    most network filesystems), the entry is renamed out of the folder's descriptor
    into the Trash by rename_to_trash. That keeps no Put Back record.
*/
@(private)
trash_to :: proc(path: string, allocator := context.allocator) -> (to: string, err: Error) {
	dir, name := filepath.split(path)
	// A name is at most NAME_MAX, 255 bytes, so this buffer holds one and its NUL.
	from: [256]u8
	if !plain_name(name) {
		return "", .Not_Directory
	}
	if len(name) >= len(from) {
		return "", .Bad_Name
	}
	copy(from[:], name)

	parent, perr := open_directory(dir)
	if perr != .None {
		return "", perr
	}
	defer posix.close(parent)

	if before_trash != nil {
		before_trash(path)
	}

	st: posix.stat_t
	if posix.fstatat(parent, cstring(&from[0]), &st, {.SYMLINK_NOFOLLOW}) != .OK {
		return "", errno_error(posix.errno())
	}

	if by_id, ok := volfs_path(parent, name); ok {
		return trash_item(by_id, allocator)
	}
	return rename_to_trash(parent, name, u64(st.st_dev), allocator)
}

/*
volfs_path is the entry name of the folder open as parent, named under /.vol by the
folder's device and inode, so the name reaches that folder whatever is done to its
path. ok is false when /.vol does not reach that very folder on this volume.
*/
@(private = "file")
volfs_path :: proc(
	parent: posix.FD,
	name: string,
	allocator := context.temp_allocator,
) -> (
	path: string,
	ok: bool,
) {
	dir: posix.stat_t
	if posix.fstat(parent, &dir) != .OK {
		return "", false
	}

	folder := fmt.tprintf("/.vol/%d/%d", u64(dir.st_dev), u64(dir.st_ino))
	seen: posix.stat_t
	cfolder := strings.clone_to_cstring(folder, context.temp_allocator)
	if posix.lstat(cfolder, &seen) != .OK || seen.st_dev != dir.st_dev || seen.st_ino != dir.st_ino {
		return "", false
	}
	return strings.concatenate({folder, "/", name}, allocator), true
}

// trash_item moves path to the Trash through NSFileManager, saying where it went.
@(private = "file")
trash_item :: proc(path: string, allocator: runtime.Allocator) -> (to: string, err: Error) {
	NS.scoped_autoreleasepool()
	str := NS.String.alloc()->initWithOdinString(path)
	defer str->release()
	url := NS.URL.alloc()->initFileURLWithPath(str)
	defer url->release()

	fm := intrinsics.objc_send(^File_Manager, File_Manager, "defaultManager")
	landed: ^NS.URL
	failure: ^NS.Error
	ok := intrinsics.objc_send(
		NS.BOOL,
		fm,
		"trashItemAtURL:resultingItemURL:error:",
		url,
		&landed,
		&failure,
	)

	switch {
	case ok && landed != nil:
		return strings.clone_from_cstring(landed->fileSystemRepresentation(), allocator), .None
	case ok:
		return "", .None
	case failure == nil:
		return "", .Other
	}
	return "", cocoa_error(failure->code())
}

// cocoa_error maps the NSCocoaErrorDomain codes NSFileManager reports.
@(private = "file")
cocoa_error :: proc(code: NS.Integer) -> Error {
	switch code {
	case 4, 260:
		// NSFileNoSuchFileError, NSFileReadNoSuchFileError
		return .Missing
	case 257, 513:
		// NSFileReadNoPermissionError, NSFileWriteNoPermissionError
		return .Denied
	case 516:
		// NSFileWriteFileExistsError
		return .Exists
	case 3328:
		// NSFeatureUnsupportedError: the volume has no Trash
		return .Unsupported
	}
	return .Other
}

/*
rename_to_trash moves the entry name out of the folder open as parent, on device,
into the Trash where the Finder looks: ~/.Trash when it is on the home folder's
volume, otherwise the volume's .Trashes/<uid> (trash_folder). renameatx_np(2) renames
it out of the descriptor, so what leaves is the entry in that folder.
RENAME_EXCL keeps whatever already has the name in the Trash; the entry then takes
"name 2.ext", "name 3.ext" and so on.
*/
@(private)
rename_to_trash :: proc(
	parent: posix.FD,
	name: string,
	device: u64,
	allocator := context.allocator,
) -> (
	to: string,
	err: Error,
) {
	from: [256]u8
	if len(name) >= len(from) {
		return "", .Bad_Name
	}
	copy(from[:], name)

	bin, bin_fd, berr := trash_folder(parent, device)
	if berr != .None {
		return "", berr
	}
	defer if bin_fd != posix.AT_FDCWD {
		posix.close(bin_fd)
	}

	for n := 1; n < 10_000; n += 1 {
		// What one try takes is let go before the next, unless it is the answer's.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
		landed := trash_name(name, n)
		if len(landed) >= len(from) {
			break
		}
		whole := strings.concatenate({bin, "/", landed}, context.temp_allocator)
		// By name inside the Trash's descriptor, or by its whole path when it has none.
		target := strings.clone_to_cstring(whole if bin_fd == posix.AT_FDCWD else landed, context.temp_allocator)
		if renameatx_np(parent, cstring(&from[0]), bin_fd, target, RENAME_EXCL) == 0 {
			return strings.clone(whole, allocator), .None
		}
		if e := posix.errno(); e != .EEXIST {
			return "", errno_error(e)
		}
	}
	return "", .Exists
}

/*
trash_folder is the Trash for an entry on device: its path, and its descriptor
opened without following a link, or AT_FDCWD to rename by that path.

~/.Trash, made if missing, serves the home folder's volume. Should opening it be
Denied (a privacy setting that guards the Trash's listing could; CI runners have not
shown it), the entry is renamed into it by path, after a look shows it is a
directory on the same volume and not a link. Only the folder the entry leaves is
held by descriptor then: the Trash is the user's own, and a link put in its place would take the entry
somewhere else of theirs, not reach anything else.

Another volume's Trash is <mount>/.Trashes/<uid>, as the Finder makes it: .Trashes
sticky and writable by all, the user's folder in it 0700 and theirs. A folder there
that some other user made is refused as Not_Yours, so it cannot catch what is
trashed. A volume with no Trash and no way to make one is Unsupported.
*/
@(private = "file")
trash_folder :: proc(
	parent: posix.FD,
	device: u64,
	allocator := context.temp_allocator,
) -> (
	bin: string,
	fd: posix.FD,
	err: Error,
) {
	if home := os.get_env("HOME", context.temp_allocator); home != "" {
		bin = strings.concatenate({home, "/.Trash"}, allocator)
		cbin := strings.clone_to_cstring(bin, context.temp_allocator)
		fd, err = open_directory(bin)
		if err == .Missing && posix.mkdir(cbin, {.IRUSR, .IWUSR, .IXUSR}) == .OK {
			fd, err = open_directory(bin)
		}
		#partial switch err {
		case .None:
			if at, lerr := look_self(fd); lerr == .NONE && at.device == device {
				return bin, fd, .None
			}
			posix.close(fd)
		case .Denied:
			st: posix.stat_t
			if posix.lstat(cbin, &st) == .OK && posix.S_ISDIR(st.st_mode) && u64(st.st_dev) == device {
				return bin, posix.AT_FDCWD, .None
			}
		}
	}

	fs: scan.Stat_FS
	if fstatfs(parent, &fs) != 0 {
		return "", -1, .Unsupported
	}
	mount := string(cstring(&fs.mntonname[0]))
	trashes := strings.concatenate({strings.trim_right(mount, "/"), "/.Trashes"}, context.temp_allocator)
	vol, verr := open_directory(trashes)
	if verr == .Missing {
		// Sticky, and writable and searchable by all, as the Finder leaves it.
		ctrashes := strings.clone_to_cstring(trashes, context.temp_allocator)
		mode: posix.mode_t = {.IRUSR, .IWUSR, .IXUSR, .IWGRP, .IXGRP, .IWOTH, .IXOTH, .ISVXT}
		if posix.mkdir(ctrashes, mode) == .OK {
			_ = posix.chmod(ctrashes, mode)
		}
		vol, verr = open_directory(trashes)
	}
	if verr != .None {
		return "", -1, .Unsupported
	}
	defer posix.close(vol)

	uid := posix.getuid()
	mine := fmt.tprintf("%d", uid)
	cmine := strings.clone_to_cstring(mine, context.temp_allocator)
	_ = posix.mkdirat(vol, cmine, {.IRUSR, .IWUSR, .IXUSR})
	ofd, oerr := open_dir_at(vol, cmine)
	if ofd == -1 {
		return "", -1, .Not_Directory if oerr == .ELOOP || oerr == .ENOTDIR else .Unsupported
	}
	st: posix.stat_t
	switch {
	case posix.fstat(ofd, &st) != .OK:
		posix.close(ofd)
		return "", -1, .Unsupported
	case st.st_uid != uid:
		posix.close(ofd)
		return "", -1, .Not_Yours
	case u64(st.st_dev) != device:
		posix.close(ofd)
		return "", -1, .Cross_Device
	}
	return strings.concatenate({trashes, "/", mine}, allocator), ofd, .None
}

// trash_name is the nth name tried for name in the Trash: name itself first, then
// "name 2.ext", keeping an extension after the number.
@(private = "file")
trash_name :: proc(name: string, n: int, allocator := context.temp_allocator) -> string {
	if n == 1 {
		return name
	}
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		return fmt.aprintf("%s %d%s", name[:dot], n, name[dot:], allocator = allocator)
	}
	return fmt.aprintf("%s %d", name, n, allocator = allocator)
}

// reveal asks the Finder to show path selected.
@(private)
reveal :: proc(path: string) {
	run({"open", "-R", path})
}

@(private = "file")
errno_error :: proc(errno: posix.Errno) -> Error {
	#partial switch errno {
	case .EEXIST, .ENOTEMPTY:
		return .Exists
	case .ENOENT:
		return .Missing
	case .EACCES, .EPERM:
		return .Denied
	case .EXDEV:
		return .Cross_Device
	case .ENOTSUP, .EINVAL:
		return .Unsupported
	}
	return .Other
}

// documents is ~/Documents, where the Finder keeps them; "" when there is no
// home to find it in.
@(private)
documents :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	return strings.concatenate({home, "/Documents"}, allocator)
}

// look is what the entry name in the directory dir is, not following a link.
@(private)
look :: proc(dir: posix.FD, name: cstring) -> (Look, posix.Errno) {
	st: posix.stat_t
	if posix.fstatat(dir, name, &st, {.SYMLINK_NOFOLLOW}) != .OK {
		return {}, posix.errno()
	}
	return look_of(st), .NONE
}

// look_self is what the directory open as fd is.
@(private)
look_self :: proc(fd: posix.FD) -> (Look, posix.Errno) {
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		return {}, posix.errno()
	}
	return look_of(st), .NONE
}

/*
look_of is st as a Look. lstat gives no mount id, so a mount at a folder is told by
its device alone: this assumes whatever is mounted there reports a device of its
own, which has not been checked on a Mac. A nullfs mount (mount_nullfs(8)) of the
same volume may keep the device and not be seen here. The walk does see one (DIR_MNTSTATUS_MNTPOINT in
walk/read_darwin.odin), so Reclaim never offers it, but one inside a candidate
would be entered.
*/
@(private = "file")
look_of :: proc(st: posix.stat_t) -> Look {
	return Look {
		directory = posix.S_ISDIR(st.st_mode),
		regular = posix.S_ISREG(st.st_mode),
		device = u64(st.st_dev),
		inode = u64(st.st_ino),
		links = u64(st.st_nlink),
		disk = u64(st.st_blocks) * 512,
		mode = st.st_mode - posix.S_IFMT,
	}
}

// mount_points is none: macOS keeps its mount table in the kernel (getmntinfo(3)),
// not a file, and look_of says what a device alone can tell.
@(private)
mount_points :: proc(path: string) -> map[[2]u64]struct{} {
	return make(map[[2]u64]struct{}, context.temp_allocator)
}
