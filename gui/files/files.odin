/*
Package files is what leita's window does to what it found, through the platform:
show an entry in the system's file manager, move it to the Trash, rename it. Each
acts on a path and reports an Error; deciding whether to ask is the caller's.

Targets are Linux, macOS and Windows. On Linux the Trash is the freedesktop.org one
in the user's home; the file manager is asked over D-Bus through the freedesktop.org
FileManager1 interface, with xdg-open on the folder as the fallback. On macOS both go
through the Finder: NSFileManager's Trash, and open -R to show an entry. On Windows
this package calls SHQueryRecycleBinW and SHEmptyRecycleBinW.
*/
package leita_files

import "base:runtime"

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"
import "core:unicode"

import "jm:timefmt"

// Recycle_Bin is one volume's Recycle Bin as this package reports it.
Recycle_Bin :: struct {
	volume: string, // `C:\` root this package passes to the shell
	path:   string, // `C:\$Recycle.Bin\<SID>`
	bytes:  u64,
	items:  u64,
}

Error :: enum u8 {
	None,
	Exists, // something already has that name
	Missing, // the entry is no longer there
	Denied,
	Cross_Device, // the Trash is on another filesystem
	Not_Recycled, // the Recycle Bin would not keep it, and nothing was deleted
	Bad_Name,
	Not_Directory, // asked to delete a tree at something that is not a directory
	Partly, // some of a tree could not be deleted, so the tree is still there
	Mount_Point, // asked to delete a tree another filesystem is mounted at
	// run as root, asked to delete what is not the invoking user's, or not under
	// their home (reclaim.root_may_delete)
	Not_Yours,
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
	case .Not_Recycled:
		return "the Recycle Bin refused it; nothing was deleted"
	case .Bad_Name:
		return "that is not a name a file can have"
	case .Not_Directory:
		return "it is not a directory"
	case .Partly:
		return "some of it could not be deleted"
	case .Mount_Point:
		return "another filesystem is mounted there"
	case .Not_Yours:
		return "as root, only your own folders in your home are deleted"
	case .Unsupported:
		return "this system cannot do that"
	case .Other:
	}
	return "the system refused"
}

/*
trash_outcome is what a shell delete to the Recycle Bin came to, from the code it
returned, whether it says some of it was aborted, and whether the path is gone.
Success is the path being gone, whatever the shell returned: a path still there
was not recycled. A path gone after a failure is not claimed saved or lost, it is
Other.
*/
@(private)
trash_outcome :: proc(code: i32, aborted, gone: bool) -> Error {
	switch {
	case !gone:
		return .Not_Recycled
	case code != 0 || aborted:
		return .Other
	}
	return .None
}

// Name_Fault is why a name cannot be a file's new name, which the window words.
Name_Fault :: enum u8 {
	None,
	Empty,
	Dot, // . or .., which name a folder itself
	Slash,
	Nul,
	Reserved, // one of \ : * ? " < > | on Windows
	Device, // a name Windows keeps for a device (CON, NUL, COM1), with or without an extension
	Trailing, // a space or dot at the end, which Windows drops from the name it stores
}

// name_fault is why name cannot be a file's new name, or None if it can.
name_fault :: proc(name: string) -> Name_Fault {
	switch {
	case strings.trim_space(name) == "":
		return .Empty
	case name == "." || name == "..":
		return .Dot
	case strings.contains_rune(name, '/'):
		return .Slash
	case strings.contains_rune(name, 0):
		return .Nul
	}
	when ODIN_OS == .Windows {
		return windows_name_fault(name)
	}
	return .None
}

// windows_name_fault is why Windows would not keep name as it is, or None. It
// is not Windows-only code so that every host tests it.
@(private)
windows_name_fault :: proc(name: string) -> Name_Fault {
	switch {
	case strings.contains_any(name, `\:*?"<>|`):
		return .Reserved
	case is_device_name(name):
		return .Device
	case strings.has_suffix(name, " ") || strings.has_suffix(name, "."):
		return .Trailing
	}
	return .None
}

// is_device_name says whether name is CON, PRN, AUX, NUL, COM1 to COM9 or LPT1 to
// LPT9, which Microsoft's "Naming Files, Paths, and Namespaces" lists as reserved
// and says an extension (NUL.tar.gz) does not make a different name. Case is
// folded, and spaces before the first dot are ignored, as a cautious reading.
@(private)
is_device_name :: proc(name: string) -> bool {
	stem, _, _ := strings.partition(name, ".")
	stem = strings.trim_right(stem, " ")
	for device in ([?]string{"CON", "PRN", "AUX", "NUL"}) {
		if strings.equal_fold(stem, device) {
			return true
		}
	}
	if len(stem) == 4 && stem[3] >= '1' && stem[3] <= '9' {
		return strings.equal_fold(stem[:3], "COM") || strings.equal_fold(stem[:3], "LPT")
	}
	return false
}

