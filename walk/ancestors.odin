#+build linux, windows
package walk

import "core:mem"

// Whether `id` is one of the directories on `path`.
@(private)
on_path :: proc(path: ^Ancestor, id: File_Id) -> bool {
	for a := path; a != nil; a = a.up {
		if a.id == id {
			return true
		}
	}
	return false
}

// A chain that is `up` with `id` below it, made in `allocator`: the worker's
// arena (ancestry), which lasts as long as the walk.
@(private)
push :: proc(w: ^Worker, id: File_Id, up: ^Ancestor, allocator := context.allocator) -> (a: ^Ancestor, ok: bool) {
	err: mem.Allocator_Error
	a, err = new(Ancestor, allocator)
	if err != nil {
		w.err = .Out_Of_Memory
		return nil, false
	}
	a^ = {id, up}
	return a, true
}

// The arena a worker keeps its chains of directories in (Scratch).
@(private)
ancestry :: proc(w: ^Worker) -> mem.Allocator {
	return mem.dynamic_arena_allocator(&w.scratch.ancestry)
}
