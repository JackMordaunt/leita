package survey

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../scan"

// A folder of three files in two directories under the temp directory.
@(private = "file")
small :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := strings.join(
		{strings.trim_right(dir, `\/`), fmt.tprintf("leita_probe_%s_%d", name, os.get_pid())},
		scan.SEPARATOR,
		context.temp_allocator,
	)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	sub := strings.join({root, "sub"}, scan.SEPARATOR, context.temp_allocator)
	testing.expect(t, os.make_directory(sub) == nil, "could not make sub")
	put(t, strings.join({root, "a.txt"}, scan.SEPARATOR, context.temp_allocator), 100)
	put(t, strings.join({sub, "b.txt"}, scan.SEPARATOR, context.temp_allocator), 5000)
	put(t, strings.join({sub, "c.txt"}, scan.SEPARATOR, context.temp_allocator), 3000)
	return root
}

/*
target as resolve gives it for an NTFS folder with a record on a volume that opens
raw, which is what makes the choice wait on the folder's size. Its volume names
nothing, so a read that does go to the MFT fails at once rather than reading the
volume this test runs on.
*/
@(private = "file")
sized :: proc(target: scan.Target) -> scan.Target {
	s := target
	s.fs = .Ntfs
	s.volume = ""
	if s.record == nil {
		s.record = 5
	}
	return s
}

// The entries a tree holds, as a baseline keeps them.
@(private = "file")
used :: proc(tree: ^scan.Tree) -> (n: u64) {
	for i in 0 ..< scan.slots(tree) {
		if .Used in scan.node_flags(scan.node(tree, i)) {
			n += 1
		}
	}
	return
}

/*
A small folder whose size is not known is probed, the probe finishes inside its
budget, and the folder is walked: well under a second, where the MFT reader took 5
to 30 s for a folder of four files on the hosted Windows runner. On Windows from an
elevated prompt, resolve itself asks for the probe; elsewhere the target is made to.
*/
@(test)
test_a_small_folder_waiting_on_its_size_is_walked :: proc(t: ^testing.T) {
	root := small(t, "walked")
	defer os.remove_all(root)

	start := time.tick_now()
	target, choice, err := scan.resolve(root)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)

	if ODIN_OS == .Windows && target.fs == .Ntfs && !choice.permission_would_help {
		testing.expect_value(t, choice, scan.Choice{engine = .Walk, probe = true})
	}
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
	defer scan.tree_destroy(&tree)

	f := Fill {
		target = sized(target),
		engine = .Walk,
		probe  = true,
		wcfg   = {workers = 2},
		tree   = &tree,
	}
	defer fill_destroy(&f)

	fill_run(&f)
	took := time.tick_since(start)

	testing.expectf(t, problem(&f) == "", "the fill failed: %s", problem(&f))
	testing.expect_value(t, f.engine, scan.Engine.Walk)
	testing.expect(t, !f.escalated, "a small folder escalated to the MFT")
	testing.expect_value(t, used(&tree), 5)
	testing.expectf(t, took < time.Second, "the folder took %v", took)
	fmt.printfln("probed and walked %s in %.1f ms", root, time.duration_milliseconds(took))
}

/*
The entries a baseline kept are read from its head, and a place kept with more
than a walk is expected to beat reads from the MFT without a probe, when it is read
whole. The count is written into the head of a real baseline, which leaves the
rest of the file too short for it, so the update is refused and the place is read
whole with the count as its prior.
*/
@(test)
test_a_place_kept_large_goes_to_the_mft :: proc(t: ^testing.T) {
	root := small(t, "large")
	defer os.remove_all(root)

	file := fmt.tprintf("%s.tree", root)
	defer os.remove(file)

	target, _, err := scan.resolve(root)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)

	place := scan.location(target, context.temp_allocator)

	tree := read_tree(t, place)
	defer scan.tree_destroy(&tree)

	testing.expect(t, baseline_save(file, place, &tree, {}), "the baseline was not kept")
	testing.expect_value(t, baseline_entries(file, place), Maybe(u64)(used(&tree)))
	testing.expect_value(t, baseline_entries(file, "elsewhere"), nil)
	testing.expect_value(t, baseline_entries("", place), nil)

	data, read_err := os.read_entire_file(file, context.temp_allocator)
	testing.expect(t, read_err == nil, "could not read the baseline back")
	at := len(BASELINE_MAGIC) + CURSOR_SIZE + 4 + len(place)
	endian.put_u32(data[at:], .Little, scan.WALK_MOST + 1)
	testing.expect(t, os.write_entire_file(file, data) == nil, "could not rewrite the baseline")
	testing.expect_value(t, baseline_entries(file, place), Maybe(u64)(scan.WALK_MOST + 1))

	into: scan.Tree
	testing.expect_value(t, scan.tree_init(&into, 2), scan.Error.None)
	defer scan.tree_destroy(&into)

	f := Fill {
		target   = sized(target),
		engine   = .Walk,
		probe    = true,
		wcfg     = {workers = 2},
		tree     = &into,
		baseline = file,
	}
	defer fill_destroy(&f)

	fill_run(&f)
	testing.expect_value(t, f.how, Fill_Kind.Full)
	testing.expect_value(t, f.engine, scan.Engine.Mft)
	testing.expect(t, bool(f.escalated), "the window is not told the MFT is reading")
	// The volume names nothing, so the MFT reader is what failed.
	testing.expect(t, f.mft_err != nil, "something other than the MFT reader read it")
}

/*
An update from a baseline walks what changed whichever reader was chosen to read the
place whole: the MFT reader is never opened. The fill is told the MFT, as resolve
tells an elevated scan of a whole NTFS volume, and its volume names nothing, so had
it gone there it would have failed.
*/
@(test)
test_an_update_walks_whatever_reader_was_chosen :: proc(t: ^testing.T) {
	root := small(t, "update")
	defer os.remove_all(root)

	if fixture_fill_kind(root) == .Full {
		return // this filesystem's files are always read whole
	}
	file := fmt.tprintf("%s.tree", root)
	defer os.remove(file)

	target, choice, err := scan.resolve(root)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)

	runs: [2]time.Duration
	for engine, i in ([]scan.Engine{choice.engine, .Mft}) {
		tree: scan.Tree
		testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
		defer scan.tree_destroy(&tree)

		f := Fill {
			target   = target if i == 0 else sized(target),
			engine   = engine,
			wcfg     = {workers = 2},
			tree     = &tree,
			baseline = file,
		}
		defer fill_destroy(&f)

		start := time.tick_now()
		fill_run(&f)
		runs[i] = time.tick_since(start)
		testing.expectf(t, problem(&f) == "", "run %d failed: %s", i, problem(&f))
		testing.expectf(t, f.saved, "run %d was not kept", i)
		if i == 1 {
			testing.expect_value(t, f.how, Fill_Kind.Updated)
			testing.expect(t, f.mft_err == nil && len(f.table.entries) == 0, "the update read the MFT")
			testing.expect_value(t, used(&tree), 5)
		}
	}
	fmt.printfln(
		"kept %s whole in %.1f ms, updated it in %.1f ms",
		root,
		time.duration_milliseconds(runs[0]),
		time.duration_milliseconds(runs[1]),
	)
}
