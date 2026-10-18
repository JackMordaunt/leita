package walk

import "core:mem"
import "core:sync"

// ATTR_CMNEXT_CLONEID identifies a data stream shared by pure clones; see
// Apple's getattrlist(2), ATTR_CMNEXT_CLONEID:
// https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/getattrlist.2
// This key is limited to that stream and the real device; other forks keep
// their own allocation.
@(private)
Clone_Key :: struct {
	device, stream: u64,
}

@(private)
Clone_Data :: struct {
	allocated, logical: u64,
}

@(private)
Clones :: struct {
	mutex: sync.Mutex,
	paid:  map[Clone_Key]Clone_Data,
}

// Only known, consistent data-fork measurements can remove a duplicate charge.
// An allocation mismatch can mean a concurrent write; keep the upper bound.
// The caller has already selected the payer of any hard-linked inode.
@(private)
charge_clone :: proc(
	c: ^Clones,
	key: Clone_Key,
	data: Clone_Data,
	all: u64,
) -> (
	charge: u64,
	shared, ok: bool,
) {
	if key.stream == 0 || data.allocated > all {
		return all, false, true
	}
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	_, prior, inserted, err := map_entry(&c.paid, key)
	if err != nil {
		return all, false, false
	}
	if inserted {
		prior^ = data
		return all, false, true
	}
	if prior^ != data {
		return all, false, true
	}
	return all - data.allocated, data.allocated != 0, true
}

@(private)
clones_make :: proc(allocator: mem.Allocator) -> Clones {
	return {paid = make(map[Clone_Key]Clone_Data, allocator)}
}

when ODIN_OS != .Darwin {
	@(private)
	Darwin_Measurement :: struct {}
}
