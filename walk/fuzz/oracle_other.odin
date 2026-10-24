#+build !windows
package walk_fuzz

import "base:runtime"

import scan "../../scan"

// second_reader compares another reader of the tree with the model. Only Windows
// has one here (oracle_windows.odin): the walk is the only reader of a tree that
// is not a whole volume.
second_reader :: proc(spec: Spec, fx: ^Fixture, start: int, allocator: runtime.Allocator) -> (class, what: string) {
	return "", ""
}

// from_volume says whether a node of a scanned tree is something the volume came
// with rather than the spec. A tmpfs comes empty.
from_volume :: proc(t: ^scan.Tree, i: u32) -> bool {
	return false
}
