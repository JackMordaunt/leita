/*
Package report describes one finished scan of one target as plain data, and
writes that description as CSV, JSON or HTML for a person to keep, attach to a
ticket or feed to another program.

A Report is built once from the scan (build) and then only read: every format is
written from the same Report, so a CSV and an HTML of one scan never disagree,
and whatever else writes one (a PDF, the window's export) builds it the same way.
It holds no type from the window and nothing about the person beyond the paths
scanned.

Paths are kept as the tree has them: whatever bytes the filesystem allowed, which
need not be UTF-8. Each format says how it writes those (see export).
*/
package report

import "core:mem"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "../history"
import "../home"
import "../kinds"
import "../reclaim"
import "../scan"
import "../survey"
import "../synth"
import "../version"

// DEFAULT_TOP is how many of the largest directories and files a report lists
// when its caller does not say.
DEFAULT_TOP :: 50

Report :: struct {
	generated:           time.Time, // when the report was built
	version:             string, // the leita that built it
	// Whose licence the leita that built it runs under, "" for none: every
	// format says so where it says what built it, as it says a name: a CSV cell
	// of it is neutralised like a path's.
	licensee:            string,
	// A CSV or JSON of the current scan, written with no licence and no earlier
	// scan attached. The note says it is free. A Pro report with no licence,
	// during the evaluation, leaves this false and names the evaluation.
	free_export:         bool,
	// An earlier scan of this place was kept and not attached. The note says
	// so, rather than that there was no earlier scan.
	earlier_kept:        bool,
	target:              string, // the path scanned, its top; the display formats picture its controls
	volume:              string, // the device behind it, "" when unknown
	filesystem:          scan.Filesystem,
	engine:              scan.Engine, // JSON preserves the source, including .Synthetic
	started:             time.Time, // when the scan began
	duration:            time.Duration, // how long it took
	bytes:               u64, // on disk under the target, the target's own included
	files:               u64,
	directories:         u64, // under the target, not counting it
	unread:              u64, // directories the scan could not open, so left out
	space:               Maybe(Space),
	retention:           Maybe(Volume_Retention), // APFS local snapshots and purgeable space
	// The earlier scan the largest entries are compared with: absent when there
	// is none, or when one was kept and not attached (earlier_kept).
	compared:            Maybe(Baseline),
	largest_directories: []Entry, // largest first
	largest_files:       []Entry, // largest first
	// What the target holds by kind: every file by what it is, everything under a
	// build or cache directory as Cache, and each directory's own allocation as
	// Folder. They add up to bytes.
	kinds:               [kinds.Kind]Kind_Total,
	// What can be deleted without losing anything, by category, in the order of
	// reclaim.Category, a category with nothing in it left out: absent unless the
	// caller asked for it.
	reclaim:             Maybe([]Group),
	// Whether the volume's space passes the limits asked for (threshold.odin),
	// absent unless --warn-used, --fail-used or --min-free was.
	thresholds:          Maybe(Threshold),
	allocator:           mem.Allocator,
}

// Space is what the volume holds and has free, in bytes.
Space :: struct {
	total: u64,
	free:  u64,
}

Volume_Retention :: struct {
	snapshots: scan.Snapshot_State,
	names:     []string, // owned by the report
	purgeable: Maybe(u64), // no verified public numeric API on macOS 11+
}

// Baseline is the earlier scan of the same place that sizes are compared with:
// when it was taken and what its top held.
Baseline :: struct {
	taken: time.Time,
	bytes: u64,
}

// Entry is a directory or a file: its full path, what it holds on disk, what
// it is, and what it held in the scan compared with, when that scan kept it.
Entry :: struct {
	path:  string,
	bytes: u64,
	kind:  kinds.Kind,
	was:   Maybe(u64),
}

Kind_Total :: struct {
	bytes: u64,
	files: u64, // files of this kind; directories are not counted
}

// Group is the candidates of one Reclaim category, largest first.
Group :: struct {
	category: reclaim.Category,
	bytes:    u64,
	items:    []Candidate,
}

Candidate :: struct {
	path:  string,
	bytes: u64,
}

