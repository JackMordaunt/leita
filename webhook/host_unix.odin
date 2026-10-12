#+build linux, darwin, freebsd, openbsd, netbsd
package leita_webhook

import "core:strings"
import "core:sys/posix"

// host_name is this machine's name, for an event to say where it came from:
// its network name, as uname(3) gives it, or "" when the system will not say.
// In the temp allocator.
host_name :: proc() -> string {
	u: posix.utsname
	if posix.uname(&u) < 0 {
		return ""
	}
	return trim_name(
		strings.string_from_null_terminated_ptr(raw_data(u.nodename[:]), len(u.nodename)),
	)
}
