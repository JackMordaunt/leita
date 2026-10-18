/*
Package query is what leita's window may read: each query is a pair, the params a
need asks with and the result it is answered with, named Name and Name_Result. The
view needs these; the host answers them from the scan, again every time the scan
has moved on, for as long as the need is live. It imports nothing.

Frequency type here is plain data: it crosses a pipe or a wire as cbor, under its
"leita_query.Name" kind, and ui.need keys a query by its bytes.

A node is an index into one scan's tree, meaningful only within the scan that
numbered it, so every query that names one also names the scan's generation. A
query for a generation that is gone is answered empty rather than wrongly.
*/
package leita_query

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
	reports:    string, // the folder the save dialog opens in, and a report goes to when it names none; "" for none
	// How the scan read its place, with history on (kept): updated from the last
	// scan's tree, `reread` directories read again since `since` (unix seconds), or
	// whole, and `why`, in survey's English. Nothing is said with history off.
	kept:       bool,
	updated:    bool,
	reread:     u64,
	since:      i64,
	why:        string,
	// Directories the scan could not open, so left out of every total, and whether
	// permission was what any of them lacked.
	unread:     u64,
	denied:     bool,
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
	node:       u32,
	name:       string,
	bytes:      u64, // on disk; a directory's counts everything under it found so far
	directory:  bool,
	was:        i64, // what it held in the snapshot compared with, or -1 (History)
	// A directory the walk left short, so its total is less than it holds: it, or a
	// directory under it, could not be opened or listed, or, in a scan stopped or
	// failed, has no entries yet, which an empty one cannot be told from.
	incomplete: bool,
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
	gone:       bool, // dir was forgotten (moved to the Trash, cleaned up), so nothing else is set but up
	up:         u32, // when gone, the nearest ancestor the scan still holds
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
	node:       u32,
	name:       string,
	bytes:      u64,
	directory:  bool,
	depth:      u8, // 1 for the first ring
	branch:     u8, // which entry of the first ring it lies under, for its colour
	start:      f32, // turns clockwise from twelve o'clock, 0 to 1
	sweep:      f32, // turns
	up:         i32, // the index of the arc it lies in, -1 for the first ring
	was:        i64, // what it held in the snapshot compared with, or -1
	incomplete: bool, // as for an Entry
}

