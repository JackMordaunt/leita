package ntfs

import "core:mem"

// A byte range of the MFT's logical address space that is worth reading.
@(private)
Read_Extent :: struct {
	offset: u64,
	length: u64,
}

/*
Decide which parts of the MFT to read.

$MFT carries its own $BITMAP, one bit per record slot, so which slots are dead is
known before a single record is fetched. On a volume that has seen a lot of churn the
dead slots can be a third of the table, and reading them is pure waste.

Skipping is only a win when the dead run is long enough that not reading it beats
breaking the sequential stream and paying for another request, so gaps shorter than
`min_gap` are read through instead. Extents are cluster aligned because a cluster can
hold several records and unbuffered reads must cover whole sectors; a cluster counts
as live when any record touching it is live.

A slot the bitmap calls dead may briefly hold a record the file system is still
allocating. The reader is already looking at a live volume without a snapshot, so
that race is the same one the whole scan lives with.
*/
@(private)
plan_reads :: proc(
	bitmap: []byte,
	mft_bytes: u64,
	record_size, cluster, min_gap: u64,
	allocator: mem.Allocator,
) -> (extents: []Read_Extent, err: Error) {
	out := make([dynamic]Read_Extent, allocator)
	total_clusters := (mft_bytes + cluster - 1) / cluster
	records := mft_bytes / record_size

	start, end: u64 // current extent, in clusters; end is exclusive
	open := false
	for c: u64 = 0; c < total_clusters; c += 1 {
		if !cluster_has_live_record(bitmap, c, records, record_size, cluster) {
			continue
		}
		switch {
		case !open:
			start, end, open = c, c + 1, true
		case (c - end) * cluster < min_gap:
			end = c + 1 // the gap is too short to be worth skipping
		case:
			append(&out, Read_Extent{start * cluster, (end - start) * cluster})
			start, end = c, c + 1
		}
	}
	if open {
		append(&out, Read_Extent{start * cluster, (end - start) * cluster})
	}

	// The last extent may run past the attribute's length once rounded to a cluster.
	if len(out) > 0 {
		last := &out[len(out) - 1]
		if last.offset + last.length > mft_bytes {
			last.length = mft_bytes - last.offset
		}
	}
	return out[:], .None
}

@(private)
cluster_has_live_record :: proc "contextless" (bitmap: []byte, c, records, record_size, cluster: u64) -> bool {
	first := c * cluster / record_size
	last := ((c + 1) * cluster - 1) / record_size
	for r := first; r <= last && r < records; r += 1 {
		if bit_is_set(bitmap, r) {
			return true
		}
	}
	return false
}

@(private)
bit_is_set :: proc "contextless" (b: []byte, i: u64) -> bool {
	byte_index := i / 8
	if byte_index >= u64(len(b)) {
		return false
	}
	return b[byte_index] & (1 << uint(i % 8)) != 0
}
