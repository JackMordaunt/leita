#+build linux
package kstat

import "base:runtime"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:time"

/*
stat of what path names, following a link, asked with fstatat.

core:os answers os.stat with statx, which is Linux 4.11: on an older kernel every
os.stat fails, so a file that is there is missing. The File_Info is os.stat's but
for the fields a program of this repository does not read.
*/
stat :: proc(path: string, allocator := context.allocator) -> (info: os.File_Info, err: os.Error) {
	return info_of(path, true, allocator)
}

// stat of path itself, a link not followed (os.lstat).
lstat :: proc(path: string, allocator := context.allocator) -> (info: os.File_Info, err: os.Error) {
	return info_of(path, false, allocator)
}

// Whether path names a regular file (os.is_file).
is_file :: proc(path: string) -> bool {
	type, ok := type_of(path)
	return ok && type == .Regular
}

// Whether path names a directory (os.is_dir).
is_dir :: proc(path: string) -> bool {
	type, ok := type_of(path)
	return ok && type == .Directory
}

// The type and mode of what path names, following a link, and no more: no path is
// built and nothing is allocated.
@(private)
type_of :: proc(path: string) -> (type: os.File_Type, ok: bool) {
	type, _, ok = type_and_mode_of(path)
	return
}

@(private)
type_and_mode_of :: proc(
	path: string,
	allocator := context.temp_allocator,
) -> (
	type: os.File_Type,
	mode: os.Permissions,
	ok: bool,
) {
	buf: [4096]u8
	if len(path) >= len(buf) {
		return .Undetermined, {}, false
	}
	copy(buf[:], path)
	when size_of(int) != 8 {
		info, err := os.stat(path, allocator)
		return info.type, info.mode, err == nil
	} else {
		st: linux.Stat
		if linux.fstatat(linux.AT_FDCWD, cstring(&buf[0]), &st, {}) != .NONE {
			return .Undetermined, {}, false
		}
		return type_from(st.mode), transmute(os.Permissions)(0o7777 & transmute(u32)st.mode), true
	}
}

// Whether path is a regular file its owner may execute.
@(private)
is_executable_file :: proc(path: string) -> bool {
	type, mode, ok := type_and_mode_of(path)
	return ok && type == .Regular && os.Permission_Flag.Execute_User in mode
}

/*
The entries of the directory path, each as lstat gives it, in the order the kernel
lists them (os.read_all_directory_by_path, which asks statx of the directory first).
An entry that vanished between the listing and its stat is left out.
*/
read_directory :: proc(path: string, allocator := context.allocator) -> (list: []os.File_Info, err: os.Error) {
	cpath, clone_err := strings.clone_to_cstring(path, context.temp_allocator)
	if clone_err != nil {
		return nil, clone_err
	}
	fd, errno := linux.open(cpath, {.DIRECTORY, .CLOEXEC})
	if errno != .NONE {
		return nil, error_of(errno)
	}
	defer linux.close(fd)
	out := make([dynamic]os.File_Info, 0, 16, allocator)
	buf := make([]u8, 4096, context.temp_allocator)
	for {
		n, got := linux.getdents(fd, buf)
		if got == .EINVAL {
			buf = make([]u8, len(buf) * 2, context.temp_allocator)
			continue
		}
		if got != .NONE {
			for info in out {
				os.file_info_delete(info, allocator)
			}
			delete(out)
			return nil, error_of(got)
		}
		if n == 0 {
			break
		}
		offset := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(d)
			if name == "." || name == ".." {
				continue
			}
			full, _ := filepath.join({path, name}, context.temp_allocator)
			if info, lerr := lstat(full, allocator); lerr == nil {
				append(&out, info)
			}
		}
	}
	return out[:], nil
}

/*
argv with its program found on PATH when it is a bare name, as the shell would.
core:os starts a bare name by asking statx of each PATH entry, so on a kernel
without it nothing is found and nothing starts; a name with a slash is not
searched. A name that is not found is left as given, for os to say so.
*/
resolve_command :: proc(argv: []string, allocator := context.temp_allocator) -> []string {
	if len(argv) == 0 || strings.contains_rune(argv[0], '/') {
		return argv
	}
	paths, has := os.lookup_env("PATH", context.temp_allocator)
	if !has {
		return argv
	}
	for dir in strings.split_iterator(&paths, ":") {
		if dir == "" {
			continue
		}
		candidate, _ := filepath.join({dir, argv[0]}, context.temp_allocator)
		if is_executable_file(candidate) {
			out := make([]string, len(argv), allocator)
			copy(out, argv)
			out[0] = strings.clone(candidate, allocator)
			return out
		}
	}
	return argv
}

@(private)
info_of :: proc(path: string, follow: bool, allocator: runtime.Allocator) -> (info: os.File_Info, err: os.Error) {
	cpath, clone_err := strings.clone_to_cstring(path, context.temp_allocator)
	if clone_err != nil {
		return {}, clone_err
	}
	when size_of(int) != 8 {
		return os.stat(path, allocator) if follow else os.lstat(path, allocator)
	} else {
		st: linux.Stat
		flags: linux.FD_Flags = {} if follow else {.SYMLINK_NOFOLLOW}
		if errno := linux.fstatat(linux.AT_FDCWD, cpath, &st, flags); errno != .NONE {
			return {}, error_of(errno)
		}
		full: string
		if follow {
			abs_err: os.Error
			if full, abs_err = os.get_absolute_path(path, allocator); abs_err != nil {
				return {}, abs_err
			}
		} else {
			full = lexical_path(path, allocator) or_return
		}
		_, name := filepath.split(full)
		info = os.File_Info {
			fullpath          = full,
			name              = name,
			inode             = u128(u64(st.ino)),
			device            = u64(st.dev),
			size              = i64(st.size),
			mode              = transmute(os.Permissions)(0o7777 & transmute(u32)st.mode),
			type              = type_from(st.mode),
			modification_time = time.Time{i64(st.mtime.time_sec) * i64(time.Second) + i64(st.mtime.time_nsec)},
			access_time       = time.Time{i64(st.atime.time_sec) * i64(time.Second) + i64(st.atime.time_nsec)},
		}
		info.creation_time = info.modification_time
		return info, nil
	}
}

// path made absolute and cleaned, its last element left as it is.
@(private)
lexical_path :: proc(path: string, allocator: runtime.Allocator) -> (string, os.Error) {
	dir, base := filepath.split(path)
	if dir == "" {
		dir = "."
	}
	abs_dir, err := os.get_absolute_path(dir, context.temp_allocator)
	if err != nil {
		return "", err
	}
	joined, _ := filepath.join({abs_dir, base}, allocator)
	return joined, nil
}

@(private)
type_from :: proc(mode: linux.Mode) -> os.File_Type {
	switch mode & linux.S_IFMT {
	case linux.S_IFBLK:
		return .Block_Device
	case linux.S_IFCHR:
		return .Character_Device
	case linux.S_IFDIR:
		return .Directory
	case linux.S_IFIFO:
		return .Named_Pipe
	case linux.S_IFLNK:
		return .Symlink
	case linux.S_IFSOCK:
		return .Socket
	}
	return .Regular
}

@(private)
error_of :: proc(errno: linux.Errno) -> os.Error {
	#partial switch errno {
	case .ENOENT:
		return os.General_Error.Not_Exist
	case .EACCES, .EPERM:
		return io.Error.Permission_Denied
	case .EEXIST:
		return os.General_Error.Exist
	case .ENOTDIR:
		return os.General_Error.Invalid_Dir
	}
	return os.Platform_Error(errno)
}
