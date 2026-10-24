package walk

import "../scan"

// What a file reader measured. allocated_known is false when the byte count in
// `allocated` is not an allocation (a btrfs st_blocks figure, a logical tree).
// charge is the number the node will store in Node.disk.
File_Measure :: struct {
	logical:          u64,
	allocated:        u64,
	charge:           u64,
	links:            u32,
	allocated_known:  bool,
	links_known:      bool,
}

/*
The account worth keeping for one file.

An empty known set means "do not store": a plain file whose length matches its
allocation teaches freed_of nothing, and absence stays Unknown. A link count
above one stores Reclaim 0, which is name-unlink, not a volume-free figure.
Shared is set only from a known allocation. Exclusive is never set.
*/
file_account :: proc(m: File_Measure) -> scan.Account {
	multi := m.links_known && m.links > 1
	slack := m.allocated_known && m.logical != m.allocated
	unallocated := !m.allocated_known && m.logical != m.charge
	if !multi && !slack && !unallocated {
		return {}
	}
	a := scan.Account {
		logical = m.logical,
		links   = m.links,
		known   = {.Logical},
	}
	if m.links_known {
		a.known += {.Links}
	}
	if multi {
		a.known += {.Reclaim}
		if m.allocated_known {
			a.allocated = m.allocated
			a.shared = m.allocated
			a.known += {.Allocated, .Shared}
		}
	} else if m.allocated_known {
		a.allocated = m.allocated
		a.known += {.Allocated}
	}
	return a
}

// The scan's charged bytes for a Windows file. This is not an Allocated fact.
// A reported size that is not a whole number of clusters is replaced with the
// file length so a resident file is not charged the rounded figure. Callers
// pass the occupied size, when they have one, as `reported`.
windows_charge :: proc(logical, reported, cluster: u64, ntfs: bool) -> u64 {
	if ntfs && cluster > 0 && reported % cluster != 0 {
		return logical
	}
	return reported
}

// Figures the Windows reader actually obtained, before any charge heuristic.
Windows_Figures :: struct {
	logical:              u64,
	reported_allocation:  u64, // directory entry or FileStandardInformation, not yet rewritten
	occupied:             u64, // compressed or sparse query
	occupied_known:       bool,
	compressed_or_sparse: bool,
	cluster:              u64,
	ntfs:                 bool,
	links:                u32,
	links_known:          bool,
}

/*
Split a Windows file into a charge and an account.

`charge` is what Node.disk stores. `Account.allocated` is set only from a
measurement that is still the occupied size: the occupied query when the file
is compressed or sparse and that query succeeded, otherwise the reported
allocation when it is a whole number of clusters. A failed occupied query does
not invent an allocation from the reported size. A resident rewrite changes
the charge to the length and leaves Allocated unset. Neither case is Exact.
*/
windows_account :: proc(o: Windows_Figures) -> (charge: u64, a: scan.Account) {
	occupied := occupied_size(o)
	reported := o.reported_allocation
	if o.compressed_or_sparse && o.occupied_known {
		reported = occupied
	}
	charge = windows_charge(o.logical, reported, o.cluster, o.ntfs)

	allocated_known := false
	allocated: u64
	if o.compressed_or_sparse {
		if o.occupied_known {
			allocated_known = true
			allocated = occupied
		}
	} else if !(o.ntfs && o.cluster > 0 && o.reported_allocation % o.cluster != 0) {
		allocated_known = true
		allocated = o.reported_allocation
	}
	a = file_account({
		logical = o.logical,
		allocated = allocated,
		charge = charge,
		links = o.links,
		allocated_known = allocated_known,
		links_known = o.links_known,
	})
	return
}

/*
What a compressed or sparse file occupies. The occupied query stops at the file's
length: NTFS gives a sparse file its clusters a compression unit at a time, 64 KiB
on a 4 KiB volume, so a file of 4096 bytes with data in it holds 16 clusters
(FSCTL_GET_RETRIEVAL_POINTERS maps all 16, as walk/fuzz finds on a hosted Windows
runner), yet the query says 4096. An occupied size that reaches the length is that
cut, and the reported allocation, a whole number of clusters above it, is what NTFS
holds; below the length the query was not cut.
*/
@(private = "file")
occupied_size :: proc(o: Windows_Figures) -> u64 {
	whole := o.cluster > 0 && o.reported_allocation % o.cluster == 0
	if o.ntfs && whole && o.occupied >= o.logical && o.reported_allocation > o.occupied {
		return o.reported_allocation
	}
	return o.occupied
}
