package ntfs

import "core:math/bits"

Boot_Sector :: struct {
	bytes_per_sector:    u32,
	sectors_per_cluster: u32,
	bytes_per_cluster:   u32,
	total_sectors:       u64,
	mft_lcn:             u64, // first cluster of $MFT
	mft_mirror_lcn:      u64,
	record_size:         u32, // bytes per FILE record, normally 1024
	index_block_size:    u32, // bytes per directory index block, normally 4096
	serial:              u64,
}

/*
Parse the first sector of an NTFS volume. `b` must hold at least 512 bytes.

Two fields use an encoding worth knowing about. Sectors-per-cluster and
clusters-per-record are single bytes; values of 0x80 and above are negative exponents,
so 0xF6 means 2^(256-0xF6) = 2^10 = 1024 bytes. This lets a cluster (up to 2 MiB) or a
record be smaller or larger than the other without a wider field.
*/
parse_boot_sector :: proc(b: []byte) -> (bs: Boot_Sector, err: Error) {
	if len(b) < 512 {
		return {}, .Bad_Boot_Sector
	}
	if string(b[3:11]) != "NTFS    " {
		return {}, .Not_Ntfs
	}
	if b[0x1FE] != 0x55 || b[0x1FF] != 0xAA {
		return {}, .Bad_Boot_Sector
	}

	bs.bytes_per_sector = u32(rd16(b, 0x0B))
	bs.sectors_per_cluster = decode_shift_byte(b[0x0D])
	bs.total_sectors = rd64(b, 0x28)
	bs.mft_lcn = rd64(b, 0x30)
	bs.mft_mirror_lcn = rd64(b, 0x38)
	bs.serial = rd64(b, 0x48)

	if bs.bytes_per_sector < 256 || bs.bytes_per_sector > 4096 || !is_pow2(bs.bytes_per_sector) {
		return {}, .Bad_Boot_Sector
	}
	if bs.sectors_per_cluster == 0 || !is_pow2(bs.sectors_per_cluster) {
		return {}, .Bad_Boot_Sector
	}
	bs.bytes_per_cluster = bs.bytes_per_sector * bs.sectors_per_cluster

	bs.record_size = decode_size_byte(b[0x40], bs.bytes_per_cluster)
	bs.index_block_size = decode_size_byte(b[0x44], bs.bytes_per_cluster)

	// A record must be a whole number of sectors so it can be read directly from the
	// volume, and at least two fixup blocks so the update sequence array has something
	// to protect.
	if bs.record_size < 512 || !is_pow2(bs.record_size) || bs.record_size % bs.bytes_per_sector != 0 {
		return {}, .Bad_Boot_Sector
	}
	if bs.mft_lcn == 0 || bs.total_sectors == 0 {
		return {}, .Bad_Boot_Sector
	}
	return bs, .None
}

// Byte values below 0x80 are literal counts; values at or above are 2^(256-v).
@(private)
decode_shift_byte :: proc "contextless" (v: byte) -> u32 {
	if v < 0x80 {
		return u32(v)
	}
	return u32(1) << uint(256 - int(v))
}

// Clusters-per-X fields: positive is a cluster count, negative is a byte exponent.
@(private)
decode_size_byte :: proc "contextless" (v: byte, bytes_per_cluster: u32) -> u32 {
	if v < 0x80 {
		return u32(v) * bytes_per_cluster
	}
	return u32(1) << uint(256 - int(v))
}

@(private)
is_pow2 :: proc "contextless" (v: u32) -> bool {
	return v != 0 && bits.count_ones(v) == 1
}
