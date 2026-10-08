package sonar_history

import "core:strings"

import "../scan"
import "../survey"

/*
collect is what a finished scan keeps, in allocator: the top's total, named "",
then every entry under it that holds at least KEPT_MIN, all the way down, each
named by its path under the top. roll must be linked, so it lists each directory's
children. The window and the command line both keep a scan through this, so a
snapshot reads the same whichever kept it.
*/
collect :: proc(
	tree: ^scan.Tree,
	roll: ^survey.Rollup,
	top: u32,
	allocator := context.temp_allocator,
) -> []Entry {
	entries := make([dynamic]Entry, allocator)
	append(&entries, Entry{"", roll.totals[top]})
	collect_under(tree, roll, &entries, top, "", allocator)
	return entries[:]
}

// collect_under adds what dir holds of at least KEPT_MIN, all the way down, each
// named by its path under the top: dir's own is at.
@(private)
collect_under :: proc(
	tree: ^scan.Tree,
	roll: ^survey.Rollup,
	into: ^[dynamic]Entry,
	dir: u32,
	at: string,
	allocator := context.temp_allocator,
) {
	it := survey.children(roll, dir)
	for c in survey.next_child(&it) {
		n := scan.node(tree, c)
		directory := .Directory in scan.node_flags(n)
		bytes := roll.totals[c] if directory else n.disk
		if bytes < KEPT_MIN {
			continue
		}
		path := path_under(at, n.name, allocator)
		append(into, Entry{path, bytes})
		if directory {
			collect_under(tree, roll, into, c, path, allocator)
		}
	}
}

// path_under is the path of name in the directory at path at, under the top.
path_under :: proc(at, name: string, allocator := context.temp_allocator) -> string {
	if at == "" {
		return strings.clone(name, allocator)
	}
	return strings.concatenate({at, "/", name}, allocator)
}
