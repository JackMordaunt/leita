package pdf

import "core:hash"

// Streams are compressed here because core:compress (zlib, gzip) has inflate
// procedures and no deflate ones, at Odin dev-2026-09. LZ77 over a 32 KiB
// window, matches found through 3-byte hash chains, coded in a single block of
// deflate's fixed Huffman codes (RFC 1951, 3.2.6): they cost a little against
// dynamic codes but need no code-length tables.

@(private)
WINDOW :: 1 << 15
@(private)
CHAIN_HEADS :: 1 << 15
@(private)
MAX_CHAIN :: 128 // candidates tried per position before taking the best so far
@(private)
MIN_MATCH :: 3
@(private)
MAX_MATCH :: 258

@(private)
LENGTH_BASE := [29]u16 {
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
}
@(private)
LENGTH_EXTRA := [29]u8 {
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	1,
	1,
	2,
	2,
	2,
	2,
	3,
	3,
	3,
	3,
	4,
	4,
	4,
	4,
	5,
	5,
	5,
	5,
	0,
}
@(private)
DIST_BASE := [30]u16 {
	1,
	2,
	3,
	4,
	5,
	7,
	9,
	13,
	17,
	25,
	33,
	49,
	65,
	97,
	129,
	193,
	257,
	385,
	513,
	769,
	1025,
	1537,
	2049,
	3073,
	4097,
	6145,
	8193,
	12289,
	16385,
	24577,
}
@(private)
DIST_EXTRA := [30]u8 {
	0,
	0,
	0,
	0,
	1,
	1,
	2,
	2,
	3,
	3,
	4,
	4,
	5,
	5,
	6,
	6,
	7,
	7,
	8,
	8,
	9,
	9,
	10,
	10,
	11,
	11,
	12,
	12,
	13,
	13,
}

// Bits writes a deflate bit stream: least significant bit first.
@(private)
Bits :: struct {
	out:  ^[dynamic]byte,
	acc:  u64,
	nacc: uint,
}

@(private)
bits_put :: proc(b: ^Bits, v: u32, n: uint) {
	b.acc |= u64(v) << b.nacc
	b.nacc += n
	for b.nacc >= 8 {
		append(b.out, byte(b.acc))
		b.acc >>= 8
		b.nacc -= 8
	}
}

@(private)
bits_flush :: proc(b: ^Bits) {
	if b.nacc > 0 {
		append(b.out, byte(b.acc))
	}
	b.acc, b.nacc = 0, 0
}

// put_code writes a Huffman code, which deflate packs most significant bit
// first, the reverse of everything else.
@(private)
put_code :: proc(b: ^Bits, code: u32, n: uint) {
	rev: u32
	for i in 0 ..< n {
		rev |= ((code >> i) & 1) << (n - 1 - i)
	}
	bits_put(b, rev, n)
}

// put_symbol writes a literal/length symbol in the fixed code.
@(private)
put_symbol :: proc(b: ^Bits, sym: int) {
	switch {
	case sym < 144:
		put_code(b, u32(0x30 + sym), 8)
	case sym < 256:
		put_code(b, u32(0x190 + sym - 144), 9)
	case sym < 280:
		put_code(b, u32(sym - 256), 7)
	case:
		put_code(b, u32(0xc0 + sym - 280), 8)
	}
}

@(private)
put_match :: proc(b: ^Bits, length, dist: int) {
	lc := len(LENGTH_BASE) - 1
	for int(LENGTH_BASE[lc]) > length {
		lc -= 1
	}
	put_symbol(b, 257 + lc)
	bits_put(b, u32(length - int(LENGTH_BASE[lc])), uint(LENGTH_EXTRA[lc]))
	dc := len(DIST_BASE) - 1
	for int(DIST_BASE[dc]) > dist {
		dc -= 1
	}
	put_code(b, u32(dc), 5)
	bits_put(b, u32(dist - int(DIST_BASE[dc])), uint(DIST_EXTRA[dc]))
}

@(private)
chain_key :: #force_inline proc(data: []byte, at: int) -> int {
	v := u32(data[at]) << 16 | u32(data[at + 1]) << 8 | u32(data[at + 2])
	return int((v * 2654435761) >> 17) & (CHAIN_HEADS - 1)
}

// zlib_compress appends data to out as a zlib stream (RFC 1950), the form a
// PDF FlateDecode filter reads (ISO 32000-1, 7.4.4). Its working tables,
// 256 KiB, come from context.temp_allocator.
zlib_compress :: proc(out: ^[dynamic]byte, data: []byte) {
	append(out, 0x78, 0x9c)
	b := Bits {
		out = out,
	}
	bits_put(&b, 1, 1) // the final block
	bits_put(&b, 1, 2) // fixed Huffman codes

	heads := make([]i32, CHAIN_HEADS, context.temp_allocator)
	prev := make([]i32, WINDOW, context.temp_allocator)
	for &h in heads {
		h = -1
	}
	insert :: #force_inline proc(data: []byte, heads, prev: []i32, at: int) {
		k := chain_key(data, at)
		prev[at & (WINDOW - 1)] = heads[k]
		heads[k] = i32(at)
	}

	n := len(data)
	i := 0
	for i < n {
		best, dist := 0, 0
		if i + MIN_MATCH <= n {
			limit := min(MAX_MATCH, n - i)
			cand := int(heads[chain_key(data, i)])
			for tries := 0;
			    cand >= 0 && cand < i && i - cand <= WINDOW && tries < MAX_CHAIN;
			    tries += 1 {
				l := 0
				for l < limit && data[cand + l] == data[i + l] {
					l += 1
				}
				if l > best {
					best, dist = l, i - cand
					if l == limit {
						break
					}
				}
				next := int(prev[cand & (WINDOW - 1)])
				if next >= cand {
					break // the slot was reused by a later position
				}
				cand = next
			}
			insert(data, heads, prev, i)
		}
		if best >= MIN_MATCH {
			put_match(&b, best, dist)
			for k in 1 ..< best {
				if i + k + MIN_MATCH <= n {
					insert(data, heads, prev, i + k)
				}
			}
			i += best
		} else {
			put_symbol(&b, int(data[i]))
			i += 1
		}
	}
	put_symbol(&b, 256)
	bits_flush(&b)

	sum := hash.adler32(data)
	append(out, byte(sum >> 24), byte(sum >> 16), byte(sum >> 8), byte(sum))
}
