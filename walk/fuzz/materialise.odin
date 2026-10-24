package walk_fuzz

import "base:runtime"

// Fixture is a spec made real: a directory under the temp directory holding the
// tree, and what has to be undone to remove it.
Fixture :: struct {
	base:    string, // everything this case made; the scan's root is inside it
	root:    string, // the spec's root directory
	paths:   map[int]string, // the path of each node
	mounted: [dynamic]string, // in the order mounted
	locked:  [dynamic]string, // unreadable directories, whose mode is 0
	// The files whose data a clone shares, by node, a clone and what it is a clone
	// of, and their hard links; empty where a clone is a copy.
	clones:  map[int]bool,
	// The volume each tmpfs node shows, where a tmpfs is a volume made before
	// the run and lent to the case (Windows); nil where the mount makes it.
	volumes: map[int]string,
	// Whether this process is refused what a mode of 0 refuses, found by
	// asking: a root in a user namespace is not, unless it gives up the
	// capabilities that say so (`deny`).
	denies:  bool,
	// What everything above was allocated from, and so is freed to.
	allocator: runtime.Allocator,
}