// Facts are what the caller knows of a scan that its tree does not say.
Facts :: struct {
	target:   scan.Target,
	engine:   scan.Engine,
	started:  time.Time,
	duration: time.Duration,
	space:    Maybe(Space),
}

/*
Options are what a report holds beyond the scan's own.

top is how many of the largest directories and files to list, DEFAULT_TOP for 0.
reclaim asks for Reclaim's candidates, which needs the rollup linked
(survey.Rollup.linked) before it rolled anything up; user is whose home directory
and id those are relative to, the zero value for the person running the process.

previous is an earlier scan of the same place to compare with: its entries by
path under the top, names joined by "/", "" for the top, as the window keeps
them (history).
*/
Options :: struct {
	top:         int,
	reclaim:     bool,
	user:        home.User,
	previous:    Maybe(Snapshot),
	licensee:     string, // whose licence leita runs under, "" for none
	free_export:  bool, // current-scan CSV or JSON with no licence and no earlier scan
	earlier_kept: bool, // an earlier scan was kept and is not in previous
	warn_used:    int, // --warn-used, percent used; 0 for no check
	fail_used:    int, // --fail-used, percent used; 0 for no check
	min_free:     u64, // --min-free, bytes; 0 for no check
}

// Snapshot is an earlier scan as history keeps it: when it was taken, and what
// each entry held by its path under the top.
Snapshot :: struct {
	taken:   time.Time,
	entries: map[string]u64,
}

// share is what bytes is of the whole report, 0 to 1; 0 for an empty one.
share :: proc(r: ^Report, bytes: u64) -> f64 {
	if r.bytes == 0 {
		return 0
	}
	return f64(bytes) / f64(r.bytes)
}

// change is what an entry gained since the scan compared with, negative for
// what it lost, and whether that scan kept it at all.
change :: proc(e: Entry) -> (delta: i64, ok: bool) {
	was := e.was.? or_return
	return i64(e.bytes) - i64(was), true
}

