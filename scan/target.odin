package scan

import "core:mem"
import "core:strings"

/*
What the user asked to scan, resolved once so no backend has to re-derive it.

Deciding which volume a path lives on and what filesystem that volume runs is work
for the OS, not string matching, and every backend would otherwise repeat it. Doing
it here also puts the failures that are knowable up front, a path that does not
exist or a share with no volume behind it, in the one place that can explain them.
*/
Target :: struct {
	input:     string, // exactly what was given
	volume:    string, // device path to open, e.g. \\.\C:
	mount:     string, // where that volume is mounted, e.g. C:\
	root:      string, // subtree within the volume; "" means all of it
	fs:        Filesystem,
	image:     bool, // a file holding a volume rather than a mounted one
	allocator: mem.Allocator,
}

Filesystem :: enum {
	Unknown, // nothing could be learned about it
	Ntfs,
	Refs,
	Exfat,
	Fat32,
	Network,
	Other, // named, but no reader here knows it: walking is all that is left
}

/*
The top of the target, named as a path: where the volume is mounted, or the volume
itself when nothing has it mounted. No trailing separator, so a subtree joins on.
*/
top :: proc(t: Target) -> string {
	if t.mount == "" {
		return t.volume
	}
	if len(t.mount) > 1 {
		return strings.trim_right(t.mount, `\/`)
	}
	return t.mount
}

// The full path of what will be scanned: the top, and the subtree below it.
location :: proc(t: Target, allocator := context.allocator) -> string {
	if t.root == "" {
		return strings.clone(top(t), allocator)
	}
	return strings.concatenate({top(t), t.root}, allocator)
}

target_destroy :: proc(t: ^Target) {
	delete(t.input, t.allocator)
	delete(t.volume, t.allocator)
	delete(t.mount, t.allocator)
	delete(t.root, t.allocator)
	t^ = {}
}

// Which reader to use. Named here so choosing needs no knowledge of the backends
// themselves, which keeps this package free of a dependency on any of them.
Engine :: enum {
	None, // nothing here can be scanned
	Mft,  // read the NTFS master file table whole
	Walk, // enumerate directories
}

Choice :: struct {
	engine: Engine,
	// The MFT reader is far faster but needs a raw volume handle. When this is set,
	// Walk is what will run unless the caller elevates and asks again.
	elevation_would_help: bool,
}

/*
Pick a reader for a target.

The MFT reader takes the whole volume at once, so a subtree costs no more than the
root does and is far cheaper than walking it. That makes a subtree target a reason to
filter the result, never a reason to reject the reader.
*/
choose :: proc(t: Target, elevated: bool) -> Choice {
	if t.fs == .Ntfs {
		// An image is an ordinary file, so reading one needs no more than opening it.
		// It is the raw handle onto a mounted volume that has to be granted.
		if elevated || t.image {
			return {engine = .Mft}
		}
		return {engine = .Walk, elevation_would_help = true}
	}
	// Nothing mounted means no directory tree to enumerate. A raw volume and an image
	// are both bytes until a reader that knows the filesystem inside says otherwise,
	// so an unrecognised one has nothing to offer rather than something to walk.
	if t.mount == "" {
		return {engine = .None}
	}
	return {engine = .Walk}
}
