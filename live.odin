package main

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

import "human"
import "scan"
import "survey"

/*
Stand in for a UI.

Three jobs, as the scan is meant to run: a reader filling the tree, a builder owning
everything derived from it, and this loop drawing. The point of the arrangement is
that a frame costs the same whatever the volume holds, because it reads a published
snapshot of twenty rows rather than the tree.

Which reader fills it is not decided here, and nothing here knows which one did. A
reader settles nodes, and restates if it has to correct itself; that is the whole of
the conversation.

Nothing here waits on the builder. If a build pass is mid-write the loop draws the
answer from the last one.
*/
FRAME :: 16 * time.Millisecond

run_live :: proc(f: ^survey.Fill) -> int {
	out: Publisher
	started := time.tick_now()

	f.watched = true
	sync.atomic_store(&f.scanning, true)

	b := Builder {
		tree     = f.tree,
		out      = &out,
		scanning = &f.scanning,
		started  = started,
	}

	filler := thread.create_and_start_with_poly_data(f, fill_thread)
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
	defer survey.rollup_destroy(&b.roll)

	frames, drawn, missed := 0, 0, 0
	last: Snapshot
	have := false

	for {
		frame_start := time.tick_now()
		finished := bool(sync.atomic_load(&b.done))

		if s, ok := current(&out); ok {
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
				human.bytes(last.rows[0].bytes),
				scan.path(f.tree, last.rows[0].node, context.temp_allocator),
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

	if fill_report(f) {
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

	print_largest(f.tree, b.roll.totals[:], .files)
	print_largest(f.tree, b.roll.totals[:], .directories)

	return 0
}

@(private)
fill_thread :: proc(f: ^survey.Fill) {
	survey.fill_run(f)
}

@(private)
build_thread :: proc(b: ^Builder) {
	builder_run(b)
}
