#+build linux
package leita_files

import "base:runtime"

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import "../../scan"

SEPARATOR  :: "/"
SEPARATORS :: "/"

@(private = "file")
RENAME_NOREPLACE :: 1

/*
rename_noreplace renames from to to, failing with Exists rather than replacing
whatever is at to. Each folder is opened without following a link (open_directory),
and renameat2's RENAME_NOREPLACE does the check and the rename as one step inside
those descriptors. A symbolic link in either path is Not_Directory.
*/
rename_noreplace :: proc(from, to: string) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	from_name := filepath.base(from)
	to_name := filepath.base(to)
	if from_name == "" ||
	   from_name == "." ||
	   from_name == ".." ||
	   to_name == "" ||
	   to_name == "." ||
	   to_name == ".." {
		return .Bad_Name
	}
	from_dir := filepath.dir(from)
	to_dir := filepath.dir(to)
	if from_dir == to_dir {
		fd, err := open_directory(from_dir)
		if err != .None {
			return err
		}
		defer posix.close(fd)
		return rename_at(fd, from_name, fd, to_name)
	}
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
	return rename_at(from_fd, from_name, to_fd, to_name)
}

// rename_at is renameat2 of from in from_dir to to in to_dir, refusing to replace.
@(private)
rename_at :: proc(from_dir: posix.FD, from: string, to_dir: posix.FD, to: string) -> Error {
	f := strings.clone_to_cstring(from, context.temp_allocator)
	t := strings.clone_to_cstring(to, context.temp_allocator)
	ret := linux.syscall(
		linux.SYS_renameat2,
		uintptr(from_dir),
		rawptr(f),
		uintptr(to_dir),
		rawptr(t),
		uintptr(RENAME_NOREPLACE),
	)
	if ret < 0 {
		return errno_error(i32(-ret))
	}
	return .None
}

/*
fchmod_nofollow changes the mode of name in dir on Linux, via fchmodat2 with
AT_SYMLINK_NOFOLLOW. If that call fails, the caller leaves the directory unopened.
There is no fallback that follows a link.
*/
@(private)
fchmod_nofollow :: proc(dir: posix.FD, name: cstring, mode: posix.mode_t) -> bool {
	flags := linux.FD_Flags{.SYMLINK_NOFOLLOW}
	ret := linux.syscall(
		linux.SYS_fchmodat2,
		uintptr(dir),
		rawptr(name),
		uintptr(transmute(u32)mode),
		uintptr(transmute(i32)flags),
	)
	return ret == 0
}

/*
trash moves path to the home Trash of the freedesktop.org Trash specification: the
entry under files/, and a .trashinfo under info/ saying where it came from, so the
desktop's Trash can put it back. The info file is made first and exclusively, so two
trashes never take one name. An entry on another filesystem than the home Trash is
refused with Cross_Device: the specification's per-volume Trash folders are not
supported, and copying a tree across to the home one is not a move.

On Linux, the source's folder and the Trash's files and info directories are opened
without following a link (open_directory, make_directory). A symbolic link in the
source path, or standing in for files or info, is Not_Directory.
*/
trash :: proc(path: string) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	base := filepath.base(path)
	if base == "" || base == "." || base == ".." || strings.contains_rune(base, '/') {
		return .Not_Directory
	}
	src, err := open_directory(filepath.dir(path))
	if err != .None {
		return err
	}
	defer posix.close(src)

	root := trash_root()
	files_dir, _ := filepath.join({root, "files"}, context.temp_allocator)
	info_dir, _ := filepath.join({root, "info"}, context.temp_allocator)
	files, ferr := make_directory(files_dir)
	if ferr != .None {
		return ferr
	}
	defer posix.close(files)
	info, ierr := make_directory(info_dir)
	if ierr != .None {
		return ierr
	}
	defer posix.close(info)

	for n := 1; n < 10_000; n += 1 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		name := base if n == 1 else fmt.tprintf("%s.%d", base, n)
		info_name := strings.concatenate({name, ".trashinfo"}, context.temp_allocator)
		cname := strings.clone_to_cstring(info_name, context.temp_allocator)
		ifd := posix.openat(
			info,
			cname,
			{.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC},
			{.IRUSR, .IWUSR},
		)
		if ifd == -1 {
			if posix.errno() == .EEXIST {
				continue
			}
			return .Denied
		}
		stamp := time.now()
		y, mo, d := time.date(stamp)
		h, mi, s := time.clock(stamp)
		body := fmt.tprintf(
			"[Trash Info]\nPath=%s\nDeletionDate=%04d-%02d-%02dT%02d:%02d:%02d\n",
			escape(path),
			y,
			int(mo),
			d,
			h,
			mi,
			s,
		)
		wrote := write_all(ifd, transmute([]byte)body)
		posix.close(ifd)
		if !wrote {
			_ = posix.unlinkat(info, cname, {})
			return .Other
		}
		moved := rename_at(src, base, files, name)
		if moved == .None {
			return .None
		}
		_ = posix.unlinkat(info, cname, {})
		if moved == .Exists {
			continue
		}
		return moved
	}
	return .Exists
}

