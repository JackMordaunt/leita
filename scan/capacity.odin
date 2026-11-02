package scan

// Checked conversion for a volume API with unsigned block counts. Invalid or
// unrepresentable measurements stay unknown instead of wrapping into small disks.
@(private)
freebsd_capacity :: proc(blocks, available, unit: u64) -> (total, free: u64, ok: bool) {
	if unit == 0 || available > blocks || blocks > max(u64) / unit {
		return 0, 0, false
	}
	return blocks * unit, available * unit, true
}
