#+build linux
package scan

import "base:runtime"
import "core:io"
import "core:os"
import "core:strings"
import "core:sys/linux"

/*
What the target is, and where, asked without statx.

core:os answers a stat with statx, which is Linux 4.11: on an older kernel every
os.stat fails, and a scan of a folder that is there says Target_Not_Found before
it reads one (shown on Linux 4.9, tools/vm). fstatat gives the type, which is all this layer
needs; the full path is the open file's, as os.stat reports it.
*/
@(private)
stat_target :: proc(
	path: string,
	allocator: runtime.Allocator,
) -> (
	type: os.File_Type,
	fullpath: string,
	err: io.Error,
) {
	when size_of(int) == 8 {
		cpath, clone_err := strings.clone_to_cstring(path, context.temp_allocator)
		if clone_err != nil {
			return .Undetermined, "", .Unknown
		}
		st: linux.Stat
		if errno := linux.fstatat(linux.AT_FDCWD, cpath, &st, {}); errno != .NONE {
			if errno == .EACCES || errno == .EPERM {
				return .Undetermined, "", .Permission_Denied
			}
			return .Undetermined, "", .Unknown
		}
		switch st.mode & linux.S_IFMT {
		case linux.S_IFBLK:
			type = .Block_Device
		case linux.S_IFCHR:
			type = .Character_Device
		case linux.S_IFDIR:
			type = .Directory
		case linux.S_IFREG:
			type = .Regular
		case:
			type = .Undetermined
		}
		abs, abs_err := os.get_absolute_path(path, allocator)
		if abs_err != nil {
			return .Undetermined, "", .Unknown
		}
		return type, abs, .None
	} else {
		info, stat_err := os.stat(path, allocator)
		if stat_err != nil {
			if stat_err == io.Error.Permission_Denied {
				return .Undetermined, "", .Permission_Denied
			}
			return .Undetermined, "", .Unknown
		}
		return info.type, info.fullpath, .None
	}
}