/*
make_directory opens path as a directory on Linux, creating any missing component
as mode 0700. A symbolic link is Not_Directory and is not created through: mkdirat
is only on a descriptor opened without following a link.
*/
@(private)
make_directory :: proc(path: string) -> (fd: posix.FD, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if fd, err = open_directory(path); err != .Missing {
		return fd, err
	}
	parent := filepath.dir(path)
	name := filepath.base(path)
	if name == "" || name == "." || name == ".." || strings.contains_rune(name, '/') {
		return -1, .Not_Directory
	}
	pfd: posix.FD
	switch {
	case parent == "" || parent == ".":
		pfd, err = open_directory(".")
	case parent == path:
		return -1, .Not_Directory
	case:
		pfd, err = make_directory(parent)
	}
	if err != .None {
		return -1, err
	}
	defer posix.close(pfd)
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	if posix.mkdirat(pfd, cname, posix.S_IRWXU) != .OK && posix.errno() != .EEXIST {
		return -1, errno_error(i32(posix.errno()))
	}
	fd = posix.openat(pfd, cname, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if fd == -1 {
		if posix.errno() == .ELOOP || posix.errno() == .ENOTDIR {
			return -1, .Not_Directory
		}
		return -1, errno_error(i32(posix.errno()))
	}
	return fd, .None
}

// write_all writes the whole of body to fd, or false if a write fails.
@(private)
write_all :: proc(fd: posix.FD, body: []byte) -> bool {
	rest := body
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), c.size_t(len(rest)))
		if n <= 0 {
			return false
		}
		rest = rest[int(n):]
	}
	return true
}

// reveal asks the file manager over D-Bus to show path selected, and opens its
// folder with xdg-open when nothing answers.
@(private)
reveal :: proc(path: string) {
	uri := strings.concatenate({"file://", escape(path)}, context.temp_allocator)
	shown := run(
		{
			"dbus-send",
			"--session",
			"--print-reply",
			"--dest=org.freedesktop.FileManager1",
			"--type=method_call",
			"/org/freedesktop/FileManager1",
			"org.freedesktop.FileManager1.ShowItems",
			strings.concatenate({"array:string:", uri}, context.temp_allocator),
			"string:",
		},
	)
	if !shown {
		run({"xdg-open", filepath.dir(path)})
	}
}

@(private = "file")
trash_root :: proc() -> string {
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data == "" {
		home, _ := os.user_home_dir(context.temp_allocator)
		data, _ = filepath.join({home, ".local", "share"}, context.temp_allocator)
	}
	root, _ := filepath.join({data, "Trash"}, context.temp_allocator)
	return root
}

// escape percent-encodes a path for a .trashinfo or a file URI, keeping slashes.
@(private = "file")
escape :: proc(path: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)path {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~', '/':
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
errno_error :: proc(errno: i32) -> Error {
	#partial switch posix.Errno(errno) {
	case .EEXIST, .ENOTEMPTY:
		return .Exists
	case .ENOENT:
		return .Missing
	case .EACCES, .EPERM:
		return .Denied
	case .EXDEV:
		return .Cross_Device
	case .ENOSYS, .EINVAL:
		return .Unsupported
	}
	return .Other
}

