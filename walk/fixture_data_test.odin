package walk

// Physical-size fixtures need deterministic incompressible bytes: repeated
// characters can occupy one block on ZFS and conceal growth or retention edges.
@(private)
fixture_bytes :: proc(length: int) -> []byte {
	body := make([]byte, length, context.temp_allocator)
	state: u64 = 0x9e3779b97f4a7c15
	for &b in body {
		state ~= state << 13
		state ~= state >> 7
		state ~= state << 17
		b = byte(state >> 32)
	}
	return body
}
