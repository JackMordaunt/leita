#+build windows
package leita_faults

import "core:os"
import win "core:sys/windows"

@(private)
platform_error :: proc(f: Fault) -> os.Error {
	#partial switch f {
	case .No_Space, .Short:
		return os.Platform_Error(win.System_Error.DISK_FULL)
	case .Read_Only:
		return os.Platform_Error(win.System_Error.WRITE_PROTECT)
	case .Denied:
		return os.Platform_Error(win.System_Error.ACCESS_DENIED)
	}
	return os.Platform_Error(win.System_Error.CRC)
}

// KILLED is the exit code of a process killed here, 9 as SIGKILL is.
KILLED :: 9

@(private)
kill_self :: proc() {
	win.TerminateProcess(win.GetCurrentProcess(), KILLED)
	for {}
}
