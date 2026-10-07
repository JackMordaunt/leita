/*
Package query is what sonar's window may read: each query is a pair, the params a
need asks with and the result it is answered with, named Name and Name_Result. The
view needs these; the host answers them from the scan, again every time the scan
has moved on, for as long as the need is live. It imports nothing.

Every type here is plain data: it crosses a pipe or a wire as cbor, under its
"sonar_query.Name" kind, and ui.need keys a query by its bytes.

A node is an index into one scan's tree, meaningful only within the scan that
numbered it, so every query that names one also names the scan's generation. A
query for a generation that is gone is answered empty rather than wrongly.
*/
package sonar_query

// ROOT names the top of whatever was scanned, before the view knows its index.
ROOT :: max(u32)

State :: enum u8 {
	Idle, // nothing has been asked for
	Scanning,
	Done,
	Stopped, // called off part way; what was read is still shown
	Failed,
}

// Progress is how the current scan is going.
Progress :: struct {}

Progress_Result :: struct {
	generation: u32, // moves on with every scan started
	state:      State,
	target:     string, // the path being scanned
	engine:     string, // which reader: "MFT", "walk"
	slow:       bool, // a raw read of this volume would be far faster, given permission
	nodes:      u64, // records read so far
	bytes:      u64,
	pending:    int, // read, but waiting on a parent before they can be counted
	seconds:    f64, // since the scan began, or how long it took
	problem:    string, // why it failed
}

// Listing is a directory's contents, largest first.
Listing :: struct {
	generation: u32,
	dir:        u32, // ROOT for the top of the scan
}

Entry :: struct {
	node:      u32,
	name:      string,
	bytes:     u64, // on disk; a directory's counts everything under it found so far
	directory: bool,
}

// Crumb is one directory on the way down from the top to a listing.
Crumb :: struct {
	node: u32,
	name: string,
}

Listing_Result :: struct {
	generation: u32,
	dir:        u32, // the directory listed, ROOT resolved
	crumbs:     []Crumb, // from the top down to dir, inclusive
	bytes:      u64, // the directory's own total
	entries:    []Entry, // the largest, at most LISTING_LIMIT
	more:       int, // entries past the limit
	more_bytes: u64, // and what they hold between them
}

// LISTING_LIMIT is the most entries a listing carries.
LISTING_LIMIT :: 200

// Largest is the largest files anywhere in the scan.
Largest :: struct {
	generation: u32,
}

// File is one of the largest files, named by its whole path.
File :: struct {
	node:  u32,
	path:  string,
	bytes: u64,
}

Largest_Result :: struct {
	files: []File, // largest first, at most LARGEST_LIMIT
}

LARGEST_LIMIT :: 20
