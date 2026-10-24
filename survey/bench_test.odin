package survey

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

import "../scan"
import "../walk"

/*
What an update saves over reading a place whole, measure, when LEITA_BENCH asks: a
directory to read (one this writes a directory of its own into, and removes), or a
number of directories to make up under the temp directory, ten files each. Off
otherwise, so `just test` stays quick.

Three runs a pace, each warm from the one before: a whole read to keep the
baseline, a whole read without one, which is what a scheduled scan costs today, and
an update after one file is added. Gentle first, the pace the monitoring design
(card 41) gives a scheduled scan by default.
*/
@(test)
bench_an_update_against_a_whole_read :: proc(t: ^testing.T) {
	asked := os.get_env("LEITA_BENCH", context.temp_allocator)
	if asked == "" {
		return
	}
	place := asked
	made := false
	if dirs, is_count := strconv.parse_int(asked); is_count {
		place = place_make(t, dirs)
		made = true
	}
	defer if made {
		os.remove_all(place)
	}
	tmp, _ := os.temp_directory(context.temp_allocator)
	file := fmt.tprintf("%s%sleita-bench.tree", strings.trim_right(tmp, `\/`), scan.SEPARATOR)
	defer os.remove(file)
	target, choice, err := scan.resolve(place)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)

	// The heap, not the test runner's tracking allocator (mem.Tracking_Allocator,
	// which guards its map with a mutex), so the allocator is not what is measure.
	context.allocator = runtime.heap_allocator()
	for pace in ([]walk.Pace{.Gentle, .Full}) {
		os.remove(file)
		keep, _, nodes := measure(t, target, choice.engine, file, pace)
		whole, _, _ := measure(t, target, choice.engine, "", pace)
		changed := fmt.tprintf(
			"%s%sleita-bench-change",
			strings.trim_right(place, `\/`),
			scan.SEPARATOR,
		)
		testing.expect(t, os.make_directory(changed) == nil, "could not make a change")
		put(t, fmt.tprintf("%s%snew.txt", changed, scan.SEPARATOR), 4096)
		update, how, _ := measure(t, target, choice.engine, file, pace)
		os.remove_all(changed)
		testing.expect_value(t, how, Fill_Kind.Updated)
		fmt.printfln(
			"bench %s, %v pace, %d nodes: whole read keeping a baseline %.0f ms, whole read %.0f ms, update %.0f ms (%.1fx)",
			place,
			pace,
			nodes,
			time.duration_milliseconds(keep),
			time.duration_milliseconds(whole),
			time.duration_milliseconds(update),
			time.duration_seconds(whole) / max(time.duration_seconds(update), 1e-9),
		)
	}
}

/*
What the MFT reader saves over a walk on one folder of an NTFS volume, measured when
LEITA_BENCH_MFT names the folder (`just mft-bench <folder>`). The MFT engine opens
the volume raw, which resolve finds refused without an elevated prompt (survey's
problem says so for Access_Denied), so anything else fails here rather than timing
two walks. Each engine reads the folder twice and the
second, warm, read is timed. Both trees are counted by slot, as a search reads them,
so counts far apart mean the MFT's tree is not the folder's alone.
*/
@(test)
bench_a_folder_from_the_mft_against_a_walk :: proc(t: ^testing.T) {
	place := os.get_env("LEITA_BENCH_MFT", context.temp_allocator)
	if place == "" {
		return
	}
	target, choice, err := scan.resolve(place)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)
	if choice.engine != .Mft {
		testing.expectf(
			t,
			false,
			"%s is read by %v, not the MFT: it takes an NTFS folder and an elevated prompt",
			place,
			choice.engine,
		)
		return
	}

	// The heap, as above, so the allocator is not what is measured.
	context.allocator = runtime.heap_allocator()
	mft := read_twice(t, target, .Mft)
	walked := read_twice(t, target, .Walk)
	fmt.printfln(
		"bench %s: MFT %.0f ms, %d nodes, %d bytes; walk %.0f ms, %d nodes, %d bytes (%.1fx)",
		place,
		time.duration_milliseconds(mft.took),
		mft.nodes,
		mft.bytes,
		time.duration_milliseconds(walked.took),
		walked.nodes,
		walked.bytes,
		time.duration_seconds(walked.took) / max(time.duration_seconds(mft.took), 1e-9),
	)
}

@(private = "file")
Read :: struct {
	first: time.Duration, // the first read, which may find the cache cold
	took:  time.Duration,
	nodes: u64, // used nodes, not counting a file's extra names
	bytes: u64,
}

// Read the target whole with one engine, twice, and time and count the second.
@(private = "file")
read_twice :: proc(t: ^testing.T, target: scan.Target, engine: scan.Engine) -> (r: Read) {
	for pass in 0 ..< 2 {
		tree: scan.Tree
		testing.expect_value(t, scan.tree_init(&tree, 32), scan.Error.None)
		defer scan.tree_destroy(&tree)
		f := Fill {
			target = target,
			engine = engine,
			wcfg = {media = target.media, pace = .Full},
			tree = &tree,
		}
		defer fill_destroy(&f)
		start := time.tick_now()
		fill_run(&f)
		took := time.tick_since(start)
		r = {first = r.first if pass > 0 else took, took = took}
		testing.expectf(t, problem(&f) == "", "%s", problem(&f))
		for i in 0 ..< scan.slots(&tree) {
			n := scan.node(&tree, i)
			flags := scan.node_flags(n)
			if .Used in flags && .Extra_Name not_in flags {
				r.nodes += 1
				r.bytes += n.disk
			}
		}
	}
	return
}