/*
build describes the scan in t, rolled up by roll, from its top. The tree must be
finished: nothing still filling it, its rollup advanced over all of it. What the
report holds is in allocator; destroy frees it.
*/
build :: proc(
	t: ^scan.Tree,
	roll: ^survey.Rollup,
	facts: Facts,
	opt: Options,
	allocator := context.allocator,
) -> (
	r: Report,
) {
	r.allocator = allocator
	r.generated = time.now()
	r.version = strings.clone(version.VERSION, allocator)
	r.licensee = strings.clone(opt.licensee, allocator)
	r.free_export = opt.free_export
	r.earlier_kept = opt.earlier_kept
	r.volume = strings.clone(facts.target.volume, allocator)
	r.filesystem = facts.target.fs
	r.engine = facts.engine
	r.started = facts.started
	r.duration = facts.duration
	r.space = facts.space
	if scan.has_snapshot_volume(t) {
		measured := scan.retention_of(t)
		retained := Volume_Retention {
			snapshots = measured.snapshots,
		}
		if measured.purgeable_known {
			retained.purgeable = measured.purgeable
		}
		names := scan.snapshot_names_of(t)
		retained.names = make([]string, len(names), allocator)
		for name, i in names {
			retained.names[i] = strings.clone(name, allocator)
		}
		r.retention = retained
	}
	if th, configured, _ := threshold_of(
		r.space,
		opt.warn_used,
		opt.fail_used,
		opt.min_free,
		allocator,
	); configured {
		r.thresholds = th
	}

	top := t.root
	if top >= roll.seen || .Used not_in scan.node_flags(scan.node(t, top)) {
		r.target = scan.location(facts.target, allocator)
		return
	}
	r.target = scan.path(t, top, allocator)
	r.bytes = survey.total(roll, top)
	r.unread, _ = scan.unread(t)

	n := opt.top if opt.top > 0 else DEFAULT_TOP
	dirs := make([]Contender, n, context.temp_allocator)
	files := make([]Contender, n, context.temp_allocator)
	dir_count, file_count := 0, 0

	// Where each node lies, found once per node rather than once per node and
	// ancestor: survey.Rollup's doc records 2,581,257 nodes in one home
	// directory, each reached through every directory above it.
	places := make([]Place, roll.seen, context.temp_allocator)
	places[top] = {.Known, .Under}
	// The top is named by its whole path; its last name says what it is.
	if kinds.of(filepath.base(scan.name_of(t, top)), true) == .Cache {
		places[top] += {.Cache}
	}
	for i in 0 ..< roll.seen {
		node := scan.node(t, i)
		flags := scan.node_flags(node)
		if .Used not_in flags || .Settled not_in flags || .Extra_Name in flags {
			continue
		}
		at := locate(t, roll, places, i)
		if .Under not_in at || survey.removed(roll, t, i) {
			continue
		}
		if .Directory in flags {
			r.kinds[.Cache if .Cache in at else .Folder].bytes += node.disk
			if i == top {
				continue
			}
			r.directories += 1
			if bytes := survey.total(roll, i); bytes > 0 {
				keep_largest(dirs, &dir_count, {bytes, i})
			}
			continue
		}
		kind := kinds.Kind.Cache if .Cache in at else kinds.of(scan.name_of(t, i), false)
		r.kinds[kind].bytes += node.disk
		r.kinds[kind].files += 1
		r.files += 1
		if node.disk > 0 {
			keep_largest(files, &file_count, {node.disk, i})
		}
	}

	prev, comparing := opt.previous.?
	if comparing {
		if bytes, kept := prev.entries[""]; kept {
			r.compared = Baseline{prev.taken, bytes}
		} else {
			comparing = false
		}
	}
	entries :: proc(
		t: ^scan.Tree,
		places: []Place,
		top: u32,
		ranked: []Contender,
		prev: ^Snapshot,
		allocator: mem.Allocator,
	) -> []Entry {
		out := make([]Entry, len(ranked), allocator)
		for s, i in ranked {
			flags := scan.node_flags(scan.node(t, s.node))
			kind :=
				kinds.Kind.Folder if .Directory in flags else kinds.of(scan.name_of(t, s.node), false)
			if .Cache in places[s.node] {
				kind = .Cache
			}
			out[i] = {
				path  = scan.path(t, s.node, allocator),
				bytes = s.bytes,
				kind  = kind,
			}
			if prev != nil {
				if was, kept := prev.entries[history.entry_path(t, top, s.node)]; kept {
					out[i].was = was
				}
			}
		}
		return out
	}
	p := &prev if comparing else nil
	r.largest_directories = entries(t, places, top, dirs[:dir_count], p, allocator)
	r.largest_files = entries(t, places, top, files[:file_count], p, allocator)

	if opt.reclaim {
		r.reclaim = candidates(t, roll, top, r.target, opt.user, facts.engine, allocator)
	}
	return
}

destroy :: proc(r: ^Report) {
	if retained, ok := r.retention.?; ok {
		for name in retained.names {delete(name, r.allocator)}
		delete(retained.names, r.allocator)
	}
	for e in r.largest_directories {
		delete(e.path, r.allocator)
	}
	delete(r.largest_directories, r.allocator)
	for e in r.largest_files {
		delete(e.path, r.allocator)
	}
	delete(r.largest_files, r.allocator)
	if groups, ok := r.reclaim.?; ok {
		for g in groups {
			for c in g.items {
				delete(c.path, r.allocator)
			}
			delete(g.items, r.allocator)
		}
		delete(groups, r.allocator)
	}
	if th, ok := r.thresholds.?; ok {
		for reason in th.reasons {
			delete(reason, r.allocator)
		}
		delete(th.reasons, r.allocator)
	}
	delete(r.version, r.allocator)
	delete(r.licensee, r.allocator)
	delete(r.target, r.allocator)
	delete(r.volume, r.allocator)
	r^ = {}
}

// Contender is a node and what it holds, for keeping the largest.
@(private)
Contender :: struct {
	bytes: u64,
	node:  u32,
}

// Place is what build has learned of places a node lies: under the top, and
// under a build or cache directory, once Known.
@(private)
Place_Flag :: enum u8 {
	Known,
	Under,
	Cache,
}
@(private)
Place :: bit_set[Place_Flag;u8]

