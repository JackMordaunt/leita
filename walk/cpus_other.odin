#+build !linux
package walk

import "core:os"

// The machine's logical CPUs. No CPU limit is read here, such as a Windows job
// object's rate cap, so a process held below the count is not seen to be.
@(private)
cpus :: proc() -> int {
	return max(os.get_processor_core_count(), 1)
}
