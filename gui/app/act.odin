package sonar_app

import "core:fmt"
import "core:strings"

import "../../scan"
import "../../survey"
import "../command"
import "../files"

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
