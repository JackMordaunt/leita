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
}

// Scan reads what is at path, calling off any scan still running.
Scan :: struct {
	path: Text,
}

// Stop calls off the running scan, keeping what it has read.
Stop :: struct {}
