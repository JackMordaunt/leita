#+build darwin
package leita_faults

import "core:os"
import "core:sys/posix"

@(private)
platform_error :: proc(f: Fault) -> os.Error {
	#partial switch f {
	case .No_Space, .Short:
		return os.Platform_Error(posix.Errno.ENOSPC)
	case .Read_Only:
		return os.Platform_Error(posix.Errno.EROFS)
	case .Denied:
		return os.Platform_Error(posix.Errno.EACCES)
	}
	return os.Platform_Error(posix.Errno.EIO)
}

@(private)
kill_self :: proc() {
	posix.kill(posix.getpid(), .SIGKILL)
	for {}
}
