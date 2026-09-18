package main

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

import "ntfs"
import "scan"

/*
Stand in for a UI.

A real one repaints on a timer and must never block on the scan, so this runs the
reader on its own thread and polls from here at the frame interval. What it prints
each frame is what a UI could draw at that moment: the answer as it stood, not the
answer it will eventually be.

The point is to find out what the seam has to provide. Everything the loop touches
has to be safe to read while a reader is writing it, and cheap enough to do sixty
times a second.
*/
FRAME :: 16 * time.Millisecond

Live :: struct {
	volume: string,
	opts:   ntfs.Read_Options,
	table:  ^ntfs.Mft,
	err:    ntfs.Error,
	done:   b32,
}

run_live :: proc(volume: string, mount: string, opts: ntfs.Read_Options) -> int {
	m: ntfs.Mft
	defer ntfs.mft_destroy(&m)

	l := Live {
		volume = volume,
		opts   = opts,
		table  = &m,
	}
	worker := thread.create_and_start_with_poly_data(&l, scan_thread)
	if worker == nil {
		fmt.eprintln("error: could not start the scan")
		return 1
	}
	defer thread.destroy(worker)

	t: scan.Tree
	if err := scan.tree_init(&t, 1); err != nil {
		fmt.eprintfln("error: %v", err)
		return 1
	}
	defer scan.tree_destroy(&t)

	projection: ntfs.Projection
	totals: [dynamic]u64
	defer delete(totals)

	start := time.tick_now()
	frames := 0
	settled := 0 // consecutive frames whose top twenty has not moved
	previous: [TOP_N]Sized

	for {
		finished := bool(sync.atomic_load(&l.done))
		frame_start := time.tick_now()

		if ntfs.mft_ready(&m) {
			// Both of these have to be cheap, because they run every frame.
			if err := ntfs.to_tree(&m, &t, &projection); err != nil {
				fmt.eprintfln("error: %v", err)
				return 1
			}
			resize(&totals, int(t.count))
			for i in 0 ..< len(totals) {
				totals[i] = 0
			}
			roll_up(&t, totals[:])

			top: [TOP_N]Sized
			count := rank(&t, totals[:], top[:])
			if count > 0 {
				scan.node(&t, t.root).name = mount
			}

			if same_ranking(top, previous) {
				settled += 1
			} else {
				settled = 0
			}
			previous = top

			fmt.printfln(
				"frame %3d  %6.0f ms  %8d nodes  %10s  top1 %s  frame cost %.1f ms  settled %d",
				frames,
				time.duration_milliseconds(time.tick_since(start)),
				t.nodes_done,
				human(count > 0 ? top[0].bytes : 0),
				count > 0 ? scan.path(&t, top[0].record, context.temp_allocator) : "-",
				time.duration_milliseconds(time.tick_since(frame_start)),
				settled,
			)
			free_all(context.temp_allocator)
		}
		frames += 1

		if finished {
			break
		}
		// Sleep the rest of the frame, or not at all if the work overran it.
		if spent := time.tick_since(frame_start); spent < FRAME {
			time.sleep(FRAME - spent)
		}
	}
	thread.join(worker)

	if l.err != nil {
		fmt.eprintfln("error: %v", l.err)
		return 1
	}
	fmt.println()
	fmt.printfln("scan finished in %.0f ms over %d frames", time.duration_milliseconds(time.tick_since(start)), frames)
	print_largest(&t, totals[:], .files)
	print_largest(&t, totals[:], .directories)
	return 0
}

@(private = "file")
scan_thread :: proc(l: ^Live) {
	l.err = ntfs.read_mft(l.volume, l.table, l.opts)
	sync.atomic_store(&l.done, true)
}

@(private = "file")
same_ranking :: proc(a, b: [TOP_N]Sized) -> bool {
	for i in 0 ..< TOP_N {
		if a[i].record != b[i].record {
			return false
		}
	}
	return true
}
