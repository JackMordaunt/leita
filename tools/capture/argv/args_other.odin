#+build !windows
package argv

import "core:os"

// program_args is this process's arguments.
program_args :: proc() -> []string {
	return os.args
}
