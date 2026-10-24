package leita_app

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "jm:stream"

import "../../history"
import "../../home"
import "../../reclaim"
import "../../scan"
import "../../survey"
import "../../synth"
import "../command"
import "../files"
import "../msg"
import "../query"

/*
What the window asks of an entry it was shown: locate, open, trash, rename. Each
runs on the desk thread, which owns the tree and its totals, so a trashed entry leaves
the totals and a renamed one takes its new name in the same step as the disk
changes, and the next answers show it.

The window names an entry by its node in one scan's tree, so a request carrying
another generation's is refused rather than applied to whatever has that number now.

Each path a request changed on disk, or failed to, goes in the audit trail, once
the request is done. A request refused before it touched the disk does not.
*/

// act carries out c, one of the requests about an entry.
act :: proc(d: ^Desk, c: ^command.Command) {
	// A made-up disk's paths may name real files, /Applications/Xcode.app among
	// them, which no request about the made-up ones may touch.
	if d.scan != nil && d.scan.engine == .Synthetic {
		_, opening := c.(command.Open)
		tell(d, true, .Made_Up_Open if opening else .Made_Up)
		return
	}
	done := make([dynamic]history.Action, context.temp_allocator)
	defer audit(d, done[:])
	#partial switch &c in c {
	case command.Locate:
		if path, ok := entry_path(d, c.entry, .Locate); ok {
			files.locate(path)
		}
	case command.Open:
		if path, ok := entry_path(d, c.entry, .Open); ok {
			open_entry(d, path, name_of(d, c.entry))
		}
	case command.Trash:
		path, ok := entry_path(d, c.entry, .Trash)
		if !ok {
			return
		}
		bytes := held(d.scan, c.entry.node)
		if err := files.trash(path); err != .None {
			note(&done, .Trash, path, files.describe(err), bytes, true)
			tell(d, true, .Trash_Failed, name_of(d, c.entry), say(d, FILE_ERRORS[err]))
			return
		}
		note(&done, .Trash, path, "", bytes, false)
		survey.forget(&d.scan.roll, &d.scan.tree, c.entry.node)
		tell(d, false, .Trashed, name_of(d, c.entry))
	case command.Clean:
		clean(d, &c, &done)
	case command.Empty_Trash:
		empty_trash(d, c.entry, &done)
	case command.Rename:
		path, ok := entry_path(d, c.entry, .Rename)
		if !ok {
			return
		}
		name := command.text_of(&c.name)
		if fault := files.name_fault(name); fault != .None {
			tell(d, true, .Rename_Failed, name_of(d, c.entry), say(d, NAME_FAULTS[fault]))
			return
		}
		bytes := held(d.scan, c.entry.node)
		if _, err := files.rename(path, name, context.temp_allocator); err != .None {
			why := files.describe(err)
			note(&done, .Rename, path, fmt.tprintf("to %s: %s", name, why), bytes, true)
			tell(d, true, .Rename_Failed, name_of(d, c.entry), say(d, FILE_ERRORS[err]))
			return
		}
		note(&done, .Rename, path, name, bytes, false)
		s := d.scan
		was := name_of(d, c.entry)
		scan.node(&s.tree, c.entry.node).name = scan.name_copy(&s.tree, name)
		tell(d, false, .Renamed, was, name)
	}
}

// Open_Failure is an entry the system would not open, by its name, back from the
// worker that asked.
Open_Failure :: struct {
	name: command.Text,
}

open_failure_in :: proc(n: Open_Failure) -> Desk_In {
	return n
}

// Opening is an entry being opened on a worker.
@(private)
Opening :: struct {
	path:   command.Text,
	name:   command.Text,
	answer: ^stream.Port(Open_Failure),
	done:   ^sync.Wait_Group,
}

/*
open_entry opens path as the system would, on a thread of its own: the
application it starts may take its time, which the desk must not wait for, and
an opener that waits for the application to quit must not hold a worker a
search needs. Only a failure is said, in a notice, as the window has nothing to
show for one that went well.
*/
open_entry :: proc(d: ^Desk, path, name: string) {
	o := new(Opening)
	o^ = {
		path   = command.text_make(path),
		name   = command.text_make(name),
		answer = d.open_failures,
		done   = d.opening,
	}
	sync.wait_group_add(d.opening, 1)
	thread.create_and_start_with_data(o, proc(data: rawptr) {
			o := (^Opening)(data)
			if !files.open_default(command.text_of(&o.path)) {
				stream.port_send(o.answer^, Open_Failure{name = o.name})
			}
			done := o.done
			free(o)
			sync.wait_group_done(done)
		}, context, self_cleanup = true)
}

// Doing is a request about an entry, for entry_path to say it could not do.
Doing :: enum u8 {
	Locate,
	Open,
	Trash,
	Rename,
}