Rings_Result :: struct {
	generation: u32,
	dir:        u32, // the directory at the centre, ROOT resolved
	crumbs:     []Crumb, // from the top down to dir, inclusive
	bytes:      u64,
	was:        i64, // what dir held in the snapshot compared with, or -1
	compared:   bool, // whether a snapshot is compared with, so was says anything
	arcs:       []Arc, // ring by ring is not promised; each arc carries its depth
	// The scan was stopped or failed, or dir itself could not be read whole, so the
	// chart shows less than is there.
	incomplete: bool,
	gone:       bool, // dir was forgotten (moved to the Trash, cleaned up), so nothing else is set but up
	up:         u32, // when gone, the nearest ancestor the scan still holds
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

/*
Record is what leita changed on disk at the person's request, newest first: the
audit trail the History dialog lists. It is the same record leita history
prints.
*/
Record :: struct {}

// RECORD_LIMIT is the most actions a Record_Result carries: the newest.
RECORD_LIMIT :: 1000

// Action is one change leita made, or tried to: when, in Unix seconds, the path,
// what it held, and how it went.
Action :: struct {
	taken:      i64,
	path:       string,
	bytes:      u64,
	failed:     bool,
	why:        string, // when it failed; "" if it did not or no reason is known
	renamed_to: string, // for a rename that went through
}

Record_Result :: struct {
	kept:    bool, // whether there is a record at all: the store could be opened
	actions: []Action,
}

// Licence is the licence leita runs under, and how the last one offered went.
Licence :: struct {}

Licence_Result :: struct {
	licensed:   bool, // a licence is in use; the rest says whose
	licensee:   string,
	tier:       string, // as the window shows it
	order:      string,
	issued:     string, // YYYY-MM-DD
	activating: bool, // a licence key is out being exchanged for its licence
	unlocked:   bool, // the paid features work: licensed, or in the trial
	trial_left: int, // whole days of the trial left, 0 once it is over
	// The last licence offered (command.Add_Licence): offered moves on with each,
	// and problem says why it was not taken, "" when it was.
	offered:    u32,
	problem:    string,
}

// Update is where a check for a newer Leita stands, which About shows. Nothing
// asks on its own: it is Idle until a person sends command.Check_Update.
Update :: struct {}

Update_State :: enum u8 {
	Idle, // no check has been asked for
	Checking,
	Current, // this is the latest release
	Available, // a newer release is out; latest says which
	Applying, // downloading it, to replace this window
	Applied, // replaced; the new one runs when Leita next starts
	Failed, // problem says why
}

// Update_Problem is why a check or an update failed, for the window to word.
Update_Problem :: enum u8 {
	None,
	No_Library, // libcurl is not on this system
	Unreachable, // the release page could not be reached
	Not_Published, // the release does not hold this window's build
	Other, // detail says
}

Update_Result :: struct {
	state:     Update_State,
	latest:    string, // the release's version, "" when it did not say
	// Available: this copy can be replaced in place. When not (a package, an
	// AppImage, the installer's copy, Leita.app, a development build) the
	// window sends the person to page instead.
	can_apply: bool,
	problem:   Update_Problem,
	detail:    string, // English, from the update package, when problem is Other
	page:      string, // where to download a release by hand
}

// Settings is what the person chose in an earlier run, for the window to open
// as they left it.
Settings :: struct {}

// Theme_Choice is the theme chosen, or Unset to follow the window's default.
Theme_Choice :: enum u8 {
	Unset,
	Light,
	Dark,
}

Settings_Result :: struct {
	language: string, // a BCP 47 tag, as i18n.locale_tag gives it; "" when none was chosen
	theme:    Theme_Choice,
}

/*
Search is the entries anywhere in the scan whose paths hold term: its
characters in order, not necessarily together, ranked by how well they line up,
in the manner of fzf (package search). The scan is searched as it stands, part way
or finished, never scanned again, and answered again as it finds more. Each
term is a need of its own, so the need going calls off its search.
*/
Search :: struct {
	generation: u32,
	term:       string,
}

// Mark is a stretch of a hit's path the term matched, as byte offsets: from up
// to but not including to.
Mark :: struct {
	from, to: u32,
}

// Hit is one entry a search found.
Hit :: struct {
	node:      u32,
	parent:    u32, // the directory holding it
	path:      string, // whole, from the top of the filesystem
	name_at:   u32, // where its own name starts in path
	marks:     []Mark, // in order, none overlapping
	bytes:     u64, // on disk; a directory's counts everything under it found so far
	directory: bool,
}

Search_Result :: struct {
	generation: u32,
	term:       string,
	hits:       []Hit, // best first, at most SEARCH_LIMIT
	total:      int, // every entry that matched, not only those sent
	complete:   bool, // the scan is over and searched to its end
}

// SEARCH_LIMIT is the most hits a search sends.
SEARCH_LIMIT :: 500

// Thumb is a picture's thumbnail, fitted into a square px across. The host
// reads the picture off the disk on a worker, and keeps what it made by the
// file's path and time, so a picture is decoded once until it changes.
Thumb :: struct {
	path: string,
	px:   int,
}

// Thumb_Result names an image file the renderer reads, "" when the picture
// could not be read.
Thumb_Result :: struct {
	image: string,
}

/*
Monitor is monitoring, a paid feature: whether it is on, the places it watches
and how each one's last scan went. The host reads it from settings.db, which
the monitor's runs write while the window is closed, and answers again after
each change the window asks for (command.Monitoring, Watch, Unwatch, Recording).
*/
Monitor :: struct {}

// Frequency is how often a watched place is scanned, as settings.Frequency has it.
Frequency :: enum u8 {
	Hourly,
	Daily,
	Weekly,
}

// Watched_Place is one place the monitor scans, what its scans are checked
// against, and how its last scan went: scanned is false until it has run once;
// problem is why it failed, "" when it did not; alerting is whether anything
// was wrong after it.
Watched_Place :: struct {
	place:       string,
	every:       Frequency,
	warn_used:   int, // percent used, 0 for none
	fail_used:   int, // percent used, 0 for none
	min_free:    u64, // bytes, 0 for none
	full_within: int, // days, 0 for none
	growth:      bool,
	scanned:     bool,
	started:     i64, // Unix seconds
	seconds:     f64,
	bytes:       u64,
	problem:     string,
	alerting:    bool,
}

// Raised_Alert is an alert a scheduled scan raised, when, worded in the
// window's language.
Raised_Alert :: struct {
	place:  string,
	raised: i64, // Unix seconds
	text:   string,
}

// MONITOR_ALERTS_LIMIT is the most alerts a Monitor_Result carries, newest first.
MONITOR_ALERTS_LIMIT :: 20

Monitor_Result :: struct {
	on:               bool,
	scheduler:        string, // where the system keeps the schedule, as a person would look for it
	// Each change asked for moves changed on once it is made or refused;
	// problem says why it was refused, "" when it was made. note is anything
	// the person should know of how scans will run here, in every answer from
	// the first whether monitoring is on or not.
	changed:          u32,
	problem:          string,
	note:             string,
	watched:          []Watched_Place, // in the order they were added
	alerts:           []Raised_Alert, // of every place, newest first, at most MONITOR_ALERTS_LIMIT
	// The recorder of changes, shown on Linux only: whether its service is
	// installed, and whether it runs.
	recorder_shown:   bool,
	recorder_on:      bool,
	recorder_running: bool,
}
