/*
Package files is what sonar's window does to what it found, through the platform:
show an entry in the system's file manager, move it to the Trash, rename it. Each
acts on a path and reports an Error; deciding whether to ask is the caller's.

Targets are Linux and Windows. On Linux the Trash is the freedesktop.org one in the
user's home; the file manager is asked over D-Bus through the freedesktop.org
FileManager1 interface, with xdg-open on the folder as the fallback.
*/
package sonar_files

import "base:runtime"

import "core:os"
import "core:strings"
import "core:thread"

Error :: enum u8 {
	None,
	Exists, // something already has that name
	Missing, // the entry is no longer there
	Denied,
	Cross_Device, // the Trash is on another filesystem
	Bad_Name,
	Unsupported,
	Other,
}

describe :: proc(e: Error) -> string {
	switch e {
	case .None:
		return ""
	case .Exists:
		return "something already has that name"
	case .Missing:
		return "it is no longer there"
	case .Denied:
		return "permission was denied"
	case .Cross_Device:
		return "it is on another filesystem than the Trash"
	case .Bad_Name:
		return "that is not a name a file can have"
	case .Unsupported:
		return "this system cannot do that"
	case .Other:
	}
	return "the system refused"
}

// name_problem is why name cannot be a file's new name, or "" if it can.
name_problem :: proc(name: string) -> string {
	switch {
	case strings.trim_space(name) == "":
		return "a name cannot be empty"
	case name == "." || name == "..":
		return "that name means a folder itself"
	case strings.contains_rune(name, '/'):
		return "a name cannot hold /"
	case strings.contains_rune(name, 0):
		return "a name cannot hold a NUL"
	}
	when ODIN_OS == .Windows {
		if strings.contains_any(name, `\:*?"<>|`) {
			return `a name cannot hold \ : * ? " < > or |`
		}
	}
	return ""
}

// rename gives the entry at path the new name in the same folder, refusing with
// Exists rather than replacing whatever already has it.
rename :: proc(path, name: string, allocator := context.allocator) -> (to: string, err: Error) {
	if name_problem(name) != "" {
		return "", .Bad_Name
	}
	dir := path[:max(strings.last_index_any(path, SEPARATORS), 0)]
	to = strings.concatenate({dir, SEPARATOR, name}, allocator)
	if err = rename_noreplace(path, to); err != .None {
		delete(to, allocator)
		return "", err
	}
	return to, .None
}

/*
locate shows path in the system's file manager, selected. It hands the asking to a
thread of its own and returns at once: a file manager that is slow to start must
not hold up the caller, and none of them says whether it found the entry.
*/
locate :: proc(path: string) {
	run_in_background(path, reveal)
}

// Job is work on a path that runs on a thread of its own, holding its own copy of
// the path.
@(private)
Job :: struct {
	path: string,
	work: proc(path: string),
}

/*
run_in_background runs work on a copy of path on a new thread. The thread is given the
caller's context, so the copy is freed by the allocator that made it: a thread
started without one frees through the system heap, which aborts on memory a
debug or tracking allocator handed out. A detached thread cleans up after itself;
otherwise the caller joins and destroys the thread returned.
*/
@(private)
run_in_background :: proc(
	path: string,
	work: proc(path: string),
	detach := true,
) -> ^thread.Thread {
	job := new(Job)
	job^ = {strings.clone(path), work}
	t := thread.create_and_start_with_poly_data(
		job,
		job_main,
		init_context = context,
		self_cleanup = detach,
	)
	if t == nil {
		delete(job.path)
		free(job)
	}
	return nil if detach else t
}

@(private)
job_main :: proc(job: ^Job) {
	// Given a context, the thread owns its temp allocator and frees it here.
	defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}
	defer free(job)
	defer delete(job.path)
	job.work(job.path)
}

// run starts command and waits for it, reporting whether it ran and exited 0.
@(private)
run :: proc(command: []string) -> bool {
	process, err := os.process_start({command = command})
	if err != nil {
		return false
	}
	state, _ := os.process_wait(process)
	return state.exit_code == 0
}
