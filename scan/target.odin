package scan

import "core:mem"
import "core:os"
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
	media:     Media,
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

// SYNTHETIC_ENV names the day of a made-up disk to scan in place of whatever is
// asked for, so a demo or a screenshot shows no one's real files. Unset or empty,
// every target is real.
SYNTHETIC_ENV :: "LEITA_SYNTHETIC"

/*
The made-up target in place of input, when SYNTHETIC_ENV asks for one. It is
named and shaped as input would be, on a flash disk, so the window and the
command line show it as they would the real one; resolve asks this first.
*/
synthetic :: proc(
	input: string,
	allocator := context.allocator,
) -> (
	t: Target,
	c: Choice,
	ok: bool,
) {
	if os.get_env(SYNTHETIC_ENV, context.temp_allocator) == "" {
		return {}, {}, false
	}
	t.allocator = allocator
	t.input = strings.clone(input, allocator)
	t.mount = strings.clone(input, allocator)
	t.fs = .Other
	t.media = .Solid
	return t, {engine = .Synthetic}, true
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

/*
What stores the volume, which decides how many reads it serves well at once.

Flash has no head to move, so reads in flight are served side by side, and a reader
that keeps many going finishes sooner: on an Apple NVMe drive, 16 directory readers
took 12.5 s where 8 took 15.8 s. A spinning disk serves one place at a time,
and each read in flight beyond the first sends the head somewhere else. That seeking
between them costs more than the overlap gains is assumed, not measured: no spinning
disk was at hand to time.
*/
Media :: enum {
	Unknown, // the volume did not say: a network share, an image, a reader that is silent
	Solid,
	Rotational,
}

// Which reader to use. Named here so choosing needs no knowledge of the backends
// themselves, which keeps this package free of a dependency on any of them.
Engine :: enum {
	None, // nothing here can be scanned
	Mft, // read the NTFS master file table whole
	Walk, // enumerate directories
	Synthetic, // make a disk up, with no one's real files in it (package synth)
}

Choice :: struct {
	engine:                Engine,
	// The MFT reader is far faster but needs to open the volume raw. When this is
	// set, Walk is what will run unless the caller obtains that and asks again.
	permission_would_help: bool,
}

/*
Pick a reader for a target.

`readable` says the volume opened for raw reading, which is the only thing standing
between an NTFS target and the MFT reader. `resolve` finds it out and calls this; it
is a separate procedure so the whole decision table can be tested without a disk, not
because anything else needs to choose. An image needs no special case: it is a file,
so it opens.

The MFT reader takes the whole volume at once, so a subtree costs no more than the
root does and is far cheaper than walking it. That makes a subtree target a reason to
filter the result, never a reason to reject the reader.
*/
@(private)
choose :: proc(t: Target, readable: bool) -> Choice {
	if t.fs == .Ntfs {
		if readable {
			return {engine = .Mft}
		}
		return {engine = .Walk, permission_would_help = true}
	}
	// Nothing mounted means no directory tree to enumerate. A raw volume and an image
	// are both bytes until a reader that knows the filesystem inside says otherwise,
	// so an unrecognised one has nothing to offer rather than something to walk.
	if t.mount == "" {
		return {engine = .None}
	}
	return {engine = .Walk}
}
