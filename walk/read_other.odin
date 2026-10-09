#+build !linux
#+build !darwin
package walk

import "core:mem"
import "core:os"
import "core:strings"

/*
Read one directory through core:os.

The reader that works anywhere. core:os describes every entry in full and this keeps
the part the tree records, which is most of what it costs: not knowing the platform
means not knowing which of that description was worth asking for.
*/
@(private)
read_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	f, open_err := os.open(d.path)
	if open_err != nil {
		return 0, 0, false
	}
	defer os.close(f)

	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)

	for info in os.read_directory_iterator(&it) {
		if _, err := os.read_directory_iterator_error(&it); err != nil {
			continue
		}
		e := Entry {
			name      = info.name,
			directory = info.type == .Directory,
			symlink   = info.type == .Symlink,
		}
		if !e.directory && !e.symlink {
			// core:os reports the logical length and nothing about allocation, so the
			// on-disk figure is the best estimate available here: the size rounded up
			// to a block.
			e.disk = round_up(u64(max(info.size, 0)), BLOCK_ESTIMATE)
		}
		index, descend, charged, recorded := record(w, d.index, e)
		if !recorded {
			return nodes, bytes, false
		}
		if descend {
			path, clone_err := strings.clone(info.fullpath, w.allocator)
			if clone_err != nil {
				w.err = .Out_Of_Memory
				return nodes, bytes, false
			}
			append(&w.found, Dir{index = index, path = path})
		}
		nodes += 1
		bytes += charged
	}
	return nodes, bytes, true
}

// Without filesystem-specific knowledge the allocation unit is a guess, and four
// kilobytes is the common one. It makes small files cost something rather than
// nothing, which matters more than being exactly right.
@(private)
BLOCK_ESTIMATE :: 4096

@(private)
round_up :: proc(v, unit: u64) -> u64 {
	if v == 0 {
		return 0
	}
	return (v + unit - 1) / unit * unit
}

// Scratch is what a worker reuses between directories: nothing, here.
@(private)
Scratch :: struct {}

@(private)
scratch_make :: proc(allocator: mem.Allocator) -> Scratch {
	return {}
}

@(private)
scratch_destroy :: proc(s: ^Scratch) {}