// Called with a directory's name as delete_tree is about to enter it, so a test
// can change the tree between the look and the open. Nil outside tests.
@(private)
before_enter: proc(name: string)

/*
delete_tree deletes the directory at path and everything in it, for good. It says
how many entries it could not delete, not counting a folder kept only because it
holds one, and how many bytes what it did delete gave back. Anything left is
Partly: the tree is still there, and only freed is gone. It is for what Reclaim
proved can be made again, and it is careful in the ways deletion has to be:

  - path must be a directory itself, not a link to one. On Linux and Darwin an
    ancestor that is a link is refused as well, and the delete does not walk
    through it;
  - inside, a link is deleted as a link, never followed;
  - it never deletes through a mount: a tree that is itself mounted there is
    refused with Mount_Point, and another disk or a bind of somewhere else
    mounted inside it is counted as left and not entered;
  - a directory is made writable by its owner before it is emptied, since some
    caches (Go's module cache) are made read-only, and given its mode back if it
    could not be deleted after all;
  - an entry that cannot be deleted is counted and passed over, and the rest
    still go.

How it walks the tree is the platform's: delete_unix.odin and delete_windows.odin.
*/
delete_tree :: proc(path: string) -> (failed: int, freed: u64, err: Error) {
	info, serr := os.stat_do_not_follow_links(path, context.temp_allocator)
	switch {
	case serr != nil:
		return 0, 0, .Missing
	case info.type != .Directory, is_link(path):
		return 0, 0, .Not_Directory
	}
	failed, freed, err = remove_tree(path)
	if err == .None && failed > 0 {
		err = .Partly
	}
	return
}

// rename gives the entry at path the new name in the same folder, refusing with
// Exists rather than replacing whatever already has it. On Linux the folder is
// opened without following a link, and the rename stays inside that descriptor.
rename :: proc(path, name: string, allocator := context.allocator) -> (to: string, err: Error) {
	if name_fault(name) != .None {
		return "", .Bad_Name
	}
	parent := filepath.dir(path)
	base := filepath.base(path)
	if base == "" || base == "." || base == ".." {
		return "", .Bad_Name
	}
	to = child_path(parent, name, allocator)
	err = rename_noreplace(path, to)
	if err != .None {
		delete(to, allocator)
		return "", err
	}
	return to, .None
}

// child_path is name inside parent. An empty parent is the working directory, so
// a relative path is not joined onto the root: path[:0] + "/" + name is "/name".
@(private)
child_path :: proc(parent, name: string, allocator := context.allocator) -> string {
	switch {
	case parent == "" || parent == ".":
		return strings.clone(name, allocator)
	case strings.has_suffix(parent, "/") || strings.has_suffix(parent, `\`):
		return strings.concatenate({parent, name}, allocator)
	}
	return strings.concatenate({parent, SEPARATOR, name}, allocator)
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
		if open_err == os.General_Error.Exist {
			continue
		}
		return "", nil, open_error(open_err)
	}
	return "", nil, .Exists
}

/*
create_at opens the file at path to write, making it or emptying what was there:
for a path the person chose in a save dialog, which asks them before it names a
file that exists (ui.pick_save says which backend asks how).
*/
create_at :: proc(path: string) -> (file: ^os.File, err: Error) {
	f, open_err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil {
		return nil, open_error(open_err)
	}
	return f, .None
}

// open_error is the Error an open of a file to write failed with.
@(private)
open_error :: proc(err: os.Error) -> Error {
	switch {
	case err == os.General_Error.Exist:
		return .Exists
	case err == os.General_Error.Not_Exist:
		return .Missing
	case err == io.Error.Permission_Denied:
		return .Denied
	}
	return .Other
}

/*
report_stem is what a report of target made at now is called, less its
extension: leita-report-<target's last name>-<local date and minute>. The name is
kept to letters, digits, dots, dashes and underscores, anything else a dash: none
of those is reserved in a name on Linux, macOS or Windows, and the prefix keeps
it from being one of the names Windows reserves (CON, NUL). A target with no last
name, a volume's top, is "root". The window suggests it in the save dialog, and
the host names a report it saves without one so.
*/
report_stem :: proc(target: string, now: time.Time) -> string {
	base := filepath.base(strings.trim_right(target, `/\`))
	sb := strings.builder_make(context.temp_allocator)
	dash := false
	for r in base {
		if unicode.is_letter(r) || unicode.is_digit(r) || r == '.' || r == '_' || r == '-' {
			strings.write_rune(&sb, r)
			dash = false
		} else if !dash {
			strings.write_byte(&sb, '-')
			dash = true
		}
		if strings.builder_len(sb) >= 48 {
			break
		}
	}
	name := strings.trim(strings.to_string(sb), "-.")
	if name == "" {
		name = "root"
	}
	return strings.concatenate(
		{"leita-report-", name, "-", timefmt.local(now, "%Y-%m-%d-%H%M", context.temp_allocator)},
		context.temp_allocator,
	)
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
