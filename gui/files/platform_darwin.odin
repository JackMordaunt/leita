#+build darwin
package sonar_files

import "base:intrinsics"

import "core:c"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import "core:sys/posix"

foreign import libc "system:System"

SEPARATOR  :: "/"
SEPARATORS :: "/"

@(private = "file")
RENAME_EXCL :: 0x00000004

@(private = "file")
MAXPATHLEN :: 1024

// Stat_FS is struct statfs from <sys/mount.h> as __DARWIN_STRUCT_STATFS64 lays it
// out, which is what the statfs symbol takes on arm64 and statfs$INODE64 on x86_64.
// statvfs is not used: core:sys/posix declares its block counts c.uint on Darwin,
// too few blocks for a large volume.
@(private = "file")
Stat_FS :: struct {
	bsize:       u32,
	iosize:      i32,
	blocks:      u64,
	bfree:       u64,
	bavail:      u64,
	files:       u64,
	ffree:       u64,
	fsid:        [2]i32,
	owner:       u32,
	type:        u32,
	flags:       u32,
	fssubtype:   u32,
	fstypename:  [16]u8,
	mntonname:   [MAXPATHLEN]u8,
	mntfromname: [MAXPATHLEN]u8,
	flags_ext:   u32,
	reserved:    [7]u32,
}
#assert(size_of(Stat_FS) == 2168)

when ODIN_ARCH == .amd64 {
	@(private = "file")
	STATFS :: "statfs$INODE64"
} else {
	@(private = "file")
	STATFS :: "statfs"
}

@(private = "file", default_calling_convention = "c")
foreign libc {
	renamex_np :: proc(from, to: cstring, flags: c.uint) -> c.int ---
	@(link_name = STATFS)
	statfs :: proc(path: cstring, buf: ^Stat_FS) -> c.int ---
}

@(private = "file", objc_class = "NSFileManager")
File_Manager :: struct {
	using _: NS.Object,
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

// space is the size of the filesystem holding path and what of it is free to
// this user: statfs's available blocks, as df shows, not those kept for root.
space :: proc(path: string) -> (total, free: u64, ok: bool) {
	st: Stat_FS
	if statfs(strings.clone_to_cstring(path, context.temp_allocator), &st) != 0 {
		return 0, 0, false
	}
	unit := u64(st.bsize)
	return st.blocks * unit, st.bavail * unit, true
}
