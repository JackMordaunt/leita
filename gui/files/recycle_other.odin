#+build !windows
package leita_files

// recycle_bins is none off Windows: the Recycle Bin is the shell's.
recycle_bins :: proc(sid: string, allocator := context.allocator) -> []Recycle_Bin {
	return nil
}

recycle_bin_info :: proc(root: string) -> (bytes, items: u64, ok: bool) {
	return 0, 0, false
}

empty_recycle_bin :: proc(root: string) -> Error {
	return .Unsupported
}