// documents is the user's Documents folder as xdg-user-dirs names it in
// user-dirs.dirs (XDG_DOCUMENTS_DIR="$HOME/Documents"), else ~/Documents; ""
// when there is no home to find it in.
@(private)
documents :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if config == "" || !filepath.is_abs(config) {
		config, _ = filepath.join({home, ".config"}, context.temp_allocator)
	}
	dirs, _ := filepath.join({config, "user-dirs.dirs"}, context.temp_allocator)
	if data, err := os.read_entire_file(dirs, context.temp_allocator); err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			KEY :: "XDG_DOCUMENTS_DIR="
			entry := strings.trim_space(line)
			if !strings.has_prefix(entry, KEY) {
				continue
			}
			value := strings.trim(entry[len(KEY):], `"`)
			if strings.has_prefix(value, "$HOME") {
				return strings.concatenate({home, value[len("$HOME"):]}, allocator)
			}
			if filepath.is_abs(value) {
				return strings.clone(value, allocator)
			}
		}
	}
	path, _ := filepath.join({home, "Documents"}, allocator)
	return path
}

// look is what the entry name in the directory dir is, not following a link nor
// mounting an automount point to ask (AT_NO_AUTOMOUNT in statx(2)).
@(private)
look :: proc(dir: posix.FD, name: cstring) -> (Look, posix.Errno) {
	return statx_look(linux.Fd(dir), name, {.SYMLINK_NOFOLLOW, .NO_AUTOMOUNT})
}

// look_self is what the directory open as fd is.
@(private)
look_self :: proc(fd: posix.FD) -> (Look, posix.Errno) {
	return statx_look(linux.Fd(fd), "", {.EMPTY_PATH})
}

/*
statx_look asks statx, which alone says which mount an entry is reached through
and whether one is mounted on it: a bind of a folder on the same filesystem keeps
the device, so only the mount id tells it apart. Linux 5.8 is the first to say
either; before it, the mount table must (mount_points).
*/
@(private = "file")
statx_look :: proc(
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
) -> (
	e: Look,
	err: posix.Errno,
) {
	st: linux.Statx
	mask := linux.Statx_Mask{.TYPE, .MODE, .NLINK, .INO, .BLOCKS, .MNT_ID}
	if errno := linux.statx(dir, name, flags, mask, &st); errno != .NONE {
		return {}, posix.Errno(i32(errno))
	}
	return Look {
			directory = linux.S_ISDIR(st.mode),
			regular = linux.S_ISREG(st.mode),
			device = device_of(st),
			inode = u64(st.ino),
			mount = st.mnt_id if .MNT_ID in st.mask else 0,
			mount_root = st.attributes & {.MOUNT_ROOT, .AUTOMOUNT} != {},
			links = u64(st.nlink),
			disk = st.blocks * 512,
			mode = transmute(posix.mode_t)(transmute(u32)st.mode & 0o7777),
		},
		.NONE
}

// device_of folds statx's major and minor into one number, as walk's statx_device
// does; a shift is not worth importing walk for.
@(private = "file")
device_of :: proc(st: linux.Statx) -> u64 {
	return u64(st.dev_major) << 32 | u64(st.dev_minor)
}

/*
mount_points is every mount point the mount table has at or under path, by the
device and inode of what is mounted there, which is what an entry on it is seen as.
statx's mount id already tells a bind apart where the kernel gives one, from Linux
5.8; the table is what tells one on a kernel before it.
*/
@(private)
mount_points :: proc(path: string) -> map[[2]u64]struct{} {
	points := make(map[[2]u64]struct{}, context.temp_allocator)
	buf: [4096]u8 // PATH_MAX on Linux
	real := posix.realpath(
		strings.clone_to_cstring(path, context.temp_allocator),
		raw_data(buf[:]),
	)
	if real == nil {
		return points
	}
	for point in scan.mounts_under(string(real), context.temp_allocator) {
		if len(point) >= len(buf) {
			continue
		}
		// realpath is done with buf, so it holds each point in turn, NUL ended.
		copy(buf[:], point)
		buf[len(point)] = 0
		st: linux.Statx
		// Followed, to what is mounted there; asking must not mount an automount point.
		if linux.statx(linux.AT_FDCWD, cstring(&buf[0]), {.NO_AUTOMOUNT}, {.INO}, &st) == .NONE {
			points[{device_of(st), u64(st.ino)}] = {}
		}
	}
	return points
}
