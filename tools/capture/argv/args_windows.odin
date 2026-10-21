#+build windows
package argv

import "core:c"
import "core:os"
import win "core:sys/windows"

// program_args reads the wide command line and decodes each argument with
// command_arg.
program_args :: proc(allocator := context.allocator) -> []string {
	count: c.int
	wide := win.CommandLineToArgvW(win.GetCommandLineW(), &count)
	if wide == nil || count < 1 {
		return os.args
	}
	defer win.LocalFree(rawptr(wide))
	args := make([]string, int(count), allocator)
	for i in 0 ..< int(count) {
		w := cast([^]u16)wide[i]
		n := 0
		for w[n] != 0 {
			n += 1
		}
		args[i] = command_arg(w[:n], allocator)
	}
	return args
}