// locate is places node i lies, learning it for i and every ancestor of i not
// yet known. A chain that ends anywhere but the top, an orphan's or one too deep
// to follow, is not under it.
@(private)
locate :: proc(t: ^scan.Tree, roll: ^survey.Rollup, places: []Place, i: u32) -> Place {
	chain: [64]u32
	depth := 0
	cur := i
	found: Place
	for {
		if .Known in places[cur] {
			found = places[cur]
			break
		}
		if depth == len(chain) {
			found = {.Known}
			break
		}
		chain[depth] = cur
		depth += 1
		parent := scan.node(t, cur).parent
		if parent == cur || parent >= roll.seen {
			found = {.Known}
			break
		}
		cur = parent
	}
	// Down from the ancestor known, each directory passing on what it is.
	for j := depth - 1; j >= 0; j -= 1 {
		at := found & {.Known, .Under, .Cache}
		node := chain[j]
		if .Under in at &&
		   .Directory in scan.node_flags(scan.node(t, node)) &&
		   kinds.of(scan.name_of(t, node), true) == .Cache {
			at += {.Cache}
		}
		places[node] = at
		found = at
	}
	return found
}

// Keep the n largest in descending order without sorting them all.
@(private)
keep_largest :: proc(top: []Contender, count: ^int, cand: Contender) {
	if count^ == len(top) && cand.bytes <= top[len(top) - 1].bytes {
		return
	}
	i := count^ if count^ < len(top) else len(top) - 1
	for i > 0 && top[i - 1].bytes < cand.bytes {
		top[i] = top[i - 1]
		i -= 1
	}
	top[i] = cand
	if count^ < len(top) {
		count^ += 1
	}
}

// candidates is what Reclaim finds under top, grouped as the window groups it.
@(private)
candidates :: proc(
	t: ^scan.Tree,
	roll: ^survey.Rollup,
	top: u32,
	top_path: string,
	user: home.User,
	engine: scan.Engine,
	allocator: mem.Allocator,
) -> []Group {
	assert(roll.linked, "Reclaim needs a linked rollup")
	Source_Data :: struct {
		t:    ^scan.Tree,
		roll: ^survey.Rollup,
	}
	data := Source_Data{t, roll}
	src := reclaim.Source {
		data = &data,
		name = proc(data: rawptr, node: u32) -> string {
			return scan.name_of((^Source_Data)(data).t, node)
		},
		directory = proc(data: rawptr, node: u32) -> bool {
			flags := scan.node_flags(scan.node((^Source_Data)(data).t, node))
			return flags & {.Directory, .Mount} == {.Directory}
		},
		bytes = proc(data: rawptr, node: u32) -> u64 {
			d := (^Source_Data)(data)
			n := scan.node(d.t, node)
			return survey.total(d.roll, node) if .Directory in scan.node_flags(n) else n.disk
		},
		children = proc(data: rawptr, node: u32, into: ^[dynamic]u32) {
			it := survey.children((^Source_Data)(data).roll, node)
			for c in survey.next_child(&it) {
				append(into, c)
			}
		},
	}
	who := user
	if who == {} {
		// A made-up disk has a made-up owner, whose home is where its caches are.
		who =
			home.User{synth.HOME, ""} if engine == .Synthetic else home.user(context.temp_allocator)
	}
	// The made-up disk is a Mac's.
	platform := reclaim.Platform.Darwin if engine == .Synthetic else reclaim.HOST
	found := reclaim.find(src, top, top_path, who, context.temp_allocator, platform)
	// By category, and within one largest first as find left them.
	slice.stable_sort_by(found, proc(a, b: reclaim.Candidate) -> bool {
		return a.category < b.category
	})
	groups := make([dynamic]Group, allocator)
	for i := 0; i < len(found); {
		j := i
		for j < len(found) && found[j].category == found[i].category {
			j += 1
		}
		g := Group {
			category = found[i].category,
			items    = make([]Candidate, j - i, allocator),
		}
		for c, k in found[i:j] {
			g.items[k] = {strings.clone(c.path, allocator), c.bytes}
			g.bytes += c.bytes
		}
		append(&groups, g)
		i = j
	}
	shrink(&groups)
	return groups[:]
}
