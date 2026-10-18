package changes

import "core:encoding/endian"
import "core:testing"

// A record `size` bytes long that says it is `length`, of version `major`, whose
// parent's id begins with `parent` where its version keeps it, when it reaches.
@(private = "file")
record :: proc(page: ^[dynamic]u8, length: u32, major: u16, parent: u8, size: int) {
	at := len(page)
	resize(page, at + size)
	r := page[at:]
	if size >= 4 {
		endian.unchecked_put_u32le(r, length)
	}
	if size >= 6 {
		endian.unchecked_put_u16le(r[4:], major)
	}
	field := 16 if major == 2 else 24
	if size > field {
		r[field] = parent
	}
}

// A page that begins with the next USN, `after`, ready for records.
@(private = "file")
page_from :: proc(after: u64) -> [dynamic]u8 {
	page := make([dynamic]u8, 8, context.temp_allocator)
	endian.unchecked_put_u64le(page[:], after)
	return page
}

// Every record's parent is collected, a version 2 one's and a version 3 one's, and
// the next read begins where the page says.
@(test)
test_a_usn_page_names_every_parent :: proc(t: ^testing.T) {
	page := page_from(4096)
	record(&page, 64, 2, 7, 64)
	record(&page, 80, 3, 9, 80)
	record(&page, 16, 4, 0, 16) // a version asked not to be sent: passed over
	parents := make(map[[16]u8]struct{}, context.temp_allocator)
	after, ok := usn_page(page[:], &parents)
	testing.expect(t, ok, "a whole page was refused")
	testing.expect_value(t, after, 4096)
	testing.expect_value(t, len(parents), 2)
	testing.expect(t, [16]u8{0 = 7} in parents, "the version 2 parent was not named")
	testing.expect(t, [16]u8{0 = 9} in parents, "the version 3 parent was not named")
}

// A record that does not cover its parent, or runs past the page, or would not move
// the read on, is not read past: the page is refused.
@(test)
test_a_usn_record_is_bounded_by_its_length :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		length: u32,
		major:  u16,
		size:   int,
	}
	cases := []Case {
		{"a version 2 record of 8 bytes at the end of the page", 8, 2, 8},
		{"a version 3 record too short for its parent", 32, 3, 32},
		{"a length near 2^32", 0xFFFF_FFF8, 2, 64},
		{"a length that does not move the read on", 0, 2, 64},
		{"a length past the page", 72, 2, 64},
		{"a header cut short", 0, 2, 4},
	}
	for c in cases {
		page := page_from(4096)
		record(&page, 64, 2, 7, 64)
		record(&page, c.length, c.major, 9, c.size)
		parents := make(map[[16]u8]struct{}, context.temp_allocator)
		_, ok := usn_page(page[:], &parents)
		testing.expectf(t, !ok, "%s: the page was read", c.name)
	}
	parents := make(map[[16]u8]struct{}, context.temp_allocator)
	_, ok := usn_page({1, 2, 3}, &parents)
	testing.expect(t, !ok, "a page shorter than its next USN was read")
}
