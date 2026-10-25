/*
Package survey drives a reader into a tree and keeps the totals folded from it: the
part of a scan that is the same whoever is looking, a command line or a window.
*/
package survey

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

import "../ntfs"
import "../scan"
import "../synth"
import "../walk"

/*
Runs a reader into the tree.

The one place that knows how each reader is driven. A watched scan and an unwatched
one reach the same tree by the same route, rather than by two routes that happen to
agree; the only difference between them is whether the tree is folded as it fills or
once at the end.

`scanning` is clear once nothing is filling the tree any more. A caller that draws
while it runs watches that; one that does not simply waits for `fill_run` to return.
*/
Fill :: struct {
	// What to read, and how.
	target:    scan.Target,
	engine:    scan.Engine,
	// The choice's probe (scan.Choice): walk within the probe's budget first, and
	// read from the MFT past it. engine says which ran once fill_run returns, and
	// escalated is set as soon as the MFT is what will.
	probe:     bool,
	escalated: b32,
	opts:      ntfs.Read_Options,
	wcfg:      walk.Config,
	// Whether anything is reading the tree while it fills. A reader that has to fold
	// pays for doing so repeatedly, which is worth it only if someone is looking.
	watched:   bool,
	tree:      ^scan.Tree,
	// The made-up disk's clock for this fill alone, in place of synth.config's
	// (clock_override, else the pace of a walk); zero for that.
	clock:     synth.Clock,
	// A file to keep the place's whole tree in between runs. Set, the place is
	// updated from it by what the system says changed, when that can be trusted, and
	// read whole otherwise; either way the result is kept there for next time. Empty,
	// the place is read whole and nothing is kept, as with history off. See
	// update.odin.
	baseline:  string, //review:ignore odin-destroy-incomplete borrowed from the caller
	whole:     bool, // with a baseline: read the place whole all the same, and keep it
	how:       Fill_Kind, // with a baseline: whether the place was read whole or updated
	by:        Read_Source, // updated: what said which directories changed
	why:       string, //review:ignore odin-destroy-incomplete a constant, never freed: why it was read whole
	reread:    u64, // updated: how many directories were read rather than copied
	taken:     time.Time, // updated: when the tree updated from was kept
	saved:     bool, // the result was kept as the next baseline
	// The MFT reader's own table, which carries what only NTFS knows. It outlives the
	// tree, whose names are borrowed from it.
	table:     ntfs.Mft,
	// What it left behind.
	mft_err:   ntfs.Error,
	walk_err:  walk.Error,
	synth_err: synth.Error,
	tree_err:  scan.Error,
	reading:   b32, // the table is still being read
	scanning:  b32, // the tree is still being filled
}

fill_destroy :: proc(f: ^Fill) {
	ntfs.mft_destroy(&f.table)
}

// Run the reader to completion. The one place a reader is chosen.
fill_run :: proc(f: ^Fill) {
	defer sync.atomic_store(&f.scanning, false)

	if f.baseline != "" && (f.engine == .Mft || f.engine == .Walk) {
		fill_from_baseline(f)
		return
	}
	fill_whole(f, nil)
}

/*
Read the place whole, with the reader chosen. A choice that waits on the place's
size is settled first: by `prior`, the entries it held when last kept, when there is
one, and otherwise by a probe.
*/
@(private)
fill_whole :: proc(f: ^Fill, prior: Maybe(u64)) {
	if f.probe {
		f.probe = false
		// Only an NTFS subtree that opened raw waits on its size.
		size := scan.Size {
			prior = prior,
		}
		c := scan.choose(f.target, true, size)
		if c.probe {
			size.probe = probe(f)
			c = scan.choose(f.target, true, size)
		}
		f.engine = c.engine
		if f.engine == .Mft {
			sync.atomic_store(&f.escalated, true)
		}
	}

	switch f.engine {
	case .Mft:
		fill_mft(f)
	case .Walk:
		fill_walk(f)
	case .Synthetic:
		fill_synthetic(f)
	case .None:
	}
}

/*
Walk the place into a tree of its own, and call the walk off once it reads more than
scan.WALK_MOST entries or takes longer than scan.PROBE_TIME. A place it reads whole
inside that is walked again into f.tree, from a warm cache: what the probe read is
thrown away rather than copied, since a watcher may already hold f.tree, and the
budget caps what that costs. A place cancelled while probed is let through as Within,
and the walk that follows stops straight away.
*/
@(private)
probe :: proc(f: ^Fill, allocator := context.allocator) -> scan.Probe {
	p := Probe_Walk {
		fill = f,
		root = scan.location(f.target, allocator),
	}
	defer delete(p.root, allocator)

	if scan.tree_init(&p.tree, walk.width(f.wcfg)) != nil {
		return .Over
	}
	defer scan.tree_destroy(&p.tree)

	start := time.tick_now()
	walker := thread.create_and_start_with_poly_data(&p, probe_walk, init_context = context)
	if walker == nil {
		return .Over
	}
	defer thread.destroy(walker)

	over := false
	for !sync.sema_wait_with_timeout(&p.done, PROBE_POLL) {
		if scan.cancelled(f.tree) {
			scan.cancel(&p.tree)
		}
		if !over &&
		   (sync.atomic_load(&p.tree.nodes_done) > scan.WALK_MOST ||
				   time.tick_since(start) > scan.PROBE_TIME) {
			over = true
			scan.cancel(&p.tree)
		}
	}
	thread.join(walker)
	return .Over if over else .Within
}

