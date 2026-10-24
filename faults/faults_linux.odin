#+build linux
package leita_faults

import "core:os"
import "core:sys/linux"

@(private)
platform_error :: proc(f: Fault) -> os.Error {
	#partial switch f {
	case .No_Space, .Short:
		return os.Platform_Error(linux.Errno.ENOSPC)
	case .Read_Only:
		return os.Platform_Error(linux.Errno.EROFS)
	case .Denied:
		return os.Platform_Error(linux.Errno.EACCES)
	}
	return os.Platform_Error(linux.Errno.EIO)
}

@(private)
kill_self :: proc() {
	linux.kill(linux.getpid(), .SIGKILL)
	for {}
}
