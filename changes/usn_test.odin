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

// A journal that answers each read with the next of `pages`, as a volume would; a
// nil page is records gone, and a read past the last fails.
@(private = "file")
Fake_Journal :: struct {
	pages: [][]u8,
	reads: int,
}

@(private = "file")
fake_read :: proc(volume: rawptr, start: i64, page: []u8) -> (got: int, answer: Usn_Answer) {
	j := (^Fake_Journal)(volume)
	if j.reads >= len(j.pages) {
		return 0, .Failed
	}
	p := j.pages[j.reads]
	j.reads += 1
	if p == nil {
		return 0, .Gone
	}
	return copy(page, p), .Read
}

// A page of one version 2 record whose parent is `parent`, the next read at `after`.
@(private = "file")
one_record :: proc(after: u64, parent: u8) -> []u8 {
	page := page_from(after)
	record(&page, 64, 2, parent, 64)
	return page[:]
}

// The journal is read page by page from the cursor to where it ended when queried.
@(test)
test_a_usn_read_goes_to_the_end :: proc(t: ^testing.T) {
	j := Fake_Journal {
		pages = {one_record(200, 1), one_record(300, 2)},
	}
	parents := make(map[[16]u8]struct{}, context.temp_allocator)
	wrapped, ok := usn_read(100, 300, fake_read, &j, &parents)
	testing.expect(t, ok && !wrapped, "a whole journal was not read")
	testing.expect_value(t, j.reads, 2)
	testing.expect_value(t, len(parents), 2)
}

/*
A read that stops short of where the journal ended, a page whose next USN does not
move on or an end of the journal before it, is not ok: since then rescans and does
not move the cursor past records it never read. Records gone say the journal wrapped.
*/
@(test)
test_a_usn_read_that_stops_short_is_not_ok :: proc(t: ^testing.T) {
	Case :: struct {
		name:    string,
		pages:   [][]u8,
		wrapped: bool,
	}
	cases := []Case {
		{"a next USN that does not move on", {one_record(200, 1), one_record(200, 2)}, false},
		{"a next USN that goes back", {one_record(200, 1), one_record(150, 2)}, false},
		{"the journal ends early", {one_record(200, 1)}, false},
		{"the records are gone", {one_record(200, 1), nil}, true},
	}
	for c in cases {
		j := Fake_Journal {
			pages = c.pages,
		}
		parents := make(map[[16]u8]struct{}, context.temp_allocator)
		wrapped, ok := usn_read(100, 300, fake_read, &j, &parents)
		testing.expectf(t, !ok, "%s: the read was ok", c.name)
		testing.expectf(t, wrapped == c.wrapped, "%s: wrapped %v", c.name, wrapped)
	}
}