// entry_path is the path of the entry e names, or a notice saying why there is
// none to do it to.
entry_path :: proc(d: ^Desk, e: command.Entry, doing: Doing) -> (string, bool) {
	@(static, rodata)
	GONE := [Doing]msg.Msg {
		.Locate = .Gone_Locate,
		.Open   = .Gone_Open,
		.Trash  = .Gone_Trash,
		.Rename = .Gone_Rename,
	}
	@(static, rodata)
	TRASHED := [Doing]msg.Msg {
		.Locate = .Trashed_Locate,
		.Open   = .Trashed_Open,
		.Trash  = .Trashed_Trash,
		.Rename = .Trashed_Rename,
	}
	@(static, rodata)
	TOP := [Doing]msg.Msg {
		.Locate = .Top_Trash, // never said: the top can be located
		.Open   = .Top_Trash, // nor this: the top can be opened
		.Trash  = .Top_Trash,
		.Rename = .Top_Rename,
	}
	s := d.scan
	if s == nil || e.generation != d.generation || !s.grown || e.node >= s.roll.seen {
		tell(d, true, GONE[doing])
		return "", false
	}
	if survey.removed(&s.roll, &s.tree, e.node) {
		tell(d, true, TRASHED[doing])
		return "", false
	}
	if top, ok := root(s); ok && top == e.node && doing != .Locate && doing != .Open {
		tell(d, true, TOP[doing])
		return "", false
	}
	return scan.path(&s.tree, e.node, context.temp_allocator), true
}


// note adds an action to done, taken now.
note :: proc(
	done: ^[dynamic]history.Action,
	kind: history.Action_Kind,
	path, detail: string,
	bytes: u64,
	failed: bool,
) {
	append(done, history.Action{time.time_to_unix(time.now()), kind, path, detail, bytes, failed})
}

// audit keeps done in the audit trail, if there is a store to keep it in.
audit :: proc(d: ^Desk, done: []history.Action) {
	if d.history == nil {
		return
	}
	if err := history.record(d.history, done); err != nil {
		fmt.eprintln("leita: could not keep the audit trail:", err)
	}
}

// held is what node holds: a directory's total, or a file's size on disk.
held :: proc(s: ^Scan, node: u32) -> u64 {
	n := scan.node(&s.tree, node)
	return survey.total(&s.roll, node) if .Directory in scan.node_flags(n) else n.disk
}

// name_of is the name the tree has for e, which entry_path has already checked.
@(private = "file")
name_of :: proc(d: ^Desk, e: command.Entry) -> string {
	return scan.name_of(&d.scan.tree, e.node)
}

// --- Reclaim -------------------------------------------------------------------

