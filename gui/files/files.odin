/*
Package files is what estoile's window does to what it found, through the platform:
show an entry in the system's file manager, move it to the Trash, rename it. Each
acts on a path and reports an Error; deciding whether to ask is the caller's.

Targets are Linux, macOS and Windows. On Linux the Trash is the freedesktop.org one
in the user's home; the file manager is asked over D-Bus through the freedesktop.org
FileManager1 interface, with xdg-open on the folder as the fallback. On macOS both go
through the Finder: NSFileManager's Trash, and open -R to show an entry.
*/
package estoile_files

import "base:runtime"

import "core:fmt"
import "core:io"
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
	Not_Directory, // asked to delete a tree at something that is not a directory
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
	case .Not_Directory:
		return "it is not a directory"
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

/*
delete_tree deletes the directory at path and everything in it, for good, and says
how many entries it could not delete. It is for what Reclaim proved can be made
again, and it is careful in the ways deletion has to be:

  - path must be a directory itself, not a link to one: a link is refused, so
    deleting never reaches through it to what it points at;
  - inside, a link is deleted as a link, never followed;
  - a directory is made writable by its owner before it is emptied, since some
    caches (Go's module cache) are made read-only;
  - an entry that cannot be deleted is counted and passed over, and the rest
    still go.
*/
delete_tree :: proc(path: string) -> (failed: int, err: Error) {
	info, serr := os.stat_do_not_follow_links(path, context.temp_allocator)
	switch {
	case serr != nil:
		return 0, .Missing
	case info.type != .Directory:
		return 0, .Not_Directory
	}
	return empty_tree(path) + (0 if os.remove(path) == nil else 1), .None
}

// empty_tree deletes everything in the directory at path, counting what it could
// not.
@(private)
empty_tree :: proc(path: string) -> (failed: int) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if info, err := os.stat_do_not_follow_links(path, context.temp_allocator); err == nil {
		_ = os.change_mode(path, info.mode + {.Read_User, .Write_User, .Execute_User})
	}
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		return 1
	}
	for e in entries {
		// The listing does not follow links, so a link is a link here.
		if e.type == .Directory {
			failed += empty_tree(e.fullpath)
		}
		if os.remove(e.fullpath) != nil {
			failed += 1
		}
	}
	return
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

// reports_folder is where the window saves what it exports: the user's
// Documents folder, or their home where that is missing; "" for neither.
reports_folder :: proc(allocator := context.allocator) -> string {
	if docs := documents(context.temp_allocator); docs != "" && os.is_dir(docs) {
		return strings.clone(docs, allocator)
	}
	home, err := os.user_home_dir(allocator)
	return home if err == nil else ""
}

/*
create_new makes a file in dir that was not there, named stem and ext, else
stem-2 and ext, stem-3 and on, and opens it to write. It never replaces a file,
even one made after it looked: the create claims the name or fails.
*/
create_new :: proc(
	dir, stem, ext: string,
	allocator := context.allocator,
) -> (
	path: string,
	file: ^os.File,
	err: Error,
) {
	for n in 1 ..= 999 {
		buf: [512]u8
		name :=
			fmt.bprintf(buf[:], "%s%s", stem, ext) if n == 1 else fmt.bprintf(buf[:], "%s-%d%s", stem, n, ext)
		path = strings.concatenate({dir, SEPARATOR, name}, allocator)
		f, open_err := os.open(path, {.Write, .Create, .Excl}, os.Permissions_Default_File)
		if open_err == nil {
			return path, f, .None
		}
		delete(path, allocator)
		switch {
		case open_err == os.General_Error.Exist:
			continue
		case open_err == os.General_Error.Not_Exist:
			return "", nil, .Missing
		case open_err == io.Error.Permission_Denied:
			return "", nil, .Denied
		}
		return "", nil, .Other
	}
	return "", nil, .Exists
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
