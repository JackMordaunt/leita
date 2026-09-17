package ntfs

// One contiguous extent of a non-resident attribute.
Run :: struct {
	vcn:    u64, // first virtual cluster (offset within the attribute, in clusters)
	lcn:    u64, // first logical cluster on the volume; meaningless when sparse
	length: u64, // clusters
	sparse: bool, // no clusters allocated; reads as zeros
}

/*
Decode NTFS "mapping pairs" into runs.

Each pair starts with a header byte: the low nibble is the byte width of the length
field, the high nibble the byte width of the LCN delta. Widths are variable so short
runs cost two or three bytes. The LCN is stored as a signed delta from the previous
run's LCN, which is why decoding is stateful. A zero-width delta means the run is
sparse. A zero header byte terminates the list.

`first_vcn` is the attribute's lowest_vcn; it is 0 for the first (or only) extent.
*/
decode_runlist :: proc(b: []byte, first_vcn: u64, allocator := context.allocator) -> (runs: []Run, err: Error) {
	out := make([dynamic]Run, allocator)
	vcn := first_vcn
	lcn: i64 = 0
	i := 0
	for i < len(b) {
		h := b[i]
		i += 1
		if h == 0 {
			break
		}
		len_size := int(h & 0xF)
		ofs_size := int(h >> 4)
		if len_size == 0 || len_size > 8 || ofs_size > 8 || i + len_size + ofs_size > len(b) {
			delete(out)
			return nil, .Bad_Runlist
		}
		length := read_uint_le(b[i:i + len_size])
		i += len_size
		if length == 0 {
			delete(out)
			return nil, .Bad_Runlist
		}
		run := Run{vcn = vcn, length = length}
		if ofs_size == 0 {
			run.sparse = true
		} else {
			lcn += read_int_le(b[i:i + ofs_size])
			i += ofs_size
			if lcn < 0 {
				delete(out)
				return nil, .Bad_Runlist
			}
			run.lcn = u64(lcn)
		}
		append(&out, run)
		vcn += length
	}
	return out[:], .None
}

// Total clusters covered by a run list, including sparse runs.
runlist_clusters :: proc(runs: []Run) -> u64 {
	total: u64
	for r in runs {
		total += r.length
	}
	return total
}

@(private)
read_uint_le :: proc "contextless" (b: []byte) -> u64 {
	v: u64
	for x, k in b {
		v |= u64(x) << (8 * uint(k))
	}
	return v
}

// Sign-extends a little-endian integer of 1 to 8 bytes.
@(private)
read_int_le :: proc "contextless" (b: []byte) -> i64 {
	v := read_uint_le(b)
	bits := uint(len(b)) * 8
	if bits < 64 && v & (u64(1) << (bits - 1)) != 0 {
		v |= ~u64(0) << bits
	}
	return i64(v)
}
