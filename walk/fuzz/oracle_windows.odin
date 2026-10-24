#+build windows
package walk_fuzz

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

import ntfs "../../ntfs"
import scan "../../scan"

/*
The second reader on Windows is leita's MFT reader, the one an elevated scan of an
NTFS folder uses (survey/fill.odin, fill_mft): it reads the volume's table and
projects it onto the folder's record. It is held to the spec as the walk is, by the
same model, with two differences it cannot help. It reads every record, so a
directory the walk is refused is read through, and it is compared with the model
of a scan that is not refused (`denies` false). And a record carries no reparse
tag, so it cannot tell a junction or a symlink from a mount point: those are one
count, links, against the model's symlinks and mounts together.

The bytes it charges the files are held to what Win32 says of the same files
(`allocated`). The walk was held to both first, so when the two readers disagree
it is the MFT reader that is wrong, and the failure says so.

Reading a volume needs an administrator. Where it cannot be opened, this says so
once and compares nothing.
*/

@(private)
mft_once: sync.Once
@(private)
mft_reason: string

// mft_unreadable is why the pool's volumes cannot be read raw, "" when they
// can. It is asked once, and the reason kept in `allocator` for the process.
@(private)
mft_unreadable :: proc(allocator: runtime.Allocator) -> string {
	allocator := allocator
	sync.once_do(&mft_once, proc(data: rawptr) {
		allocator := (^runtime.Allocator)(data)^
		if probe(allocator) != "" {
			mft_reason = "no volumes"
			return
		}

		h := open_volume(pool[0].guid, false, allocator)
		if h == win.INVALID_HANDLE_VALUE {
			mft_reason = fmt.aprintf(
				"the MFT reader is not compared: the volume would not open (%d), which needs an administrator",
				win.GetLastError(),
				allocator = allocator,
			)
			fmt.eprintln("tree:", mft_reason)
			return
		}
		win.CloseHandle(h)
	}, &allocator)
	return mft_reason
}