/*
reclaim_answer is what can be deleted under the directory q names, once the scan
is over: reclaim.find's candidates, grouped by kind, each with when it or what it
directly holds was last modified. A candidate that is no longer a directory on disk
is left out, as is a link to one (newest_modification), and one Reclaim run as root
may not delete (refused_as_root). What it offers is kept, and Clean deletes nothing
else.
*/
reclaim_answer :: proc(d: ^Desk, q: query.Reclaim) -> (r: query.Reclaim_Result) {
	r.generation = d.generation
	s := d.scan
	if s == nil || q.generation != d.generation || !s.grown || s.state == .Scanning {
		return
	}
	top, ok := root(s)
	if !ok {
		return
	}
	dir := top if q.dir == query.ROOT else q.dir
	if dir >= s.roll.seen {
		return
	}
	r.ready = true
	src := reclaim.Source {
		data = s,
		name = proc(
			data: rawptr,
			node: u32,
		) -> string {return scan.name_of(&(^Scan)(data).tree, node)},
		directory = proc(data: rawptr, node: u32) -> bool {
			// A mount point is another volume's, never Reclaim's (reclaim.Source).
			flags := scan.node_flags(scan.node(&(^Scan)(data).tree, node))
			return flags & {.Directory, .Mount} == {.Directory}
		},
		bytes = proc(data: rawptr, node: u32) -> u64 {
			s := (^Scan)(data)
			n := scan.node(&s.tree, node)
			return survey.total(&s.roll, node) if .Directory in scan.node_flags(n) else n.disk
		},
		children = proc(data: rawptr, node: u32, into: ^[dynamic]u32) {
			it := survey.children(&(^Scan)(data).roll, node)
			for c in survey.next_child(&it) {
				append(into, c)
			}
		},
	}
	synthetic := s.engine == .Synthetic
	// A made-up disk has a made-up owner, whose home is where its caches are, on
	// a made-up Mac.
	who := home.User{synth.HOME, ""} if synthetic else home.user(context.temp_allocator)
	top_path := top_path_of(&s.tree, dir, synthetic)
	found := reclaim.find(
		src,
		dir,
		top_path,
		who,
		context.temp_allocator,
		.Darwin if synthetic else reclaim.HOST,
	)
	if !synthetic {
		bins := files.recycle_bins(who.uid, context.temp_allocator)
		if len(bins) > 0 {
			offers := make([]reclaim.Recycle_Bin, len(bins), context.temp_allocator)
			for b, i in bins {
				offers[i] = {b.volume, b.path, b.bytes}
			}
			found = reclaim.overlay_recycle_bins(
				found,
				offers,
				who.uid,
				reclaim.recycle_bin_node,
				context.temp_allocator,
			)
		}
	}
	clear(&d.reclaimable)
	for _, path in d.recycle_paths {
		delete(path)
	}
	clear(&d.recycle_paths)
	now := time.time_to_unix(time.now())
	groups := make([dynamic]query.Reclaim_Group, context.temp_allocator)
	for category in reclaim.Category {
		g := query.Reclaim_Group {
			name   = say(d, CATEGORY_NAMES[category]),
			reason = say(d, CATEGORY_WHY[category]),
			trash  = category == .Trash,
		}
		items := make([dynamic]query.Candidate, context.temp_allocator)
		for c in found {
			if c.category != category {
				continue
			}
			modified, is_dir := synth.modified(c.path), true
			recycle := reclaim.is_recycle_bin(c.path, who.uid)
			if !synthetic {
				if refused_as_root(c.path, who) {
					continue
				}
				modified, is_dir = newest_modification(c.path)
			}
			if recycle {
				is_dir = true
				d.recycle_paths[c.node] = strings.clone(c.path)
			}
			if !is_dir {
				continue
			}
			recent := modified > 0 && now - modified < query.RECLAIM_RECENT_DAYS * 24 * 60 * 60
			append(&items, query.Candidate{c.node, c.path, c.bytes, modified, recent})
			d.reclaimable[c.node] = category
			g.bytes += c.bytes
		}
		if len(items) > 0 {
			g.items = items[:]
			append(&groups, g)
			r.bytes += g.bytes
		}
	}
	r.groups = groups[:]
	return
}

// top_path_of is the path of directory dir that Reclaim searches from, in allocator:
// a made-up disk's is the Mac's, written with / alone (synth.mac_path).
@(private = "file")
top_path_of :: proc(
	tree: ^scan.Tree,
	dir: u32,
	synthetic: bool,
	allocator := context.temp_allocator,
) -> string {
	path := scan.path(tree, dir, allocator)
	if !synthetic {
		return path
	}
	defer delete(path, allocator)

	return synth.mac_path(path, allocator)
}

/*
refused_as_root is whether Reclaim, run as root, must leave the directory at path
alone: it is not under the home of who, the person sudo ran it for, or not theirs
(reclaim.root_may_delete). One whose owner cannot be read is left alone too. Run
as anyone else, it is left to the system's permission checks.
*/
refused_as_root :: proc(
	path: string,
	who: home.User,
	allocator := context.temp_allocator,
) -> bool {
	when ODIN_OS == .Windows {
		return false
	} else {
		return reclaim.refused_as_root(path, who, home.effective_uid(), allocator)
	}
}

// newest_modification is when the directory at path, or anything it directly
// holds, was last modified, and whether path is a directory and not a link to
// one. files.is_link is asked as well as lstat: on Windows lstat drops the
// reparse tag and calls a junction or a directory symlink a directory
// (core/os/stat_windows.odin), and Reclaim would offer it. The link is not
// listed, so what it names is not read.
newest_modification :: proc(path: string) -> (modified: i64, is_dir: bool) {
	info, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	if err != nil || info.type != .Directory || files.is_link(path) {
		return 0, false
	}
	modified = time.time_to_unix(info.modification_time)
	if entries, rerr := os.read_all_directory_by_path(path, context.temp_allocator); rerr == nil {
		for e in entries {
			modified = max(modified, time.time_to_unix(e.modification_time))
		}
	}
	return modified, true
}

