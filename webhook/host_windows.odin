#+build windows
package leita_webhook

import "core:os"

// host_name is this machine's name, for an event to say where it came from:
// COMPUTERNAME, or "" when it is unset. In the temp allocator.
host_name :: proc() -> string {
	return trim_name(os.get_env("COMPUTERNAME", context.temp_allocator))
}
