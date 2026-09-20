package main

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

import "ntfs"
import "scan"

/*
Stand in for a UI.

Three threads, as the scan is meant to run: readers filling the table, a builder
owning the tree and everything derived from it, and this loop drawing. The point of
the arrangement is that a frame costs the same whatever the volume holds, because it
reads a published snapshot of twenty rows rather than the tree.

Nothing here waits on the builder. If a build pass is mid-write the loop draws the
answer from the last one.
*/
FRAME :: 16 * time.Millisecond

@(private = "file")
Reader :: struct {
	volume:   string,
	opts:     ntfs.Read_Options,
	table:    ^ntfs.Mft,
	err:      ntfs.Error,
	scanning: b32,
}

run_live :: proc(volume: string, mount: string, opts: ntfs.Read_Options) -> int {
	m: ntfs.Mft
	defer ntfs.mft_destroy(&m)

	t: scan.Tree
	if err := scan.tree_init(&t, 1); err != nil {
		fmt.eprintfln("error: %v", err)
		return 1
	}
	defer scan.tree_destroy(&t)

	out: scan.Publisher
	started := time.tick_now()

	r := Reader {
		volume   = volume,
		opts     = opts,
		table    = &m,
		scanning = true,
	}
	b := Builder {
		table    = &m,
		tree     = &t,
		out      = &out,
		mount    = mount,
		scanning = &r.scanning,
		started  = started,
	}

	reader := thread.create_and_start_with_poly_data(&r, read_thread)
	if reader == nil {
		fmt.eprintln("error: could not start the reader")
		return 1
	}
	defer thread.destroy(reader)

	builder := thread.create_and_start_with_poly_data(&b, build_thread)
	if builder == nil {
		fmt.eprintln("error: could not start the builder")
		return 1
	}
	defer thread.destroy(builder)
	defer ntfs.projection_destroy(&b.projection)
	defer rollup_destroy(&b.roll)

	frames, drawn, missed := 0, 0, 0
	last: scan.Snapshot
	have := false

	for {
		frame_start := time.tick_now()
		finished := bool(sync.atomic_load(&b.done))

		// The whole frame. Everything below is twenty rows and their paths.
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
	thread.join(reader)
	thread.join(builder)

	if r.err != nil {
		fmt.eprintfln("error: %v", r.err)
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

@(private = "file")
read_thread :: proc(r: ^Reader) {
	r.err = ntfs.read_mft(r.volume, r.table, r.opts)
	sync.atomic_store(&r.scanning, false)
}

@(private = "file")
build_thread :: proc(b: ^Builder) {
	builder_run(b)
}
