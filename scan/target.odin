package scan

import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

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
	// root's own file reference number, found without opening the volume, so a
	// reader that can address a record directly is not limited to walking a
	// subtree. nil when root is "" or finding it failed.
	record:    Maybe(u32),
	fs:        Filesystem,
	media:     Media,
	image:     bool, // a file holding a volume rather than a mounted one
	day:       int, // the made-up disk's day, read only by the synthetic engine
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
synthetic_day is the day SYNTHETIC_ENV names, or nil when it is unset or empty; a
value that is not a whole number is day 0. The command line and the window read
it once, at startup, and hand it to resolve. The variable is the whole process's,
so reading it on each resolve let a test that set it turn a concurrent test's real
scan into the made-up disk (card 81).
*/
synthetic_day :: proc() -> Maybe(int) {
	buf: [64]byte // a day is a few digits
	value, err := os.lookup_env(buf[:], SYNTHETIC_ENV)
	if err == .Buffer_Full {
		return 0 // set, and too long to be a whole number of days
	}
	if err != nil || value == "" {
		return nil
	}
	day, _ := strconv.parse_int(value)
	return max(day, 0)
}

/*
The made-up target in place of input, when made_up names a day. It is named and
shaped as input would be, on a flash disk, so the window and the command line
show it as they would the real one; resolve asks this first.
*/
@(private)
synthetic :: proc(
	input: string,
	made_up: Maybe(int),
	allocator := context.allocator,
) -> (
	t: Target,
	c: Choice,
	ok: bool,
) {
	day := made_up.? or_return
	t.allocator = allocator
	t.input = strings.clone(input, allocator)
	t.mount = strings.clone(input, allocator)
	t.fs = .Other
	t.media = .Solid
	t.day = day
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
	// Which of a walk and the MFT reader is faster turns on how big the subtree is,
	// which nothing has said yet. Set, engine is Walk, and the reader walks no more
	// than the probe budget before asking again with what that found (Size).
	probe:                 bool,
}

/*
What is known of a subtree's size, which decides whether walking it beats reading
the volume's whole master file table. The MFT reader's cost is the volume's, whatever
the subtree holds: 5 to 30 s for a folder of four files on the hosted Windows runner
(CI runs 40020856828 to 40020975869), so a small folder walks.
*/
Size :: struct {
	prior: Maybe(u64), // entries the place held when it was last kept whole
	probe: Probe,
}

Probe :: enum {
	Unrun,
	Within, // a walk finished inside the budget
	Over, // a walk ran past it and was called off
}

/*
The most entries a walk is expected to beat the MFT reader on, which is also the
probe's budget in entries, and the probe's budget in time. A probe that runs out
wastes no more than either, so a subtree too big to walk costs at most that on top
of the MFT read it then gets; one that finishes is walked again from a warm cache.

On the hosted Windows runner's SSD (CI run 40111446955, 2026-10-24) a warm walk
took 1 ms for 10 entries, 10 ms for 1,000, 74 ms for 10,000, 0.74 s for 100,000,
2.3 s for 300,000 and 7.9 s for 1,000,000, about 7.5 us an entry. Reading the
same folders from the MFT took 3.2 to 3.5 s up to 10,000 entries, 3.9 s at
100,000, 5.5 s at 300,000 and 12.6 s at 1,000,000, as each folder grew the
volume; the whole volume, 1.35 million records, took 3.4 s. So a folder walked
faster at every size measured, and only the whole volume, which a walk would take
some 10 s over, is the MFT's. The most is set where a walk costs what the whole
volume's MFT read does: 300,000 entries, 2.3 s. The time budget is what guards a
disk that walks slower than this one, a spinning one most of all, whose seeks a
walk pays for and the MFT's sequential read does not: unmeasured, as no such
disk was at hand.
*/
WALK_MOST :: 300_000
PROBE_TIME :: 2500 * time.Millisecond

/*
Pick a reader for a target.

`readable` says the volume opened for raw reading, which is the only thing standing
between an NTFS target and the MFT reader. `resolve` finds it out and calls this; it
is a separate procedure so the whole decision table can be tested without a disk, not
because anything else needs to choose. An image needs no special case: it is a file,
so it opens.

The MFT reader takes the whole volume at once; ntfs/tree.odin's projection roots the
tree at `record` and keeps only what is under it, so a subtree gets the subtree's
answer rather than the whole volume's. Rooting alone was not enough: the rest of the
volume stayed in the tree beside the root, and the window's search found 965,681
hits in a temp folder of four files (CI run 39074211450). Finding `record` needs no
elevation: file_record in target_windows.odin asks GetFileInformationByHandle on a
handle to the subtree itself, not the raw volume. Without one, resolve either found no
record or never tried, so a subtree is walked.

With a record, the subtree's size decides. The MFT reader reads the whole volume's
table whatever the subtree holds, so a small one walks faster. `size` says what is
known: a probe's outcome first, as it measured this subtree now, then the entries the
place held when it was last kept. With neither, the choice is a walk that probes,
and the reader asks again with what the probe found. The whole volume needs no size:
it is the MFT's own cost, so it reads from the MFT straight away.
*/
choose :: proc(t: Target, readable: bool, size := Size{}) -> Choice {
	if t.fs == .Ntfs && t.root != "" && t.mount != "" {
		if !readable || t.record == nil {
			return {engine = .Walk, permission_would_help = !readable}
		}
		switch size.probe {
		case .Within:
			return {engine = .Walk}
		case .Over:
			return {engine = .Mft}
		case .Unrun:
		}
		if prior, known := size.prior.?; known {
			return {engine = .Walk if prior <= WALK_MOST else .Mft}
		}
		return {engine = .Walk, probe = true}
	}
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
