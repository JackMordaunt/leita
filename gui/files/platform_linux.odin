#+build linux
package estoile_files

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

SEPARATOR  :: "/"
SEPARATORS :: "/"

@(private = "file")
RENAME_NOREPLACE :: 1

// rename_noreplace renames from to to, failing with Exists rather than replacing
// whatever is at to: renameat2's RENAME_NOREPLACE makes the check and the rename one
// step, so nothing can slip in between.
rename_noreplace :: proc(from, to: string) -> Error {
	f := strings.clone_to_cstring(from, context.temp_allocator)
	t := strings.clone_to_cstring(to, context.temp_allocator)
	ret := linux.syscall(
		linux.SYS_renameat2,
		linux.AT_FDCWD,
		rawptr(f),
		linux.AT_FDCWD,
		rawptr(t),
		uintptr(RENAME_NOREPLACE),
	)
	if ret < 0 {
		return errno_error(i32(-ret))
	}
	return .None
}

/*
trash moves path to the home Trash of the freedesktop.org Trash specification: the
entry under files/, and a .trashinfo under info/ saying where it came from, so the
desktop's Trash can put it back. The info file is made first and exclusively, so two
trashes never take one name. An entry on another filesystem than the home Trash is
refused with Cross_Device: the specification's per-volume Trash folders are not
supported, and copying a tree across to the home one is not a move.
*/
trash :: proc(path: string) -> Error {
	root := trash_root()
	files_dir, _ := filepath.join({root, "files"}, context.temp_allocator)
	info_dir, _ := filepath.join({root, "info"}, context.temp_allocator)
	_ = os.make_directory_all(files_dir)
	_ = os.make_directory_all(info_dir)
	base := filepath.base(path)
	for n := 1; n < 10_000; n += 1 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		name := base if n == 1 else fmt.tprintf("%s.%d", base, n)
		info_path, _ := filepath.join(
			{info_dir, strings.concatenate({name, ".trashinfo"}, context.temp_allocator)},
			context.temp_allocator,
		)
		f, ferr := os.open(info_path, {.Write, .Create, .Excl})
		if ferr != nil {
			if os.exists(info_path) {
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
		_, werr := os.write(f, transmute([]u8)body)
		os.close(f)
		err := Error.Other
		if werr == nil {
			target, _ := filepath.join({files_dir, name}, context.temp_allocator)
			err = rename_noreplace(path, target)
			if err == .None {
				return .None
			}
		}
		_ = os.remove(info_path)
		return err
	}
	return .Exists
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

// space is the size of the filesystem holding path and what of it is free to
// this user: statfs's available blocks, as df shows, not those kept for root.
space :: proc(path: string) -> (total, free: u64, ok: bool) {
	st: linux.Stat_FS
	if linux.statfs(strings.clone_to_cstring(path, context.temp_allocator), &st) != .NONE {
		return 0, 0, false
	}
	unit := u64(st.frsize if st.frsize > 0 else st.bsize)
	return u64(st.blocks) * unit, u64(st.bavail) * unit, true
}
