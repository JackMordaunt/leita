package ntfs

import "core:mem"

// Alignment for I/O buffers. Raw volume reads want sector alignment; 4 KiB covers
// every sector size in use.
@(private)
IO_ALIGN :: 4096

DEFAULT_CHUNK_SIZE :: 16 * mem.Megabyte

Read_Options :: struct {
	chunk_size: int, // bytes per volume read; 0 selects DEFAULT_CHUNK_SIZE
}

// Open `path` (drive letter or image file) and read its whole MFT into a table.
read_mft :: proc(path: string, opts := Read_Options{}, allocator := context.allocator) -> (m: Mft, err: Error) {
	v, open_err := volume_open(path)
	if open_err != nil {
		return {}, open_err
	}
	defer volume_close(&v)
	return read_mft_from_volume(&v, opts, allocator)
}

/*
Read the MFT in three steps:

  1. Boot sector, for cluster size, record size, and the MFT's first cluster.
  2. Record 0, which describes $MFT itself. Its $DATA run list says which clusters
     hold the rest of the table, because the MFT is a file and can be fragmented.
  3. Stream the table through the run list in large chunks, fixing up and folding each
     record into the entry table as it goes.

The MFT is addressed as a contiguous logical byte range and `read_logical` maps each
chunk onto physical runs, so a record straddling two runs (possible when a cluster is
smaller than a record) is handled without special cases.
*/
read_mft_from_volume :: proc(v: ^Volume, opts := Read_Options{}, allocator := context.allocator) -> (m: Mft, err: Error) {
	// 1. Boot sector.
	boot_buf, boot_alloc_err := mem.alloc_bytes(IO_ALIGN, IO_ALIGN, allocator)
	if boot_alloc_err != nil {
		return {}, .Out_Of_Memory
	}
	defer mem.free_bytes(boot_buf, allocator)
	if read_err := volume_read_at(v, boot_buf, 0); read_err != nil {
		return {}, read_err
	}
	boot, boot_err := parse_boot_sector(boot_buf)
	if boot_err != nil {
		return {}, boot_err
	}
	cluster := u64(boot.bytes_per_cluster)
	record_size := int(boot.record_size)

	// 2. Record 0.
	rec0_len := max(record_size, IO_ALIGN)
	rec0_buf, rec0_alloc_err := mem.alloc_bytes(rec0_len, IO_ALIGN, allocator)
	if rec0_alloc_err != nil {
		return {}, .Out_Of_Memory
	}
	defer mem.free_bytes(rec0_buf, allocator)
	if read_err := volume_read_at(v, rec0_buf, boot.mft_lcn * cluster); read_err != nil {
		return {}, read_err
	}
	rec0 := rec0_buf[:record_size]
	if fix_err := apply_fixups(rec0); fix_err != nil {
		return {}, fix_err
	}
	if .In_Use not_in record_header(rec0).flags {
		return {}, .Bad_Record
	}

	runs: []Run
	defer delete(runs, allocator)
	mft_bytes: u64
	found := false
	it := attributes(rec0)
	for {
		a, ok := next_attribute(&it)
		if !ok {
			break
		}
		if a.type != .Data || len(a.name) != 0 {
			continue
		}
		if !a.non_resident {
			return {}, .Mft_Data_Missing
		}
		if a.lowest_vcn != 0 {
			continue
		}
		decoded, run_err := decode_runlist(a.runlist, 0, allocator)
		if run_err != nil {
			return {}, run_err
		}
		runs = decoded
		mft_bytes = a.data_size
		// If the run list in record 0 stops short of the data size, the rest of the
		// mapping lives in extension records reached via $ATTRIBUTE_LIST.
		if runlist_clusters(runs) * cluster < mft_bytes {
			return {}, .Mft_Spans_Extension_Records
		}
		found = true
		break
	}
	if !found {
		return {}, .Mft_Data_Missing
	}

	record_count := int(mft_bytes / u64(record_size))
	if init_err := mft_init(&m, record_count, cluster, allocator); init_err != nil {
		return {}, init_err
	}
	m.boot = boot
	// From here on, failures must release the table.
	ok := false
	defer if !ok {
		mft_destroy(&m)
	}

	// 3. Stream the table.
	chunk := opts.chunk_size
	if chunk <= 0 {
		chunk = DEFAULT_CHUNK_SIZE
	}
	// A chunk must hold whole records and whole clusters so every read stays aligned.
	unit := max(record_size, int(cluster))
	chunk = max(chunk / unit, 1) * unit
	buf, buf_alloc_err := mem.alloc_bytes(chunk, IO_ALIGN, allocator)
	if buf_alloc_err != nil {
		return {}, .Out_Of_Memory
	}
	defer mem.free_bytes(buf, allocator)

	reader := Extent_Reader{v = v, runs = runs, cluster = cluster}
	record_number: u32 = 0
	for offset: u64 = 0; offset < mft_bytes; offset += u64(chunk) {
		n := int(min(u64(chunk), mft_bytes - offset))
		if read_err := read_logical(&reader, offset, buf[:n]); read_err != nil {
			return {}, read_err
		}
		for start := 0; start + record_size <= n; start += record_size {
			rec := buf[start:start + record_size]
			defer record_number += 1
			// Slots never written are all zeros; skip them silently.
			if rd32(rec, 0) != RECORD_MAGIC {
				continue
			}
			m.stats.records_read += 1
			if apply_fixups(rec) != nil {
				m.stats.records_bad += 1
				continue
			}
			if add_err := mft_add_record(&m, record_number, rec); add_err != nil {
				m.stats.records_bad += 1
			}
		}
	}
	ok = true
	return m, .None
}

@(private)
Extent_Reader :: struct {
	v:       ^Volume,
	runs:    []Run,
	cluster: u64,
	cursor:  int, // runs are visited in ascending order, so remember where we were
}

// Read a byte range of the attribute's logical address space by mapping it onto runs.
@(private)
read_logical :: proc(r: ^Extent_Reader, offset: u64, buf: []byte) -> Error {
	done := 0
	for done < len(buf) {
		pos := offset + u64(done)
		vcn := pos / r.cluster
		for r.cursor < len(r.runs) && r.runs[r.cursor].vcn + r.runs[r.cursor].length <= vcn {
			r.cursor += 1
		}
		if r.cursor >= len(r.runs) || r.runs[r.cursor].vcn > vcn {
			return .Bad_Runlist
		}
		run := r.runs[r.cursor]
		if run.sparse {
			return .Bad_Runlist
		}
		in_run := pos - run.vcn * r.cluster
		avail := run.length * r.cluster - in_run
		n := int(min(u64(len(buf) - done), avail))
		if read_err := volume_read_at(r.v, buf[done:done + n], run.lcn * r.cluster + in_run); read_err != nil {
			return read_err
		}
		done += n
	}
	return .None
}
