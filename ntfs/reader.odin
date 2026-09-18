package ntfs

import "core:mem"
import "core:time"

// Alignment for I/O buffers. Raw volume reads want sector alignment; 4 KiB covers
// every sector size in use.
@(private)
IO_ALIGN :: 4096

DEFAULT_CHUNK_SIZE :: 16 * mem.Megabyte

/*
How volume reads reach memory.

Buffered reads pass through the Windows cache manager, which copies every byte into
the system cache and then again into our buffer, and evicts whatever the user had
cached to make room. Unbuffered reads land in our buffer directly. The MFT is read
once from front to back and never re-read, so the cache earns nothing here.

Unbuffered reads require the buffer address, the file offset, and the length to be
sector aligned, which the reader already satisfies by working in whole clusters.
*/
IO_Mode :: enum {
	Unbuffered, // default
	Buffered,
}

/*
Shortest run of dead MFT records worth skipping over.

Breaking the sequential stream costs about 140 microseconds per extra read, measured
by sweeping this value on a live volume, so a skip only pays when the dead run takes
longer than that to read. Below a quarter of a megabyte the extra requests cost more
than the bytes they save, and at four kilobytes the scan is twice as slow as reading
the whole table. Above a megabyte the curve flattens and then slowly worsens as real
savings are left on the table. A megabyte sat at the bottom of that curve and also
produces the fewest extents, which keeps the work easy to split across threads later.
*/
DEFAULT_MIN_SKIP :: mem.Megabyte

Read_Options :: struct {
	chunk_size: int, // bytes per volume read; 0 selects DEFAULT_CHUNK_SIZE
	io_mode:    IO_Mode,
	min_skip:   int, // 0 selects DEFAULT_MIN_SKIP; negative reads the whole table
}

// Open `path` (drive letter or image file) and read its whole MFT into a table.
read_mft :: proc(path: string, opts := Read_Options{}, allocator := context.allocator) -> (m: Mft, err: Error) {
	v, open_err := volume_open(path, opts.io_mode)
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

	// $MFT's own $BITMAP marks which record slots are live, so the dead ones can be
	// skipped rather than read and discarded.
	slot_bitmap: []byte
	defer mem.free_bytes(slot_bitmap, allocator)

	it := attributes(rec0)
	for {
		a, ok := next_attribute(&it)
		if !ok {
			break
		}
		if len(a.name) != 0 || a.lowest_vcn != 0 {
			continue
		}
		#partial switch a.type {
		case .Data:
			if !a.non_resident {
				return {}, .Mft_Data_Missing
			}
			if found {
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
		case .Bitmap:
			if slot_bitmap != nil {
				continue
			}
			// Losing the bitmap only costs the skipping, so a failure is not fatal.
			if bm, bm_err := read_attribute(v, a, cluster, allocator); bm_err == nil {
				slot_bitmap = bm
			}
		}
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

	// Decide what to read. Without the slot bitmap, or with skipping turned off, the
	// plan is the whole table, which is what the reader did before.
	extents: []Read_Extent
	defer delete(extents, allocator)
	if slot_bitmap != nil && opts.min_skip >= 0 {
		min_skip := u64(DEFAULT_MIN_SKIP)
		if opts.min_skip > 0 {
			min_skip = u64(opts.min_skip)
		}
		if planned, plan_err := plan_reads(slot_bitmap, mft_bytes, u64(record_size), cluster, min_skip, allocator); plan_err == nil {
			extents = planned
		}
	}
	if extents == nil {
		whole, extent_alloc_err := make([]Read_Extent, 1, allocator)
		if extent_alloc_err != nil {
			return {}, .Out_Of_Memory
		}
		whole[0] = Read_Extent{0, mft_bytes}
		extents = whole
	}
	for e in extents {
		m.stats.planned_bytes += e.length
	}
	m.stats.skipped_bytes = mft_bytes - m.stats.planned_bytes
	m.stats.extents = u64(len(extents))

	reader := Extent_Reader{v = v, runs = runs, cluster = cluster}
	for e in extents {
		for offset := e.offset; offset < e.offset + e.length; offset += u64(chunk) {
			n := int(min(u64(chunk), e.offset + e.length - offset))
			// Unbuffered reads must cover whole sectors. The run list is cluster
			// granular, so rounding up never reads past the attribute's allocation.
			read_n := min(int((u64(n) + cluster - 1) / cluster * cluster), chunk)
			io_start := time.tick_now()
			if read_err := read_logical(&reader, offset, buf[:read_n]); read_err != nil {
				return {}, read_err
			}
			m.stats.io_ns += i64(time.tick_since(io_start))
			parse_start := time.tick_now()
			defer m.stats.parse_ns += i64(time.tick_since(parse_start))
			for start := 0; start + record_size <= n; start += record_size {
				rec := buf[start:start + record_size]
				// Extents may skip forward, so the slot number comes from the offset.
				record_number := u32((offset + u64(start)) / u64(record_size))
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
	}
	// $Bitmap is the file system's own count of used clusters, which checks the sums
	// built above. Failing to read it costs nothing else, so the table still stands.
	bitmap_start := time.tick_now()
	if c, bitmap_err := read_bitmap_clusters(&reader, boot, buf, allocator); bitmap_err == nil {
		m.stats.allocated_clusters = c
	}
	m.stats.bitmap_ns = i64(time.tick_since(bitmap_start))

	ok = true
	return m, .None
}

// Read a whole attribute into memory: a copy of the value when resident, or the
// clusters its run list names when not. The caller frees the result.
@(private)
read_attribute :: proc(v: ^Volume, a: Attribute, cluster: u64, allocator: mem.Allocator) -> (data: []byte, err: Error) {
	if !a.non_resident {
		if len(a.value) == 0 {
			return nil, .Bad_Record
		}
		out, alloc_err := mem.alloc_bytes(len(a.value), IO_ALIGN, allocator)
		if alloc_err != nil {
			return nil, .Out_Of_Memory
		}
		copy(out, a.value)
		return out, .None
	}
	runs, run_err := decode_runlist(a.runlist, 0, allocator)
	if run_err != nil {
		return nil, run_err
	}
	defer delete(runs, allocator)
	// Unbuffered reads cover whole clusters, so the buffer is rounded up to one.
	n := min((a.data_size + cluster - 1) / cluster * cluster, runlist_clusters(runs) * cluster)
	if n == 0 {
		return nil, .Bad_Runlist
	}
	out, alloc_err := mem.alloc_bytes(int(n), IO_ALIGN, allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	r := Extent_Reader{v = v, runs = runs, cluster = cluster}
	if read_err := read_logical(&r, 0, out); read_err != nil {
		mem.free_bytes(out, allocator)
		return nil, read_err
	}
	return out, .None
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
		// The cursor only walks forward, so rewind it when a read goes backwards.
		if r.cursor >= len(r.runs) || r.runs[r.cursor].vcn > vcn {
			r.cursor = 0
		}
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
