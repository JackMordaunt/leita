package main

import "core:fmt"
import "core:time"

import "jm:timefmt"
import "version"

// version_line is which leita this is, where it runs and when it was built:
// leita v0.1.0 (linux/amd64, built 2026-10-09). In the temp allocator.
version_line :: proc() -> string {
	return fmt.tprintf(
		"%s %s (%s/%s, built %s)",
		PROGRAM,
		version.VERSION,
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
		timefmt.date(time.Time{_nsec = ODIN_COMPILE_TIMESTAMP}, context.temp_allocator),
	)
}
