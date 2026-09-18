package ntfs

import "../scan"

/*
Project a finished table into the normalised tree.

The table stays the native form and keeps what only NTFS has: record and sequence
numbers, per-stream allocation, the resident-file accounting. A caller wanting the
truth reads it directly. This is the lossy view everything above the reader shares
with the other readers.

Record numbers become node indices unchanged, so the tree has a slot per record slot,
including the dead ones. That wastes the slots but keeps every parent reference valid
without a second mapping, and a dead slot is simply not marked used.
*/
to_tree :: proc(m: ^Mft, t: ^scan.Tree) -> scan.Error {
	if err := scan.reserve(t, u32(len(m.entries))); err != nil {
		return err
	}
	w := scan.writer(t, 0)
	used, bytes: u64

	for e, i in m.entries {
		if .In_Use not_in e.flags || e.name == "" {
			continue
		}
		n := scan.node(t, u32(i))
		n.name = scan.intern(&w, e.name)
		n.size = e.size
		n.disk = e.allocated
		n.flags = {.Used}
		if .Directory in e.flags {
			n.flags |= {.Directory}
		}
		if .Reparse_Point in e.attributes {
			n.flags |= {.Reparse}
		}
		// A parent that has been recycled since this name was written points at a
		// different file now, so the node is rooted at itself and reads as orphaned.
		n.parent = e.parent if entry_parent_valid(m, e) else u32(i)
		used += 1
		bytes += e.allocated
	}

	// Extra names for a file already counted. They belong in the tree so a file can
	// be found at every path it has, but their bytes must not be counted twice.
	for l in m.links {
		index, err := scan.claim(&w, 1)
		if err != nil {
			return err
		}
		n := scan.node(t, index)
		n.parent = l.parent
		n.name = scan.intern(&w, l.name)
		n.disk = m.entries[l.record].allocated
		n.size = m.entries[l.record].size
		n.flags = {.Used, .Extra_Name}
	}

	// NTFS names its root ".", which says nothing useful in a path. The caller knows
	// where the volume is mounted and renames it.
	t.root = RECORD_ROOT
	scan.progress(t, used, bytes)
	return .None
}
