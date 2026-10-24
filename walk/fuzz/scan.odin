package walk_fuzz

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import harness "jm:fuzz"

import walk ".."
import scan "../../scan"
import survey "../../survey"

@(private)
mounts_once: sync.Once
@(private)
mounts_reason: string

// skip_reason is why the scan property cannot build a tree on this host, "" if it can.
skip_reason :: proc() -> string {
	sync.once_do(&mounts_once, proc() {
		mounts_reason = strings.clone(probe(), runtime.heap_allocator())
	})
	return mounts_reason
}

check_scan :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	if skip_reason() != "" {
		return "", true
	}
	flaw := scan_flaw(draw(src))
	return flaw, flaw == ""
}

// scan_flaw is what the walk gets wrong about a spec, shrunk to the smallest
// spec that goes wrong the same way, "" if nothing.
scan_flaw :: proc(spec: Spec, allocator := context.temp_allocator) -> string {
	class, what := scan_spec(spec, allocator)
	if class == "" {
		return ""
	}
	small := minimise(spec, still_fails, &class, 120, allocator)
	_, small_what := scan_spec(small, allocator)
	if small_what == "" {
		small_what = what
	}
	return format_reason(
		allocator,
		"%s: %s\nspec, from %d nodes down to %d:\n%s",
		class,
		small_what,
		len(spec.nodes) - 1,
		len(small.nodes) - 1,
		render(small, allocator),
	)
}

// still_fails says whether a smaller spec fails in the same way as the first.
@(private)
still_fails :: proc(spec: Spec, data: rawptr) -> bool {
	class := (^string)(data)^
	got, _ := scan_spec(spec)
	return got == class
}

/*
scan_spec builds the spec, walks it from each start and checks what came back.
The class is the kind of failure ("" for none), kept short so shrinking can hold
to it, and what is the detail.
*/
scan_spec :: proc(spec: Spec, allocator := context.temp_allocator) -> (class, what: string) {
	fx: Fixture
	defer destroy(&fx)
	if err := build(spec, &fx, allocator); err != "" {
		return "build", err
	}
	if err := sizes_match(spec, &fx, allocator); err != "" {
		return "materialiser", err
	}
	for start in starts(spec, fx.denies, 4, allocator) {
		class, what = scan_from(spec, &fx, start, allocator)
		if class != "" {
			return class, what
		}
	}
	return "", ""
}

// scan_from walks the directory of node `start` three ways, whole twice and then
// brought up to date from the first, and compares the first with the model.
@(private)
scan_from :: proc(spec: Spec, fx: ^Fixture, start: int, allocator: runtime.Allocator) -> (class, what: string) {
	at := format_reason(allocator, "walk from /%s", path_of(spec, start, allocator))
	want, reps := expected(spec, start, fx.denies, allocator)
	disk, err := allocated(fx, reps, allocator)
	if err != "" {
		return "materialiser", err
	}
	first, second, third: Scan_Result
	defer scan.tree_destroy(&first.tree)
	defer scan.tree_destroy(&second.tree)
	defer scan.tree_destroy(&third.tree)

	if class, what = read_whole(fx, start, &first, allocator); class != "" {
		return class, format_reason(allocator, "%s: %s", at, what)
	}
	if d := differ(want, first.tally, allocator); d != "" {
		return "tally", format_reason(allocator, "%s: %s", at, d)
	}
	if first.disk != disk {
		return "disk", format_reason(allocator, "%s: allocated bytes, statx says %d, the scan %d", at, disk, first.disk)
	}
	if class, what = read_whole(fx, start, &second, allocator); class != "" {
		return class, format_reason(allocator, "%s, again: %s", at, what)
	}
	if !same(&first, &second, allocator) {
		return "rescan", format_reason(allocator, "%s: a second scan of the same tree differs: %v then %v", at, first.tally, second.tally)
	}
	// Bringing the first scan up to date with nothing changed gives the scan a
	// whole read gives.
	if class, what = read_update(fx, start, &first.tree, &third, allocator); class != "" {
		return class, format_reason(allocator, "%s, updated: %s", at, what)
	}
	if !same(&first, &third, allocator) {
		return "incremental", format_reason(
			allocator,
			"%s: an update of an unchanged tree differs from a whole scan: %v then %v",
			at,
			first.tally,
			third.tally,
		)
	}
	// Following links reads a tree again by each name that leads to it, and a
	// loop of links must end: the scan comes back, with at least the directories
	// and no fewer files than the scan that does not follow.
	followed: Scan_Result
	defer scan.tree_destroy(&followed.tree)

	if class, what = read_whole(fx, start, &followed, allocator, follow = true); class != "" {
		return class, format_reason(allocator, "%s, following links: %s", at, what)
	}
	if followed.tally.dirs < want.dirs || followed.tally.files < want.files {
		return "follow", format_reason(
			allocator,
			"%s: following links finds fewer than not following: %v then %v",
			at,
			first.tally,
			followed.tally,
		)
	}
	return "", ""
}