/*
Where a walk stops beating the MFT reader on an elevated NTFS volume, measured when
LEITA_BENCH_CROSSOVER lists entry counts, such as 10,1000,100000 (`just
crossover-bench`). Each count is a folder made up under the temp directory, a hundred
files to a directory, read by both engines twice. The whole volume the temp directory
is on is read by the MFT once more at the end, as the cost a folder's MFT read pays
whatever its size. Card 705 picks the walk probe's budget from these numbers.
*/
@(test)
bench_where_a_walk_overtakes_the_mft :: proc(t: ^testing.T) {
	asked := os.get_env("LEITA_BENCH_CROSSOVER", context.temp_allocator)
	if asked == "" {
		return
	}
	context.allocator = runtime.heap_allocator()
	tmp, _ := os.temp_directory(context.temp_allocator)
	top := strings.trim_right(tmp, `\/`)
	for count in strings.split(asked, ",", context.temp_allocator) {
		entries, ok := strconv.parse_int(count)
		if !testing.expectf(t, ok && entries > 0, "%q is not a count of entries", count) {
			return
		}
		place := fmt.aprintf("%s%sleita-crossover-%d", top, scan.SEPARATOR, entries)
		defer delete(place)

		os.remove_all(place)
		made := time.tick_now()
		crossover_make(t, place, entries)
		making := time.tick_since(made)
		defer os.remove_all(place)

		target, choice, err := scan.resolve(place)
		testing.expect_value(t, err, scan.Error.None)
		defer scan.target_destroy(&target)

		if target.fs != .Ntfs || target.record == nil {
			testing.expectf(t, false, "%s is no NTFS folder with a record (%v)", place, choice)
			return
		}
		mft := read_twice(t, target, .Mft)
		walked := read_twice(t, target, .Walk)
		testing.expectf(
			t,
			mft.nodes == walked.nodes,
			"the MFT found %d nodes and the walk %d",
			mft.nodes,
			walked.nodes,
		)
		fmt.printfln(
			"crossover %d entries (made in %.0f ms): MFT %.0f ms then %.0f ms, %d nodes; walk %.0f ms then %.0f ms, %d nodes",
			entries,
			time.duration_milliseconds(making),
			time.duration_milliseconds(mft.first),
			time.duration_milliseconds(mft.took),
			mft.nodes,
			time.duration_milliseconds(walked.first),
			time.duration_milliseconds(walked.took),
			walked.nodes,
		)
	}
	volume, _, err := scan.resolve(top[:2])
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&volume)

	whole := read_twice(t, volume, .Mft)
	fmt.printfln(
		"crossover whole volume %s: MFT %.0f ms then %.0f ms, %d nodes",
		top[:2],
		time.duration_milliseconds(whole.first),
		time.duration_milliseconds(whole.took),
		whole.nodes,
	)
}

// `entries` entries under root: a directory for each hundred, holding small files.
@(private = "file")
crossover_make :: proc(t: ^testing.T, root: string, entries: int) {
	testing.expect(t, os.make_directory(root) == nil, "could not make the place")

	body := []byte{'x'}
	dir: string
	for i in 0 ..< entries {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if i % 100 == 0 {
			delete(dir)
			dir = fmt.aprintf("%s%sd%d", root, scan.SEPARATOR, i / 100)
			testing.expect(t, os.make_directory(dir) == nil, "could not make a directory")
			continue
		}
		name := fmt.tprintf("%s%sf%d", dir, scan.SEPARATOR, i)
		if os.write_entire_file(name, body) != nil {
			testing.expectf(t, false, "could not write %s", name)
			break
		}
	}
	delete(dir)
}

@(private = "file")
measure :: proc(
	t: ^testing.T,
	target: scan.Target,
	engine: scan.Engine,
	file: string,
	pace: walk.Pace,
) -> (
	time.Duration,
	Fill_Kind,
	u64,
) {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 32), scan.Error.None)
	defer scan.tree_destroy(&tree)
	f := Fill {
		target = target,
		engine = engine,
		wcfg = {media = target.media, pace = pace},
		tree = &tree,
		baseline = file,
	}
	defer fill_destroy(&f)
	start := time.tick_now()
	fill_run(&f)
	took := time.tick_since(start)
	testing.expectf(t, problem(&f) == "", "%s", problem(&f))
	return took, f.how, u64(scan.slots(&tree))
}

// A place of `dirs` directories in a hundred groups, ten small files each, made
// up under the temp directory, then left 3 s, past changes.SLACK's 2 s on Linux,
// so a probe started after it reads none of it again.
@(private = "file")
place_make :: proc(t: ^testing.T, dirs: int) -> string {
	tmp, _ := os.temp_directory(context.temp_allocator)
	root := fmt.tprintf("%s%sleita-bench", strings.trim_right(tmp, `\/`), scan.SEPARATOR)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the place")
	for d in 0 ..< dirs {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		group := fmt.tprintf("%s%sg%02d", root, scan.SEPARATOR, d % 100)
		if d < 100 {
			testing.expect(t, os.make_directory(group) == nil, "could not make a group")
		}
		dir := fmt.tprintf("%s%sd%d", group, scan.SEPARATOR, d)
		testing.expect(t, os.make_directory(dir) == nil, "could not make a directory")
		for f in 0 ..< 10 {
			put(t, fmt.tprintf("%s%sf%d", dir, scan.SEPARATOR, f), 100 + f * 1000)
		}
	}
	time.sleep(3 * time.Second)
	return root
}
