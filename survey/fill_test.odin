package survey

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "../scan"

// A made-up day turns any target into a made-up disk, read by the synthetic
// reader through the same fill as a real one. Called off part way, the fill
// stops and says why, as a walk does.
@(test)
a_made_up_day_makes_the_disk_up :: proc(t: ^testing.T) {
	target, choice, err := scan.resolve("/", made_up = 3)
	testing.expect_value(t, err, scan.Error.None)
	testing.expect_value(t, choice.engine, scan.Engine.Synthetic)
	defer scan.target_destroy(&target)

	tree: scan.Tree
	testing.expect(t, scan.tree_init(&tree) == nil)
	defer scan.tree_destroy(&tree)
	f := Fill {
		target   = target,
		engine   = choice.engine,
		tree     = &tree,
		scanning = true,
	}
	defer fill_destroy(&f)
	reader := thread.create_and_start_with_poly_data(&f, fill_run)
	deadline := time.tick_now()
	for sync.atomic_load(&tree.nodes_done) < 1000 && time.tick_since(deadline) < 10 * time.Second {
		time.sleep(time.Millisecond)
	}
	scan.cancel(&tree)
	thread.join(reader)
	thread.destroy(reader)

	testing.expect_value(t, scan.name_of(&tree, tree.root), "/")
	testing.expect(t, sync.atomic_load(&tree.nodes_done) >= 1000, "it made entries up")
	testing.expect_value(t, problem(&f, context.temp_allocator), "making the disk up: Cancelled")
}

/*
A made-up scan and a real one run side by side, over the same place, and do not
mix: the made-up day is the made-up scan's alone, so a real target resolved while
the made-up disk is filling is real, and each tree holds only its own reader's
names. When the day was the process's environment, a test that set it turned a
concurrent test's real scan into the made-up disk (card 81).
*/
@(test)
a_made_up_scan_and_a_real_one_do_not_mix :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := strings.join(
		{strings.trim_right(dir, `\/`), fmt.tprintf("leita_survey_beside_%d", os.get_pid())},
		scan.SEPARATOR,
		context.temp_allocator,
	)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	defer os.remove_all(root)

	real_file := strings.join({root, "real.txt"}, scan.SEPARATOR, context.temp_allocator)
	put(t, real_file, 4000)

	made, made_choice, made_err := scan.resolve(root, made_up = 3)
	testing.expect_value(t, made_err, scan.Error.None)
	testing.expect_value(t, made_choice.engine, scan.Engine.Synthetic)
	defer scan.target_destroy(&made)

	made_tree: scan.Tree
	testing.expect(t, scan.tree_init(&made_tree) == nil)
	defer scan.tree_destroy(&made_tree)

	made_fill := Fill {
		target   = made,
		engine   = made_choice.engine,
		tree     = &made_tree,
		scanning = true,
	}
	defer fill_destroy(&made_fill)

	reader := thread.create_and_start_with_poly_data(&made_fill, fill_run)
	deadline := time.tick_now()
	for sync.atomic_load(&made_tree.nodes_done) < 100 && time.tick_since(deadline) < 10 * time.Second {
		time.sleep(time.Millisecond)
	}

	// Real scans of the place, each resolved and read while the made-up disk fills.
	// Each is walked: on CI's elevated Windows runner the place resolved to the MFT,
	// and five whole-volume reads outlasted the made-up disk (run 40112254322).
	for _ in 0 ..< 5 {
		real, real_choice, real_err := scan.resolve(root)
		testing.expect_value(t, real_err, scan.Error.None)
		testing.expect(t, real_choice.engine != .Synthetic, "the real place resolved to the made-up disk")
		place := scan.location(real, context.temp_allocator)
		tree: scan.Tree
		testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
		f := Fill {
			target = real,
			engine = .Walk,
			wcfg   = {workers = 2},
			tree   = &tree,
		}
		fill_run(&f)
		testing.expectf(t, problem(&f) == "", "the real fill failed: %s", problem(&f))
		want := read_tree(t, place)
		expect_same(t, &tree, &want)
		scan.tree_destroy(&want)
		fill_destroy(&f)
		scan.tree_destroy(&tree)
		scan.target_destroy(&real)
	}
	testing.expect(t, bool(sync.atomic_load(&made_fill.scanning)), "the made-up disk was done before the real scans were")

	scan.cancel(&made_tree)
	thread.join(reader)
	thread.destroy(reader)
	got := seen(&made_tree)
	testing.expect(t, real_file not_in got, "the made-up disk holds the real file")
	users := strings.join({root, "Users"}, scan.SEPARATOR, context.temp_allocator)
	testing.expectf(t, users in got, "the made-up disk has no %s", users)
}
