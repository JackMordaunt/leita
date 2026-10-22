#+build darwin
package leita_files

import "base:intrinsics"

import "core:c"
import "core:os"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import "core:sys/posix"

foreign import libc "system:System"

SEPARATOR  :: "/"
SEPARATORS :: "/"

@(private = "file")
RENAME_EXCL :: 0x00000004

@(private = "file", default_calling_convention = "c")
foreign libc {
	renamex_np :: proc(from, to: cstring, flags: c.uint) -> c.int ---
}

@(private = "file", objc_class = "NSFileManager")
File_Manager :: struct {
	using _: NS.Object,
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

// rename_noreplace renames from to to, failing with Exists rather than replacing
// whatever is at to: renamex_np(2)'s RENAME_EXCL makes the check and the rename one
// step, so nothing can slip in between.
rename_noreplace :: proc(from, to: string) -> Error {
	f := strings.clone_to_cstring(from, context.temp_allocator)
	t := strings.clone_to_cstring(to, context.temp_allocator)
	if renamex_np(f, t, RENAME_EXCL) != 0 {
		return errno_error(posix.errno())
	}
	return .None
}

// trash moves path to the Trash through NSFileManager, as the Finder does.
trash :: proc(path: string) -> Error {
	_, err := trash_to(path, context.temp_allocator)
	return err
}

// trash_to is trash, saying where in the Trash the entry went, which need not be
// under its old name.
@(private)
trash_to :: proc(path: string, allocator := context.allocator) -> (to: string, err: Error) {
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

// reveal asks the Finder to show path selected.
@(private)
reveal :: proc(path: string) {
	run({"open", "-R", path})
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