// open_volume opens a volume by its \\?\Volume{...}\ name, to read it or, with
// `write`, to flush it.
@(private)
open_volume :: proc(guid: string, write: bool, allocator: runtime.Allocator) -> win.HANDLE {
	access := win.GENERIC_READ
	if write {
		access |= win.GENERIC_WRITE
	}
	return win.CreateFileW(
		wide(strings.trim_right(guid, `\`), allocator),
		access,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
		nil,
		win.OPEN_EXISTING,
		0,
		nil,
	)
}

second_reader :: proc(spec: Spec, fx: ^Fixture, start: int, allocator: runtime.Allocator) -> (class, what: string) {
	if mft_unreadable(runtime.heap_allocator()) != "" {
		return "", ""
	}
	guid := pool[0].guid
	if start != 0 {
		guid = fx.volumes[start]
	}
	record, found := record_of(fx.paths[start], allocator)
	if !found {
		return "mft", format_reason(allocator, "no file id for %s: %d", fx.paths[start], win.GetLastError())
	}
	// What was written is in the cache until the volume is flushed, and the reader
	// reads the disk under it. `build` flushed what it made; this is for what a
	// mutator changed since.
	flush(guid, allocator)
	want, reps := expected(spec, start, false, allocator)
	disk, err := allocated(fx, reps, allocator)
	if err != "" {
		return "materialiser", err
	}

	got, bytes, why := mft_read(guid, fx.paths[start], record, allocator)
	if why != "" {
		return "mft", why
	}
	model := Mft_Tally {
		files  = want.files,
		extras = want.extras,
		dirs   = want.dirs,
		links  = want.symlinks + want.mounts,
	}
	if got != model {
		return "mft", format_reason(
			allocator,
			"the MFT reader is wrong: %s (the model of a scan not refused; the walk agreed with its model)",
			differ_mft(model, got, allocator),
		)
	}

	if bytes < disk || bytes > disk + spill_room(fx, reps, allocator) {
		return "mft disk", format_reason(
			allocator,
			"the MFT reader is wrong: Win32 says the files occupy %d bytes, the MFT reader %d (the walk agreed with Win32)%s",
			disk,
			bytes,
			describe_files(fx, reps, allocator),
		)
	}
	return "", ""
}

/*
spill_room is how far the MFT reader may charge above Win32 for the files named
by `nodes`: a cluster for each file with more than one name. The reader charges
every attribute a record keeps out of it, and a file's names can outgrow its
record: a 511-byte file with eight names was charged a cluster of 4096 beside
its data, which FileStandardInfo and the cluster map of its data leave out (seed
4 of the tree suite), most likely for an attribute list, which a walk cannot see.
*/
@(private)
spill_room :: proc(fx: ^Fixture, nodes: []int, allocator: runtime.Allocator) -> (room: u64) {
	for id in nodes {
		if f, why := figures(fx.paths[id], allocator); why == "" && f.links > 1 {
			room += f.cluster
		}
	}
	return
}

// mft_read is the MFT reader's count of the tree under `record` on the volume
// `guid`, and the bytes it charges the files there.
@(private)
mft_read :: proc(guid, root: string, record: u32, allocator: runtime.Allocator) -> (got: Mft_Tally, bytes: u64, why: string) {
	m: ntfs.Mft
	defer ntfs.mft_destroy(&m)

	if e := ntfs.read_mft(strings.trim_right(guid, `\`), &m); e != nil {
		return {}, 0, format_reason(allocator, "the MFT reader could not read %s: %v", guid, e)
	}
	t: scan.Tree
	if scan.tree_init(&t, 1) != .None {
		return {}, 0, "no tree"
	}
	defer scan.tree_destroy(&t)

	p := ntfs.Projection {
		root_name   = root,
		root_record = record,
	}
	defer ntfs.projection_destroy(&p)

	if e := ntfs.to_tree(&m, &t, &p); e != .None {
		return {}, 0, format_reason(allocator, "the MFT reader's tree: %v", e)
	}
	got, bytes = mft_tally(&t)
	return
}

// describe_files is what Win32 says of each file, a line each, for a failure
// over bytes: which file the readers disagree on is the first thing to know.
@(private)
describe_files :: proc(fx: ^Fixture, nodes: []int, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	for id, k in nodes {
		if k == 12 {
			fmt.sbprintf(&b, "\n  and %d more", len(nodes) - k)
			break
		}
		f, why := figures(fx.paths[id], allocator)
		if why != "" {
			fmt.sbprintf(&b, "\n  %s", why)
			continue
		}
		fmt.sbprintf(
			&b,
			"\n  %s: length %d, allocation %d, occupied %d, mapped %d, attributes %x, cluster %d",
			fx.paths[id][len(fx.root):],
			f.length,
			f.allocation,
			f.occupied,
			f.mapped,
			f.attributes,
			f.cluster,
		)
	}
	return strings.to_string(b)
}
// flush writes what a volume holds in the cache to the disk. It needs an
// administrator, as reading the volume does.
@(private)
flush :: proc(guid: string, allocator: runtime.Allocator) {
	if h := open_volume(guid, true, allocator); h != win.INVALID_HANDLE_VALUE {
		win.FlushFileBuffers(h)
		win.CloseHandle(h)
	}
}

// record_of is the MFT record of the directory at `path`, through a mount point
// to the root of the volume mounted there.
@(private)
record_of :: proc(path: string, allocator: runtime.Allocator) -> (record: u32, ok: bool) {
	h := win.CreateFileW(
		wide(path, allocator),
		win.FILE_READ_ATTRIBUTES,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		return 0, false
	}
	defer win.CloseHandle(h)

	info: win.BY_HANDLE_FILE_INFORMATION
	if !win.GetFileInformationByHandle(h, &info) {
		return 0, false
	}
	// The low 48 bits of the file reference are the record, and a volume this
	// small has fewer than 2^32 of them.
	return info.nFileIndexLow, true
}

// Mft_Tally is what the MFT reader can count: links are junctions, symlinks and
// mount points, which its records do not tell apart.
@(private)
Mft_Tally :: struct {
	files, extras, dirs, links: int,
}

// mft_tally counts the MFT reader's tree and adds up the bytes of its files, a
// hard link group once, leaving out what the volume came with.
@(private)
mft_tally :: proc(t: ^scan.Tree) -> (out: Mft_Tally, bytes: u64) {
	for i in 0 ..< scan.slots(t) {
		n := scan.node(t, i)
		flags := scan.node_flags(n)
		if .Used not_in flags || from_volume(t, i) {
			continue
		}
		switch {
		case .Reparse in flags:
			out.links += 1
		case .Directory in flags:
			out.dirs += 1
		case .Extra_Name in flags:
			out.extras += 1
		case:
			out.files += 1
			bytes += n.disk
		}
	}
	return
}

@(private)
differ_mft :: proc(want, got: Mft_Tally, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	check :: proc(b: ^strings.Builder, what: string, want, got: int) {
		if want != got {
			if strings.builder_len(b^) > 0 {
				strings.write_string(b, "; ")
			}
			fmt.sbprintf(b, "%s want %d got %d", what, want, got)
		}
	}
	check(&b, "files", want.files, got.files)
	check(&b, "extra names", want.extras, got.extras)
	check(&b, "dirs", want.dirs, got.dirs)
	check(&b, "links and mounts", want.links, got.links)
	return strings.to_string(b)
}

// from_volume says whether a node of a scanned tree is, or lies under, something
// the volume came with rather than the spec: an entry at the root named as
// foreign_name names them. Only a scan from a tmpfs, the root of a volume, meets
// one. Windows fills System Volume Information on its own time after a volume is
// mounted, and an administrator's walk may read into it, as the MFT reader does.
from_volume :: proc(t: ^scan.Tree, i: u32) -> bool {
	at := i
	for _ in 0 ..< 4096 {
		if at == t.root {
			return false
		}
		up := scan.node(t, at).parent
		if up == t.root {
			return foreign_name(scan.name_of(t, at))
		}
		if up == at {
			return false
		}
		at = up
	}
	return false
}

