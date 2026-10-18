package scan

import "core:strings"

note_snapshot_volume :: proc(t: ^Tree) {
	t.snapshot_volume = true
}

has_snapshot_volume :: proc(t: ^Tree) -> bool {
	return t.snapshot_volume
}

// Copy a completed volume snapshot enumeration into a tree. A failed copy
// publishes nothing; the caller then leaves retention as Unchecked.
note_snapshot_names :: proc(t: ^Tree, names: []string) -> bool {
	if len(t.snapshot_names) != 0 {
		return false
	}
	copy_names := make([dynamic]string, 0, len(names), t.allocator)
	for name in names {
		owned, err := strings.clone(name, t.allocator)
		if err != nil {
			for s in copy_names {delete(s, t.allocator)}
			delete(copy_names)
			return false
		}
		if _, append_err := append(&copy_names, owned); append_err != nil {
			delete(owned, t.allocator)
			for s in copy_names {delete(s, t.allocator)}
			delete(copy_names)
			return false
		}
	}
	t.snapshot_names = copy_names
	return true
}

// Valid on a finished tree until tree_destroy; callers must not mutate it.
snapshot_names_of :: proc(t: ^Tree) -> []string {
	return t.snapshot_names[:]
}
