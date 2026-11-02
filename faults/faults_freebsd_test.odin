#+build freebsd
package leita_faults

import "core:os"
import "core:sys/posix"
import "core:testing"

@(test)
freebsd_faults_have_the_native_posix_error_codes :: proc(t: ^testing.T) {
	for c in ([]struct {
			fault: Fault,
			code:  posix.Errno,
		}{{.No_Space, .ENOSPC}, {.Short, .ENOSPC}, {.Read_Only, .EROFS}, {.Denied, .EACCES}, {.IO, .EIO}}) {
		testing.expect_value(t, platform_error(c.fault), os.Error(os.Platform_Error(c.code)))
	}
}
