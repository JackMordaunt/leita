package changes

import "core:encoding/endian"

/*
The USN journal's records as FSCTL_READ_UNPRIVILEGED_USN_JOURNAL answers them: the
next USN to read from, eight bytes, then records end to end, each beginning with its
own length and version (USN_RECORD_COMMON_HEADER, Microsoft Learn). Only Windows
reads a journal; the parsing is plain bytes, kept here so every platform's tests
can feed it pages the system would never give.
*/

// RecordLength u32, MajorVersion u16, MinorVersion u16: what every record begins with.
@(private = "file")
USN_HEADER :: 8

/*
Collect into `parents` the parent directory's file id of every record on `page`, and
say where the next read begins. A record whose length does not cover what is read
from it, or runs past the page, makes the page one that cannot be trusted: not ok, so
the place is scanned whole rather than read past the record, or the rest of the page
skipped.
*/
@(private)
usn_page :: proc(page: []u8, parents: ^map[[16]u8]struct{}) -> (after: i64, ok: bool) {
	if len(page) < 8 {
		return 0, false
	}
	after = i64(endian.unchecked_get_u64le(page))
	rest := page[8:]
	for len(rest) > 0 {
		if len(rest) < USN_HEADER {
			return 0, false
		}
		// An int, which a u32 length cannot wrap, and at least a header long, so
		// every record moves the read on.
		length := int(endian.unchecked_get_u32le(rest))
		major := endian.unchecked_get_u16le(rest[4:])
		if length < usn_shortest(major) || length > len(rest) {
			return 0, false
		}
		id: [16]u8
		switch major {
		case 2:
			// USN_RECORD_V2: the parent's 64-bit reference at 16.
			copy(id[:8], rest[16:24])
			parents[id] = {}
		case 3:
			// USN_RECORD_V3: the parent's 128-bit id at 24.
			copy(id[:], rest[24:40])
			parents[id] = {}
		}
		rest = rest[length:]
	}
	return after, true
}

// How long a record of version `major` must be to hold what usn_page reads from it.
@(private = "file")
usn_shortest :: proc(major: u16) -> int {
	switch major {
	case 2:
		return 24
	case 3:
		return 40
	}
	return USN_HEADER
}
