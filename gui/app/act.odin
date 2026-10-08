package sonar_app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "../../human"
import "../../reclaim"
import "../../scan"
import "../../survey"
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
*/

// act carries out c, one of the requests about an entry.
act :: proc(d: ^Desk, c: ^command.Command) {
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
		if err := files.trash(path); err != .None {
			tell(
				d,
				true,
				"Could not move %s to the Trash: %s",
				name_of(d, c.entry),
				files.describe(err),
			)
			return
		}
		survey.forget(&d.scan.roll, &d.scan.tree, c.entry.node)
		tell(d, false, "Moved %s to the Trash", name_of(d, c.entry))
	case command.Clean:
		clean(d, &c)
	case command.Empty_Trash:
		empty_trash(d, c.entry)
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
		if _, err := files.rename(path, name, context.temp_allocator); err != .None {
			tell(d, true, "Could not rename %s: %s", name_of(d, c.entry), files.describe(err))
			return
		}
		s := d.scan
		was := name_of(d, c.entry)
		owned := strings.clone(name)
		append(&s.names, owned)
		scan.node(&s.tree, c.entry.node).name = owned
		tell(d, false, "Renamed %s to %s", was, name)
	}
}

// entry_path is the path of the entry e names, or a notice saying why there is
// none to `doing`.
entry_path :: proc(d: ^Desk, e: command.Entry, doing: string) -> (string, bool) {
	s := d.scan
	if s == nil || e.generation != d.generation || !s.grown || e.node >= u32(len(s.roll.totals)) {
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

// tell replaces the notice the window is shown.
tell :: proc(d: ^Desk, failed: bool, format: string, args: ..any) {
	delete(d.notice.text)
	d.notice = {
		id     = d.notice.id + 1,
		failed = failed,
		text   = fmt.aprintf(format, ..args),
	}
}

// name_of is the name the tree has for e, which entry_path has already checked.
@(private = "file")
name_of :: proc(d: ^Desk, e: command.Entry) -> string {
	return scan.node(&d.scan.tree, e.node).name
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
	if dir >= u32(len(s.roll.totals)) {
		return
	}
	r.ready = true
	src := reclaim.Source {
		data = s,
		name = proc(
			data: rawptr,
			node: u32,
		) -> string {return scan.node(&(^Scan)(data).tree, node).name},
		directory = proc(data: rawptr, node: u32) -> bool {
			return .Directory in scan.node_flags(scan.node(&(^Scan)(data).tree, node))
		},
		bytes = proc(data: rawptr, node: u32) -> u64 {
			s := (^Scan)(data)
			n := scan.node(&s.tree, node)
			return s.roll.totals[node] if .Directory in scan.node_flags(n) else n.disk
		},
		children = proc(data: rawptr, node: u32, into: ^[dynamic]u32) {
			it := survey.children(&(^Scan)(data).roll, node)
			for c in survey.next_child(&it) {
				append(into, c)
			}
		},
	}
	home := os.get_env("HOME", context.temp_allocator)
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
			modified, is_dir := newest_modification(c.path)
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
clean :: proc(d: ^Desk, c: ^command.Clean) {
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
		bytes := s.roll.totals[node]
		left, err := files.delete_tree(scan.path(&s.tree, node, context.temp_allocator))
		if err != .None {
			failed += 1
			continue
		}
		if left > 0 {
			failed += 1
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
empty_trash :: proc(d: ^Desk, e: command.Entry) {
	s := d.scan
	if s == nil || e.generation != d.generation || !s.grown {
		tell(d, true, "Could not empty the Trash: the scan it came from is gone")
		return
	}
	if category, offered := d.reclaimable[e.node]; !offered || category != .Trash {
		tell(d, true, "Could not empty the Trash: it is not the Trash Reclaim found")
		return
	}
	bytes := s.roll.totals[e.node]
	failed := 0
	it := survey.children(&s.roll, e.node)
	held := make([dynamic]u32, context.temp_allocator)
	for c in survey.next_child(&it) {
		append(&held, c)
	}
	for c in held {
		path := scan.path(&s.tree, c, context.temp_allocator)
		if .Directory not_in scan.node_flags(scan.node(&s.tree, c)) {
			// The freedesktop.org Trash keeps everything in its files and info
			// directories; the Finder's holds what was trashed itself.
			when ODIN_OS == .Darwin {
				if os.remove(path) == nil {
					survey.forget(&s.roll, &s.tree, c)
				} else {
					failed += 1
				}
			}
			continue
		}
		left, err := files.delete_tree(path)
		failed += left + (1 if err != .None else 0)
		if err == .None {
			survey.forget(&s.roll, &s.tree, c)
		}
	}
	freed := bytes - s.roll.totals[e.node]
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
