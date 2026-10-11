package leita_app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "../../history"
import "../../human"
import "../../reclaim"
import "../../scan"
import "../../survey"
import "../../synth"
import "../command"
import "../files"
import "../query"

/*
What the window asks of an entry it was shown: locate, trash, rename. Each runs
on the desk thread, which owns the tree and its totals, so a trashed entry leaves
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
		tell(d, true, "Nothing was changed: this disk is made up, so its files are not on disk")
		return
	}
	done := make([dynamic]history.Action, context.temp_allocator)
	defer audit(d, done[:])
	#partial switch &c in c {
	case command.Locate:
		if path, ok := entry_path(d, c.entry, "locate"); ok {
			files.locate(path)
		}
	case command.Trash:
		path, ok := entry_path(d, c.entry, "move to the Trash")
		if !ok {
			return
		}
		bytes := held(d.scan, c.entry.node)
		if err := files.trash(path); err != .None {
			note(&done, .Trash, path, files.describe(err), bytes, true)
			tell(
				d,
				true,
				"Could not move %s to the Trash: %s",
				name_of(d, c.entry),
				files.describe(err),
			)
			return
		}
		note(&done, .Trash, path, "", bytes, false)
		survey.forget(&d.scan.roll, &d.scan.tree, c.entry.node)
		tell(d, false, "Moved %s to the Trash", name_of(d, c.entry))
	case command.Clean:
		clean(d, &c, &done)
	case command.Empty_Trash:
		empty_trash(d, c.entry, &done)
	case command.Rename:
		path, ok := entry_path(d, c.entry, "rename")
		if !ok {
			return
		}
		name := command.text_of(&c.name)
		if why := files.name_problem(name); why != "" {
			tell(d, true, "Could not rename %s: %s", name_of(d, c.entry), why)
			return
		}
		bytes := held(d.scan, c.entry.node)
		if _, err := files.rename(path, name, context.temp_allocator); err != .None {
			why := files.describe(err)
			note(&done, .Rename, path, fmt.tprintf("to %s: %s", name, why), bytes, true)
			tell(d, true, "Could not rename %s: %s", name_of(d, c.entry), why)
			return
		}
		note(&done, .Rename, path, name, bytes, false)
		s := d.scan
		was := name_of(d, c.entry)
		scan.node(&s.tree, c.entry.node).name = scan.name_copy(&s.tree, name)
		tell(d, false, "Renamed %s to %s", was, name)
	}
}

// entry_path is the path of the entry e names, or a notice saying why there is
// none to `doing`.
entry_path :: proc(d: ^Desk, e: command.Entry, doing: string) -> (string, bool) {
	s := d.scan
	if s == nil || e.generation != d.generation || !s.grown || e.node >= s.roll.seen {
		tell(d, true, "Could not %s it: the scan it came from is gone", doing)
		return "", false
	}
	if survey.removed(&s.roll, &s.tree, e.node) {
		tell(d, true, "Could not %s it: it was moved to the Trash", doing)
		return "", false
	}
	if top, ok := root(s); ok && top == e.node && doing != "locate" {
		tell(d, true, "Could not %s the top of the scan from here", doing)
		return "", false
	}
	return scan.path(&s.tree, e.node, context.temp_allocator), true
}

// tell replaces the notice the window is shown. The text is cloned from a
// temporary rather than made by fmt.aprintf, whose string is shorter than the
// builder block it lives in, so freeing it would name the wrong size.
tell :: proc(d: ^Desk, failed: bool, format: string, args: ..any) {
	delete(d.notice.text)
	d.notice = {
		id     = d.notice.id + 1,
		failed = failed,
		text   = strings.clone(fmt.tprintf(format, ..args)),
	}
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
is left out. What it offers is kept, and Clean deletes nothing else.
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
			return .Directory in scan.node_flags(scan.node(&(^Scan)(data).tree, node))
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
	home := synth.HOME if synthetic else os.get_env("HOME", context.temp_allocator)
	found := reclaim.find(
		src,
		dir,
		scan.path(&s.tree, dir, context.temp_allocator),
		home,
		context.temp_allocator,
	)
	clear(&d.reclaimable)
	now := time.time_to_unix(time.now())
	groups := make([dynamic]query.Reclaim_Group, context.temp_allocator)
	for category in reclaim.Category {
		g := query.Reclaim_Group {
			name   = reclaim.CATEGORY_NAMES[category],
			reason = reclaim.CATEGORY_REASONS[category],
			trash  = category == .Trash,
		}
		items := make([dynamic]query.Candidate, context.temp_allocator)
		for c in found {
			if c.category != category {
				continue
			}
			modified, is_dir := synth.modified(c.path), true
			if !synthetic {
				modified, is_dir = newest_modification(c.path)
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

// newest_modification is when the directory at path, or anything it directly
// holds, was last modified, and whether path is a directory and not a link to one.
newest_modification :: proc(path: string) -> (modified: i64, is_dir: bool) {
	info, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	if err != nil || info.type != .Directory {
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

// clean deletes for good each entry of c that Reclaim offered, and takes it out of
// the totals; anything else it was sent is refused.
clean :: proc(d: ^Desk, c: ^command.Clean, done: ^[dynamic]history.Action) {
	s := d.scan
	if s == nil || c.generation != d.generation || !s.grown {
		tell(d, true, "Could not clean up: the scan it came from is gone")
		return
	}
	deleted, failed, refused: int
	freed: u64
	for node in c.nodes[:min(c.count, len(c.nodes))] {
		category, offered := d.reclaimable[node]
		if !offered || category == .Trash || survey.removed(&s.roll, &s.tree, node) {
			refused += 1
			continue
		}
		bytes := survey.total(&s.roll, node)
		path := scan.path(&s.tree, node, context.temp_allocator)
		left, err := files.delete_tree(path)
		if err != .None {
			note(done, .Delete, path, files.describe(err), bytes, true)
			failed += 1
			continue
		}
		if left > 0 {
			note(done, .Delete, path, fmt.tprintf("%d could not be deleted", left), bytes, true)
			failed += 1
		} else {
			note(done, .Delete, path, "", bytes, false)
		}
		survey.forget(&s.roll, &s.tree, node)
		delete_key(&d.reclaimable, node)
		deleted += 1
		freed += bytes
	}
	tell(
		d,
		failed + refused > 0,
		"Deleted %d %s and freed %s%s",
		deleted,
		"folder" if deleted == 1 else "folders",
		human.bytes(freed),
		fmt.tprintf("; %d could not be deleted", failed + refused) if failed + refused > 0 else "",
	)
}

// empty_trash deletes what the Trash entry e holds, if Reclaim offered it as the
// Trash: its files and their records, never the Trash itself.
empty_trash :: proc(d: ^Desk, e: command.Entry, done: ^[dynamic]history.Action) {
	s := d.scan
	if s == nil || e.generation != d.generation || !s.grown {
		tell(d, true, "Could not empty the Trash: the scan it came from is gone")
		return
	}
	if category, offered := d.reclaimable[e.node]; !offered || category != .Trash {
		tell(d, true, "Could not empty the Trash: it is not the Trash Reclaim found")
		return
	}
	bytes := survey.total(&s.roll, e.node)
	failed := 0
	it := survey.children(&s.roll, e.node)
	children := make([dynamic]u32, context.temp_allocator)
	for c in survey.next_child(&it) {
		append(&children, c)
	}
	for c in children {
		path := scan.path(&s.tree, c, context.temp_allocator)
		size := held(s, c)
		if .Directory not_in scan.node_flags(scan.node(&s.tree, c)) {
			// The freedesktop.org Trash keeps everything in its files and info
			// directories; the Finder's holds what was trashed itself.
			when ODIN_OS == .Darwin {
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
		left, err := files.delete_tree(path)
		failed += left + (1 if err != .None else 0)
		switch {
		case err != .None:
			note(done, .Empty_Trash, path, files.describe(err), size, true)
		case left > 0:
			note(
				done,
				.Empty_Trash,
				path,
				fmt.tprintf("%d could not be deleted", left),
				size,
				true,
			)
		case:
			note(done, .Empty_Trash, path, "", size, false)
		}
		if err == .None {
			survey.forget(&s.roll, &s.tree, c)
		}
	}
	freed := bytes - survey.total(&s.roll, e.node)
	if failed > 0 {
		tell(
			d,
			true,
			"Emptied the Trash and freed %s; %d could not be deleted",
			human.bytes(freed),
			failed,
		)
	} else {
		tell(d, false, "Emptied the Trash and freed %s", human.bytes(freed))
	}
}
