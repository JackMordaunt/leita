package main

import "core:fmt"
import "core:sync"
import "core:thread"

import "ntfs"
import "scan"
import "walk"

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
	target:   scan.Target,
	engine:   scan.Engine,
	opts:     ntfs.Read_Options,
	wcfg:     walk.Config,
	// Whether anything is reading the tree while it fills. A reader that has to fold
	// pays for doing so repeatedly, which is worth it only if someone is looking.
	watched:  bool,
	tree:     ^scan.Tree,
	// The MFT reader's own table, which carries what only NTFS knows. It outlives the
	// tree, whose names are borrowed from it.
	table:    ntfs.Mft,
	// What it left behind.
	mft_err:  ntfs.Error,
	walk_err: walk.Error,
	tree_err: scan.Error,
	reading:  b32, // the table is still being read
	scanning: b32, // the tree is still being filled
}

fill_destroy :: proc(f: ^Fill) {
	ntfs.mft_destroy(&f.table)
}

// Run the reader to completion. The one place a reader is chosen.
fill_run :: proc(f: ^Fill) {
	defer sync.atomic_store(&f.scanning, false)

	switch f.engine {
	case .Mft:
		fill_mft(f)
	case .Walk:
		fill_walk(f)
	case .None:
	}
}

// Say what went wrong, if anything did. The MFT's failures get their own words
// because they are the ones a reader of them can act on.
fill_report :: proc(f: ^Fill) -> bool {
	if f.mft_err != nil {
		#partial switch f.mft_err {
		case .Access_Denied:
			fmt.eprintln(
				"error: access denied. Reading a raw volume needs an administrator prompt.",
			)
		case .Not_Ntfs:
			fmt.eprintln("error: not an NTFS volume")
		case .Open_Failed:
			fmt.eprintfln("error: could not open %s", f.target.volume)
		case:
			fmt.eprintfln("error: %v", f.mft_err)
		}
		return true
	}
	if f.walk_err != nil {
		fmt.eprintfln(
			"error: walking %s: %v",
			scan.location(f.target, context.temp_allocator),
			f.walk_err,
		)
		return true
	}
	if f.tree_err != nil {
		fmt.eprintfln("error: %v", f.tree_err)
		return true
	}
	return false
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
@(private = "file")
fill_mft :: proc(f: ^Fill) {
	p: ntfs.Projection
	p.root_name = scan.top(f.target)
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

@(private = "file")
fill_mft_read :: proc(f: ^Fill) {
	f.mft_err = ntfs.read_mft(f.target.volume, &f.table, f.opts)
	sync.atomic_store(&f.reading, false)
}

// Walk directories straight into the tree. Nothing is restated: a walk reaches a child
// through its parent, so a node is final when it is written, watched or not.
@(private = "file")
fill_walk :: proc(f: ^Fill) {
	root := scan.location(f.target, context.allocator)
	defer delete(root)
	f.walk_err = walk.scan(root, f.tree, f.wcfg)
}
