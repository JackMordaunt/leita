#+build !linux
#+build !windows
package scan

import "base:runtime"
import "core:io"
import "core:os"

// What the target is, and where: os.stat, which these systems answer.
@(private)
stat_target :: proc(
	path: string,
	allocator: runtime.Allocator,
) -> (
	type: os.File_Type,
	fullpath: string,
	err: io.Error,
) {
	info, stat_err := os.stat(path, allocator)
	if stat_err != nil {
		if stat_err == io.Error.Permission_Denied {
			return .Undetermined, "", .Permission_Denied
		}
		return .Undetermined, "", .Unknown
	}
	return info.type, info.fullpath, .None
}
