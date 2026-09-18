package ntfs

import "core:math/bits"
import "core:mem"

/*
Count the volume's allocated clusters from $Bitmap, which holds one bit per cluster,
set meaning allocated.

This is the file system's own account of used space, arrived at without looking at any
file. Summing every file's run list should reproduce it almost exactly, so a large
divergence points at the run list decoding being wrong rather than at space having
gone missing. Files small enough to live inside their MFT record occupy no clusters
and so appear in neither figure; their bytes are counted under $MFT.

`mft` must be an extent reader over the MFT's own run list. `scratch` is reused for
the record read and then for the bitmap stream, so it must hold at least one record
and its length must be a whole number of clusters.
*/
@(private)
read_bitmap_clusters :: proc(
	mft: ^Extent_Reader,
	boot: Boot_Sector,
	scratch: []byte,
	allocator: mem.Allocator,
) -> (clusters: u64, err: Error) {
	record_size := int(boot.record_size)
	cluster := u64(boot.bytes_per_cluster)
	if len(scratch) < record_size || u64(len(scratch)) < cluster {
		return 0, .Short_Read
	}

	rec := scratch[:record_size]
	if read_err := read_logical(mft, u64(RECORD_BITMAP) * u64(record_size), rec); read_err != nil {
		return 0, read_err
	}
	if fix_err := apply_fixups(rec); fix_err != nil {
		return 0, fix_err
	}
	if .In_Use not_in record_header(rec).flags {
		return 0, .Bad_Record
	}

	runs: []Run
	data_size: u64
	found := false
	it := attributes(rec)
	for {
		a, ok := next_attribute(&it)
		if !ok {
			break
		}
		if a.type != .Data || len(a.name) != 0 || !a.non_resident || a.lowest_vcn != 0 {
			continue
		}
		decoded, run_err := decode_runlist(a.runlist, 0, allocator)
		if run_err != nil {
			return 0, run_err
		}
		runs = decoded
		data_size = a.data_size
		found = true
		break
	}
	if !found {
		return 0, .Bad_Record
	}
	defer delete(runs, allocator)

	// Bits past the last cluster are padding that NTFS leaves set, so stop counting at
	// the volume's real cluster count instead of trusting the attribute length.
	total := boot.total_sectors / u64(boot.sectors_per_cluster)
	covered := runlist_clusters(runs) * cluster
	want := (total + 7) / 8
	limit := min(min(want, data_size), covered)
	tail := uint(total % 8)
	if limit < want {
		tail = 0 // the last byte is out of reach, so there is nothing to mask
	}

	// Raw volume reads must cover whole sectors, so read whole clusters and count only
	// the prefix that maps to real clusters.
	read_limit := min((limit + cluster - 1) / cluster * cluster, covered)

	br := Extent_Reader{v = mft.v, runs = runs, cluster = cluster}
	for offset: u64 = 0; offset < read_limit; {
		n := int(min(u64(len(scratch)), read_limit - offset))
		if read_err := read_logical(&br, offset, scratch[:n]); read_err != nil {
			return 0, read_err
		}
		if offset < limit {
			countable := int(min(u64(n), limit - offset))
			if offset + u64(countable) == limit && tail != 0 {
				scratch[countable - 1] &= byte(1 << tail) - 1
			}
			clusters += count_set_bits(scratch[:countable])
		}
		offset += u64(n)
	}
	return clusters, .None
}

// Population count over a byte slice, eight bytes at a time.
@(private)
count_set_bits :: proc "contextless" (b: []byte) -> (n: u64) {
	i := 0
	for ; i + 8 <= len(b); i += 8 {
		n += bits.count_ones((^u64)(raw_data(b[i:]))^)
	}
	for ; i < len(b); i += 1 {
		n += u64(bits.count_ones(b[i]))
	}
	return
}