// How often a probe looks at its walk, which is as late as a walk past the budget
// is called off.
@(private)
PROBE_POLL :: 5 * time.Millisecond

@(private)
Probe_Walk :: struct {
	fill: ^Fill,
	root: string,
	tree: scan.Tree,
	done: sync.Sema,
}

@(private)
probe_walk :: proc(p: ^Probe_Walk) {
	cfg := p.fill.wcfg
	cfg.fold = false
	_ = walk.read(p.root, &p.tree, cfg)
	sync.sema_post(&p.done)
}

// What went wrong, in words, or "" if nothing did. The MFT's failures get their
// own words because they are the ones a reader of them can act on.
problem :: proc(f: ^Fill, allocator := context.temp_allocator) -> string {
	if f.mft_err != nil {
		#partial switch f.mft_err {
		case .Access_Denied:
			return fmt.aprint(
				"access denied. Reading a raw volume needs an administrator prompt.",
				allocator = allocator,
			)
		case .Not_Ntfs:
			return fmt.aprint("not an NTFS volume", allocator = allocator)
		case .Open_Failed:
			return fmt.aprintf("could not open %s", f.target.volume, allocator = allocator)
		case:
			return fmt.aprintf("%v", f.mft_err, allocator = allocator)
		}
	}
	if f.walk_err != nil {
		return fmt.aprintf(
			"walking %s: %v",
			scan.location(f.target, context.temp_allocator),
			f.walk_err,
			allocator = allocator,
		)
	}
	if f.synth_err != nil {
		return fmt.aprintf("making the disk up: %v", f.synth_err, allocator = allocator)
	}
	if f.tree_err != nil {
		return fmt.aprintf("%v", f.tree_err, allocator = allocator)
	}
	return ""
}

/*
Read the table, folding it into the tree.

read_mft blocks until the whole table is read, so a watched scan gives it a thread and
folds beside it. Either way a record settled part way through misses whatever
extension records added to it afterwards, so every record is folded again at the end
and the tree restated, which is how a watcher learns its totals have to start over.

The root is named inside the projection rather than afterwards: the table calls it
".", and a watcher has been known to catch the dot.
*/
@(private)
fill_mft :: proc(f: ^Fill) {
	p: ntfs.Projection
	// The whole volume names its root after the mount; a subtree the record was
	// found for names it after the whole path, the same leading segment a walk
	// of the same subtree would give it.
	root_name := scan.location(f.target, context.allocator)
	defer delete(root_name)
	p.root_name = root_name
	p.root_record = f.target.record.? or_else 0
	defer ntfs.projection_destroy(&p)

	if f.watched {
		sync.atomic_store(&f.reading, true)
		reader := thread.create_and_start_with_poly_data(f, fill_mft_read)
		if reader == nil {
			f.mft_err = .Open_Failed
			return
		}
		defer thread.destroy(reader)

		for {
			// Read first, so a table that finishes mid-fold still gets one more pass.
			reading := bool(sync.atomic_load(&f.reading))
			if ntfs.mft_ready(&f.table) {
				if err := ntfs.to_tree(&f.table, f.tree, &p); err != nil {
					f.tree_err = err
					break
				}
			}
			if !reading {
				break
			}
		}
		thread.join(reader)
	} else {
		f.mft_err = ntfs.read_mft(f.target.volume, &f.table, f.opts)
	}
	if f.mft_err != nil || f.tree_err != nil {
		return
	}

	ntfs.projection_reset(&p)
	if err := ntfs.to_tree(&f.table, f.tree, &p); err != nil {
		f.tree_err = err
		return
	}
	scan.restate(f.tree)
}

@(private)
fill_mft_read :: proc(f: ^Fill) {
	f.mft_err = ntfs.read_mft(f.target.volume, &f.table, f.opts)
	sync.atomic_store(&f.reading, false)
}

// Walk directories straight into the tree. Nothing is restated: a walk reaches a child
// through its parent, so a node is final when it is written, watched or not.
@(private)
fill_walk :: proc(f: ^Fill) {
	root := scan.location(f.target, context.allocator)
	defer delete(root)
	cfg := f.wcfg
	// The watcher charges on its own thread. Folding here too would count twice.
	cfg.fold = !f.watched
	f.walk_err = walk.read(root, f.tree, cfg)
}

// Make the disk up, at the pace of a walk, for the day the target was resolved with.
@(private)
fill_synthetic :: proc(f: ^Fill) {
	cfg := synth.config(f.target.day)
	if f.clock.wait != nil {
		cfg.clock = f.clock
	}
	root := scan.location(f.target, context.allocator)
	defer delete(root)
	f.synth_err = synth.read(root, f.tree, cfg)
}
