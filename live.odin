package main

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

import "ntfs"
import "scan"
import "walk"

/*
Stand in for a UI.

Three jobs, as the scan is meant to run: a reader filling the tree, a builder owning
everything derived from it, and this loop drawing. The point of the arrangement is
that a frame costs the same whatever the volume holds, because it reads a published
snapshot of twenty rows rather than the tree.

Which reader fills it is decided in one switch below and nowhere else. The builder is
told nothing about it: a reader settles nodes, and restates if it has to correct
itself, and that is the whole of the conversation.

Nothing here waits on the builder. If a build pass is mid-write the loop draws the
answer from the last one.
*/
FRAME :: 16 * time.Millisecond

// A reader filling the tree, and what it left behind. Only the fields its own engine
// uses are set.
@(private = "file")
Fill :: struct {
	tree:     ^scan.Tree,
	table:    ^ntfs.Mft,
	volume:   string,
	// Where a walk starts, or what an MFT calls its root. One reader runs, and it
	// reads the one that means something to it.
	root:     string,
	opts:     ntfs.Read_Options,
	wcfg:     walk.Config,
	mft_err:  ntfs.Error,
	walk_err: walk.Error,
	tree_err: scan.Error,
	reading:  b32, // the table is still being read
	scanning: b32, // the tree is still being filled
}

run_live :: proc(
	target: scan.Target,
	choice: scan.Choice,
	opts: ntfs.Read_Options,
	wcfg: walk.Config,
) -> int {
	m: ntfs.Mft
	defer ntfs.mft_destroy(&m)

	t: scan.Tree
	if err := scan.tree_init(&t, 8); err != nil {
		fmt.eprintfln("error: %v", err)
		return 1
	}
	defer scan.tree_destroy(&t)

	out: scan.Publisher
	started := time.tick_now()

	f := Fill {
		tree     = &t,
		table    = &m,
		volume   = target.volume,
		opts     = opts,
		wcfg     = wcfg,
		scanning = true,
	}
	b := Builder {
		tree     = &t,
		out      = &out,
		scanning = &f.scanning,
		started  = started,
	}

	// Freed at function scope. A defer inside the switch below would run as the case
	// ended, with the reader still holding the string.
	owned_root: string
	defer if owned_root != "" {
		delete(owned_root)
	}

	// The one place a reader is chosen for a live scan, as in the batch path.
	filler: ^thread.Thread
	switch choice.engine {
	case .Mft:
		f.root = scan.top(target)
		filler = thread.create_and_start_with_poly_data(&f, mft_fill)
	case .Walk:
		owned_root = scan.location(target, context.allocator)
		f.root = owned_root
		filler = thread.create_and_start_with_poly_data(&f, walk_fill)
	case .None:
		fmt.eprintln("error: nothing here can be scanned")
		return 1
	}
	if filler == nil {
		fmt.eprintln("error: could not start the reader")
		return 1
	}
	defer thread.destroy(filler)

	builder := thread.create_and_start_with_poly_data(&b, build_thread)
	if builder == nil {
		fmt.eprintln("error: could not start the builder")
		return 1
	}
	defer thread.destroy(builder)
	defer rollup_destroy(&b.roll)

	frames, drawn, missed := 0, 0, 0
	last: scan.Snapshot
	have := false

	for {
		frame_start := time.tick_now()
		finished := bool(sync.atomic_load(&b.done))

		if s, ok := scan.current(&out); ok {
			last = s
			have = true
			drawn += 1
		} else {
			missed += 1
		}

		if have && last.count > 0 {
			fmt.printfln(
				"frame %3d %6.0f ms %8d nodes %6d pending  %10s  %s  frame %5.2f ms%s",
				frames,
				last.elapsed,
				last.nodes,
				last.pending,
				human(last.rows[0].bytes),
				scan.path(&t, last.rows[0].node, context.temp_allocator),
				time.duration_milliseconds(time.tick_since(frame_start)),
				last.complete ? "  (final)" : "",
			)
			free_all(context.temp_allocator)
		}
		frames += 1

		if finished {
			break
		}

		if spent := time.tick_since(frame_start); spent < FRAME {
			time.sleep(FRAME - spent)
		}
	}

	thread.join(filler)
	thread.join(builder)

	if f.mft_err != nil {
		fmt.eprintfln("error: %v", f.mft_err)
		return 1
	}
	if f.walk_err != nil {
		fmt.eprintfln("error: %v", f.walk_err)
		return 1
	}
	if f.tree_err != nil {
		fmt.eprintfln("error: %v", f.tree_err)
		return 1
	}

	fmt.println()
	fmt.printfln(
		"scan finished in %.0f ms over %d frames, %d drawn, %d skipped mid-write",
		time.duration_milliseconds(time.tick_since(started)),
		frames,
		drawn,
		missed,
	)

	print_largest(&t, b.roll.totals[:], .files)
	print_largest(&t, b.roll.totals[:], .directories)

	return 0
}

/*
Read the table on its own threads, folding it into the tree as it fills.

read_mft blocks until the whole table is read, so it gets a thread and this one folds
beside it. A record settled part way through misses whatever extension records added
to it afterwards, so once the reading is over every record is folded again and the
tree restated, which is how the builder learns its totals have to start over.
*/
@(private = "file")
mft_fill :: proc(f: ^Fill) {
	defer sync.atomic_store(&f.scanning, false)

	sync.atomic_store(&f.reading, true)
	reader := thread.create_and_start_with_poly_data(f, mft_read)
	if reader == nil {
		f.mft_err = .Open_Failed
		return
	}
	defer thread.destroy(reader)

	p: ntfs.Projection
	p.root_name = f.root
	defer ntfs.projection_destroy(&p)

	for {
		// Read first, so a table that finishes mid-fold still gets one more pass.
		reading := bool(sync.atomic_load(&f.reading))
		if ntfs.mft_ready(f.table) {
			if err := ntfs.to_tree(f.table, f.tree, &p); err != nil {
				f.tree_err = err
				break
			}
		}
		if !reading {
			break
		}
	}
	thread.join(reader)
	if f.mft_err != nil || f.tree_err != nil {
		return
	}

	ntfs.projection_reset(&p)
	if err := ntfs.to_tree(f.table, f.tree, &p); err != nil {
		f.tree_err = err
		return
	}
	scan.restate(f.tree)
}

@(private = "file")
mft_read :: proc(f: ^Fill) {
	f.mft_err = ntfs.read_mft(f.volume, f.table, f.opts)
	sync.atomic_store(&f.reading, false)
}

// Walk directories straight into the tree. Nothing is restated: a walk reaches a child
// through its parent, so a node is final when it is written.
@(private = "file")
walk_fill :: proc(f: ^Fill) {
	defer sync.atomic_store(&f.scanning, false)
	f.walk_err = walk.scan(f.root, f.tree, f.wcfg)
}

@(private = "file")
build_thread :: proc(b: ^Builder) {
	builder_run(b)
}