// Scan_Result is one scan and what it adds up to.
Scan_Result :: struct {
	tree:  scan.Tree,
	tally: Tally,
	disk:  u64,
}

@(private)
same :: proc(a, b: ^Scan_Result, allocator: runtime.Allocator) -> bool {
	return a.disk == b.disk && slice.equal(signature(&a.tree, allocator), signature(&b.tree, allocator))
}

// read_whole scans the directory of node `start` once.
@(private)
read_whole :: proc(fx: ^Fixture, start: int, w: ^Scan_Result, allocator: runtime.Allocator, follow := false) -> (class, what: string) {
	if scan.tree_init(&w.tree, 1) != .None {
		return "walk", "no tree"
	}
	restore: proc()
	if fx.denies {
		restore, _ = deny(fx)
	}
	err := walk.read(fx.paths[start], &w.tree, walk.Config{follow = follow})
	if restore != nil {
		restore()
	}
	if err != .None {
		return "walk", format_reason(allocator, "read says %v", err)
	}
	add_up(w)
	return "", ""
}

// read_update reads the directory of node `start` again from the tree `base`,
// which was read before and has not changed, as the probe-based update does.
@(private)
read_update :: proc(
	fx: ^Fixture,
	start: int,
	base: ^scan.Tree,
	w: ^Scan_Result,
	allocator: runtime.Allocator,
	since := i64(0),
	restat := false,
) -> (
	class, what: string,
) {
	if scan.tree_init(&w.tree, 1) != .None {
		return "walk", "no tree"
	}
	restore: proc()
	if fx.denies {
		restore, _ = deny(fx)
	}
	u := walk.Update {
		base  = base,
		probe = true,
		since = since if since != 0 else time.now()._nsec,
	}
	if restat {
		// A file written in place moves only its own time, not its directory's
		// (update.odin, Update): ask each file of a byte or more its size again.
		u.restat, u.slices = 1, 0
	}
	err := walk.update(fx.paths[start], &u, &w.tree, walk.Config{})
	if restore != nil {
		restore()
	}
	if err != .None {
		return "walk", format_reason(allocator, "update says %v", err)
	}
	add_up(w)
	return "", ""
}

// add_up fills in what a read tree adds up to.
@(private)
add_up :: proc(w: ^Scan_Result) {
	w.tally = tally_of(&w.tree)
	roll: survey.Rollup
	roll.linked = true
	defer survey.rollup_destroy(&roll)
	survey.rollup_advance(&roll, &w.tree)
	w.disk = survey.total(&roll, u32(w.tree.root))
}

// tally_of is what the tree says it found.
tally_of :: proc(t: ^scan.Tree) -> (out: Tally) {
	for i in 0 ..< scan.slots(t) {
		flags := scan.node_flags(scan.node(t, i))
		if .Used not_in flags {
			continue
		}
		switch {
		case .Mount in flags:
			out.mounts += 1
		case .Directory in flags:
			out.dirs += 1
			if .Unread in flags {
				out.unread += 1
			}
		case .Reparse in flags:
			out.symlinks += 1
		case .Extra_Name in flags:
			out.extras += 1
		case:
			out.files += 1
		}
	}
	return
}

// signature is every node as path, flags and disk, sorted: what two scans of one
// tree must agree on whatever order the workers met it in.
@(private)
signature :: proc(t: ^scan.Tree, allocator: runtime.Allocator) -> []string {
	out := make([dynamic]string, allocator)
	for i in 0 ..< scan.slots(t) {
		n := scan.node(t, i)
		flags := scan.node_flags(n)
		if .Used not_in flags {
			continue
		}
		append(&out, format_reason(allocator, "%s %v %d", node_path(t, i, allocator), flags, n.disk))
	}
	slice.sort(out[:])
	return out[:]
}

// node_path is a node's names up to the root, innermost first.
@(private)
node_path :: proc(t: ^scan.Tree, i: u32, allocator: runtime.Allocator) -> string {
	path := strings.builder_make(allocator)
	at := i
	for hops := 0; hops < 128; hops += 1 {
		strings.write_string(&path, scan.name_of(t, at))
		strings.write_byte(&path, '/')
		up := scan.node(t, at).parent
		if up == at {
			break
		}
		at = up
	}
	return strings.to_string(path)
}