// clean deletes for good each entry of c that Reclaim offered, and takes what went
// out of the totals; anything else it was sent is refused. An entry partly deleted
// stays in the tree. The audit records the size of what was unlinked. The
// notice does not call that size space freed.
clean :: proc(d: ^Desk, c: ^command.Clean, done: ^[dynamic]history.Action) {
	s := d.scan
	if s == nil || c.generation != d.generation || !s.grown {
		tell(d, true, .Clean_Gone)
		return
	}
	deleted, failed, refused: int
	who := home.user(context.temp_allocator)
	for node in c.nodes[:min(c.count, len(c.nodes))] {
		category, offered := d.reclaimable[node]
		if !offered || category == .Trash || survey.removed(&s.roll, &s.tree, node) {
			refused += 1
			continue
		}
		path := scan.path(&s.tree, node, context.temp_allocator)
		// Asked again here: what was offered may have changed hands since.
		if refused_as_root(path, who) {
			note(done, .Delete, path, files.describe(.Not_Yours), 0, true)
			failed += 1
			continue
		}
		left, gave, err := files.delete_tree(path)
		if err != .None {
			note(done, .Delete, path, why_left(err, left), gave, true)
			failed += 1
			continue
		}
		note(done, .Delete, path, "", gave, false)
		survey.forget(&s.roll, &s.tree, node)
		delete_key(&d.reclaimable, node)
		deleted += 1
	}
	// gave is what the delete measured as unlinked. It is not an exact reclaim,
	// so the notice does not call it space freed.
	if failed + refused > 0 {
		tell(d, true, .Cleaned_Partly, deleted, failed + refused)
	} else {
		tell(d, false, .Cleaned, deleted)
	}
}

// why_left is what the audit trail says of a tree delete_tree did not delete.
@(private = "file")
why_left :: proc(err: files.Error, left: int) -> string {
	if err == .Partly {
		return fmt.tprintf("%d could not be deleted", left)
	}
	return files.describe(err)
}

// empty_trash deletes what the Trash entry e holds, if Reclaim offered it as the
// Trash: its files and their records, never the Trash itself.
empty_trash :: proc(d: ^Desk, e: command.Entry, done: ^[dynamic]history.Action) {
	s := d.scan
	if s == nil || e.generation != d.generation || !s.grown {
		tell(d, true, .Empty_Gone)
		return
	}
	if category, offered := d.reclaimable[e.node]; !offered || category != .Trash {
		tell(d, true, .Empty_Not_Trash)
		return
	}
	if _, recycle := d.recycle_paths[e.node]; recycle {
		empty_recycle_bins(d, done)
		return
	}
	failed := 0
	it := survey.children(&s.roll, e.node)
	children := make([dynamic]u32, context.temp_allocator)
	for c in survey.next_child(&it) {
		append(&children, c)
	}
	who := home.user(context.temp_allocator)
	for c in children {
		path := scan.path(&s.tree, c, context.temp_allocator)
		if refused_as_root(path, who) {
			note(done, .Empty_Trash, path, files.describe(.Not_Yours), 0, true)
			failed += 1
			continue
		}
		if .Directory not_in scan.node_flags(scan.node(&s.tree, c)) {
			// The freedesktop.org Trash keeps everything in its files and info
			// directories; the Finder's holds what was trashed itself.
			when ODIN_OS == .Darwin {
				// held is the charged share. The audit records what the path
				// held. The notice does not call that figure space freed.
				size := held(s, c)
				if err := os.remove(path); err == nil {
					note(done, .Empty_Trash, path, "", size, false)
					survey.forget(&s.roll, &s.tree, c)
				} else {
					note(done, .Empty_Trash, path, fmt.tprint(err), size, true)
					failed += 1
				}
			}
			continue
		}
		left, gave, err := files.delete_tree(path)
		if err != .None {
			// What was left is counted entry by entry; a tree refused whole is one.
			failed += left if err == .Partly else 1
			note(done, .Empty_Trash, path, why_left(err, left), gave, true)
			continue
		}
		note(done, .Empty_Trash, path, "", gave, false)
		survey.forget(&s.roll, &s.tree, c)
	}
	if failed > 0 {
		tell(d, true, .Emptied_Partly, failed)
	} else {
		tell(d, false, .Emptied)
	}
}

// empty_recycle_bins empties each Recycle Bin Reclaim offered, through the
// shell, and records each volume in the audit trail. The tree's children of a
// Bin that was in the scan are forgotten once the shell has taken them.
@(private)
empty_recycle_bins :: proc(d: ^Desk, done: ^[dynamic]history.Action) {
	s := d.scan
	failed := 0
	for node, path in d.recycle_paths {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		size, _, _ := files.recycle_bin_info(path)
		if err := files.empty_recycle_bin(path); err != .None {
			note(done, .Empty_Trash, path, files.describe(err), size, true)
			failed += 1
			continue
		}
		note(done, .Empty_Trash, path, "", size, false)
		if node < s.roll.seen {
			it := survey.children(&s.roll, node)
			children := make([dynamic]u32, context.temp_allocator)
			for c in survey.next_child(&it) {
				append(&children, c)
			}
			for c in children {
				survey.forget(&s.roll, &s.tree, c)
			}
		}
		delete_key(&d.reclaimable, node)
	}
	if failed > 0 {
		tell(d, true, .Emptied_Partly, failed)
	} else {
		tell(d, false, .Emptied)
	}
}
