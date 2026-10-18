package changes

import "core:encoding/endian"
import "core:slice"

/*
The USN journal's records as FSCTL_READ_UNPRIVILEGED_USN_JOURNAL answers them: the
next USN to read from, eight bytes, then records end to end, each beginning with its
own length and version (USN_RECORD_COMMON_HEADER, Microsoft Learn). Only Windows
reads a journal; the parsing is plain bytes, kept here so every platform's tests
can feed it pages the system would never give.
*/

// What one read of the journal gave.
@(private)
Usn_Answer :: enum {
	Read, // a page of records
	Gone, // the records from where the read began were deleted: the journal wrapped
	Failed, // anything else
}

/*
One read of the journal `volume` names, from USN `start`, into `page`: how many bytes
it filled. A procedure, not the call itself, so tests can stand in for a volume.
*/
@(private)
Usn_Read :: #type proc(volume: rawptr, start: i64, page: []u8) -> (got: int, answer: Usn_Answer)

/*
Read the journal from `start` to `end`, where it ended when it was queried,
collecting the parent of every record. `wrapped` when the records from `start` are
gone. Not ok when a page cannot be trusted, or a read stops short of `end`: a page
whose next USN does not move on leaves the records up to `end` unread, and a cursor
moved to `end` would skip them for good.
*/
@(private)
usn_read :: proc(
	start, end: i64,
	read: Usn_Read,
	volume: rawptr,
	parents: ^map[[16]u8]struct{},
) -> (
	wrapped, ok: bool,
) {
	// Eight-byte words, so the records the system writes in place are aligned.
	buf: [64 * 1024 / size_of(u64)]u64
	page := slice.to_bytes(buf[:])
	for at := start; at < end; {
		got, answer := read(volume, at, page)
		switch answer {
		case .Gone:
			return true, false
		case .Failed:
			return false, false
		case .Read:
		}
		if got > len(page) {
			return false, false
		}
		after, parsed := usn_page(page[:got], parents)
		if !parsed || after <= at {
			return false, false
		}
		at = after
	}
	return false, true
}

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
