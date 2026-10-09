package pdf

import "core:bytes"
import "core:compress/zlib"
import "core:math/rand"
import "core:testing"

@(private)
inflates_back :: proc(t: ^testing.T, data: []byte, loc := #caller_location) -> int {
	packed: [dynamic]byte
	defer delete(packed)
	zlib_compress(&packed, data)
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	err := zlib.inflate(packed[:], &buf)
	testing.expect_value(t, err, nil, loc)
	testing.expect(
		t,
		bytes.equal(bytes.buffer_to_bytes(&buf), data),
		"inflated bytes differ",
		loc = loc,
	)
	return len(packed)
}

@(test)
deflate_round_trips_through_core_inflate :: proc(t: ^testing.T) {
	inflates_back(t, {})
	inflates_back(t, {'a'})
	inflates_back(t, transmute([]byte)string("abcabcabcabcabcabc"))

	// One byte repeated: matches of the longest length, back one byte.
	same := make([]byte, 100_000)
	defer delete(same)
	for &c in same {
		c = 'x'
	}
	testing.expect(t, inflates_back(t, same) < 1000)

	// Random bytes match nothing, and the fixed code spends 9 bits on each
	// literal from 144 to 255 (RFC 1951, 3.2.6): the stream grows.
	r := rand.create(7)
	noise := make([]byte, 70_000)
	defer delete(noise)
	for &c in noise {
		c = byte(rand.uint32(rand.default_random_generator(&r)))
	}
	inflates_back(t, noise)

	// A block repeated at the window's full distance.
	far := make([]byte, 2 * WINDOW + 500)
	defer delete(far)
	for i in 0 ..< WINDOW {
		far[i] = noise[i]
	}
	copy(far[WINDOW:], far[:WINDOW + 500])
	testing.expect(t, inflates_back(t, far) < WINDOW + 10_000)
}
