package sonar_history

import "core:fmt"
import "core:hash"

/*
A kept scan holds a lock on a file beside the store for the place it scans, so a
scheduled scan that starts while the last of the same place is still running sees
it and steps aside, rather than stacking another on top. The operating system
holds the lock for the open file, so it goes when the process does, however that
ends; the file itself stays, empty, for the next to lock.
*/

// Lock_Result is how taking a lock went.
Lock_Result :: enum {
	Taken,
	Held, // another process holds it
	Failed, // the file could not be opened
}

// lock_path is the file a kept scan of place locks, beside the store at db: the
// place is hashed, since a path may hold what no file name can.
lock_path :: proc(db, place: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"%s.%016x.lock",
		db,
		hash.fnv64a(transmute([]byte)place),
		allocator = allocator,
	)
}
