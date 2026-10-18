/*
Package command is what leita's window may ask of the application: the Command
union, holding only what the window knows when it asks. The view emits these, the
host decodes and carries them out; it imports nothing.

Commands are values with fixed buffers, not strings, because they cross stream
edges by copy between threads.
*/
package leita_command

// MAX_PATH is the longest path a command carries, in bytes.
MAX_PATH :: 1024

// Text is a string that fits in a message. cut is set when the string did not
// fit and buf holds only its start: a path so cut names an ancestor, so whoever
// acts on one must refuse it.
Text :: struct {
	buf: [MAX_PATH]u8,
	len: int,
	cut: bool,
}

text_make :: proc(s: string) -> (t: Text) {
	t.len = copy(t.buf[:], s)
	t.cut = len(s) > len(t.buf)
	return
}

text_of :: proc(t: ^Text) -> string {
	return string(t.buf[:t.len])
}

Command :: union {
	Scan,
	Stop,
	Locate,
	Open,
	Trash,
	Rename,
	Clean,
	Empty_Trash,
	Baseline,
	Export,
	Reveal,
	Add_Licence,
	Language,
	Theme,
	Monitoring,
	Watch,
	Unwatch,
	Recording,
	Check_Update,
	Apply_Update,
}

// Scan reads what is at path, calling off any scan still running.
Scan :: struct {
	path: Text,
}

// Stop calls off the running scan, keeping what it has read.
Stop :: struct {}

// Entry names an entry the window was shown: a node of one scan's tree.
Entry :: struct {
	generation: u32,
	node:       u32,
}

// Locate shows the entry in the system's file manager.
Locate :: struct {
	entry: Entry,
}

// Open opens the entry in the application the system opens it with: a file
// in its default application, a folder in the file manager.
Open :: struct {
	entry: Entry,
}

// Trash moves the entry to the Trash and takes it out of the totals.
Trash :: struct {
	entry: Entry,
}

// Rename gives the entry a new name in the same folder.
Rename :: struct {
	entry: Entry,
	name:  Text,
}

// MAX_CLEAN is the most entries one Clean carries; a bigger selection is sent as
// several.
MAX_CLEAN :: 256

// Clean deletes entries for good, each a candidate Reclaim found: what a build or
// a tool made and will make again. The host deletes only those it found itself.
Clean :: struct {
	generation: u32,
	nodes:      [MAX_CLEAN]u32,
	count:      int,
}

// Empty_Trash deletes what the Trash holds, for good.
Empty_Trash :: struct {
	entry: Entry,
}

// Baseline is the earlier snapshot of the scan's place to compare it with, 0 for
// none (query.History).
Baseline :: struct {
	generation: u32,
	snapshot:   i64,
}

// Export_Format is what an Export writes, as report.Format names them.
Export_Format :: enum u8 {
	Csv,
	Json,
	Html,
	Pdf,
}

// EXTENSIONS end the name of a report in each format.
EXTENSIONS := [Export_Format]string {
	.Csv  = ".csv",
	.Json = ".json",
	.Html = ".html",
	.Pdf  = ".pdf",
}

// Export writes a report of the finished scan, with what Reclaim finds when
// reclaim is set, and says where in a notice: to path, replacing what is there,
// as the person chose in the save dialog, or when path is empty to a file of its
// own in the reports folder.
Export :: struct {
	generation: u32,
	format:     Export_Format,
	reclaim:    bool,
	path:       Text,
}

// Reveal shows the file a notice said was saved in the system's file manager.
Reveal :: struct {
	notice: u32,
}

// Add_Licence offers a licence to use from now on, in place of any before it:
// the licence itself as pasted, the licence key the shop's receipt gives, which
// the host exchanges for its licence, or when file is set the path of a file
// holding one. The host checks it and says how it went in query.Licence.
Add_Licence :: struct {
	text: Text,
	file: bool,
}

// Language is the language the window is in, an i18n.Locale's value, which
// this package does not import: the host words its notices and answers in it
// from now on. chosen says the person picked it, so it is remembered for the
// next run; the language the window opens in is only followed.
Language :: struct {
	locale: u8,
	chosen: bool,
}

// Theme is the theme the person chose, remembered for the next run.
Theme :: struct {
	dark: bool,
}

// Monitoring turns monitoring on, handing it to the system's scheduler, or off,
// taking it back.
Monitoring :: struct {
	on: bool,
}

// Watch has the monitor scan the place at path every every (query.Frequency's
// value, which this package does not import), checking each scan against the
// limits given, each 0 or false for none, in place of any it had.
Watch :: struct {
	path:        Text,
	every:       u8,
	warn_used:   int, // percent used
	fail_used:   int, // percent used
	min_free:    u64, // bytes
	full_within: int, // days
	growth:      bool,
}

// Unwatch stops the monitor scanning the place at path.
Unwatch :: struct {
	path: Text,
}

// Check_Update asks the release page whether a newer Leita is out, and says what
// it found in query.Update. It is sent only when a person asks, from About;
// nothing in Leita checks on its own.
Check_Update :: struct {}

// Apply_Update downloads the release's build of this window and replaces the
// running file with it, when a check found one and this copy can be replaced in
// place (query.Update_Result.can_apply); the new one runs on the next start.
Apply_Update :: struct {}

// Recording turns the recorder of changes on or off, on Linux: this binary's
// `journal on` or `journal off`, under pkexec for the administrator's rights it
// needs.
Recording :: struct {
	on: bool,
}
