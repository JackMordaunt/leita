/*
Package command is what sonar's window may ask of the application: the Command
union, holding only what the window knows when it asks. The view emits these, the
host decodes and carries them out; it imports nothing.

Commands are values with fixed buffers, not strings, because they cross stream
edges by copy between threads.
*/
package sonar_command

// MAX_PATH is the longest path a command carries, in bytes.
MAX_PATH :: 1024

// Text is a string that fits in a message. One that filled the buffer may have
// been cut short.
Text :: struct {
	buf: [MAX_PATH]u8,
	len: int,
}

text_make :: proc(s: string) -> (t: Text) {
	t.len = copy(t.buf[:], s)
	return
}

text_of :: proc(t: ^Text) -> string {
	return string(t.buf[:t.len])
}

Command :: union {
	Scan,
	Stop,
	Locate,
	Trash,
	Rename,
	Clean,
	Empty_Trash,
	Baseline,
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
