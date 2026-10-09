/*
Package query is what estoile's window may read: each query is a pair, the params a
need asks with and the result it is answered with, named Name and Name_Result. The
view needs these; the host answers them from the scan, again every time the scan
has moved on, for as long as the need is live. It imports nothing.

Every type here is plain data: it crosses a pipe or a wire as cbor, under its
"estoile_query.Name" kind, and ui.need keys a query by its bytes.

A node is an index into one scan's tree, meaningful only within the scan that
numbered it, so every query that names one also names the scan's generation. A
query for a generation that is gone is answered empty rather than wrongly.
*/
package estoile_query

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
	// The filesystem the target is on: its size, and what is free to this user.
	// Both 0 when nothing could say, as for a device or image nothing mounts.
	disk_total: u64,
	disk_free:  u64,
	notice:     Notice, // what came of the window's last request
	exporting:  bool, // a report is being written; its notice says how it went
}

// Notice is what came of a request the window made: an entry moved to the
// Trash, renamed, a report saved, or why not. id moves on with each, so a
// dismissed notice stays dismissed until there is a new one. saved is set when
// it names a file just written, which command.Reveal shows.
Notice :: struct {
	id:     u32,
	failed: bool,
	saved:  bool,
	text:   string,
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
	was:       i64, // what it held in the snapshot compared with, or -1 (History)
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
	was:        i64, // and in the snapshot compared with, or -1
	compared:   bool, // whether a snapshot is compared with, so was says anything
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
	node:   u32,
	parent: u32, // the directory holding it
	within: []u32, // the directories it lies in, nearest first, up to the top of the scan
	path:   string,
	bytes:  u64,
	was:    i64, // what it held in the snapshot compared with, or -1
}

Largest_Result :: struct {
	files:    []File, // largest first, at most LARGEST_LIMIT
	compared: bool, // whether a snapshot is compared with, so was says anything
}

LARGEST_LIMIT :: 20

// Rings is a directory's contents to RING_DEPTH levels deep, each laid out as its
// share of what holds it: the sunburst draws them as rings, the treemap as boxes
// within boxes.
Rings :: struct {
	generation: u32,
	dir:        u32, // ROOT for the top of the scan
}

// Arc is one entry in a ring. Its sweep is its share of its parent's, so the
// sweeps in a ring never add to more than their parent's. The arcs under one come
// largest first.
Arc :: struct {
	node:      u32,
	name:      string,
	bytes:     u64,
	directory: bool,
	depth:     u8, // 1 for the first ring
	branch:    u8, // which entry of the first ring it lies under, for its colour
	start:     f32, // turns clockwise from twelve o'clock, 0 to 1
	sweep:     f32, // turns
	up:        i32, // the index of the arc it lies in, -1 for the first ring
	was:       i64, // what it held in the snapshot compared with, or -1
}

Rings_Result :: struct {
	generation: u32,
	dir:        u32, // the directory at the centre, ROOT resolved
	crumbs:     []Crumb, // from the top down to dir, inclusive
	bytes:      u64,
	was:        i64, // what dir held in the snapshot compared with, or -1
	compared:   bool, // whether a snapshot is compared with, so was says anything
	arcs:       []Arc, // ring by ring is not promised; each arc carries its depth
}

// RING_DEPTH is how many rings a sunburst draws.
RING_DEPTH :: 5

// MIN_SWEEP is the narrowest arc drawn, in turns: half a degree. Anything
// narrower could not be seen or pointed at, so it is left out with all it holds.
MIN_SWEEP :: 1.0 / 720

// MAX_ARCS caps a sunburst, so a directory of a million tiny files cannot send
// a million arcs.
MAX_ARCS :: 6000

/*
History is the earlier scans of the place scanned that it can be compared with,
and which it is compared with. Each finished scan is kept, and compared with the
last before it until another is chosen (command.Baseline).

While a snapshot is compared with, every entry, arc and file answered carries
was: what it held then. -1 says it was not kept: under KEPT_MIN
then, or not there at all, which an entry that holds less than that now cannot
tell apart. Entries since deleted are not answered; their parent's was carries
them.
*/
History :: struct {
	generation: u32,
}

// KEPT_MIN is the least an entry holds to be kept in a snapshot: one that holds
// less now may not have been, so was -1 says nothing about it.
KEPT_MIN :: 1 << 20

// Snapshot is one earlier scan: when it was taken, in Unix seconds, and its
// totals.
Snapshot :: struct {
	id:    i64,
	taken: i64,
	bytes: u64,
	items: u64,
}

History_Result :: struct {
	generation: u32,
	kept:       bool, // whether scans are kept at all
	ready:      bool, // the scan is finished, and kept
	snapshots:  []Snapshot, // the earlier ones, newest first
	compared:   Snapshot, // the one compared with; id 0 for none
}

// Reclaim is what can be deleted under a directory to free space without losing
// anything: what builds and tools made and will make again.
Reclaim :: struct {
	generation: u32,
	dir:        u32, // ROOT for the top of the scan
}

// Candidate is one thing Reclaim offers: a directory, deleted whole.
Candidate :: struct {
	node:     u32,
	path:     string,
	bytes:    u64,
	modified: i64, // the newest modification of it or what it directly holds, Unix seconds; 0 unknown
	recent:   bool, // modified within RECLAIM_RECENT_DAYS: likely in use, so not chosen at first
}

// Reclaim_Group is the candidates of one kind and why they are safe.
Reclaim_Group :: struct {
	name:   string,
	reason: string,
	trash:  bool, // the Trash: emptied, not deleted
	items:  []Candidate,
	bytes:  u64,
}

Reclaim_Result :: struct {
	generation: u32,
	ready:      bool, // false while the scan runs: Reclaim looks once it is done
	groups:     []Reclaim_Group,
	bytes:      u64,
}

// RECLAIM_RECENT_DAYS is how recently touched a candidate is left unchosen.
RECLAIM_RECENT_DAYS :: 7
