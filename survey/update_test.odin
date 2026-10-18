package survey

import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

import "../changes"
import "../journal"
import "../scan"
import "../walk"

/*
A place on disk to keep and update, its paths spelt as the platform spells them.

	<root>/a.txt           100 bytes
	<root>/sub/b.txt       5000 bytes
	<root>/still/k.txt     3000 bytes
*/
@(private = "file")
fixture :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := join(strings.trim_right(dir, `\/`), fmt.tprintf("leita_survey_%s", name))
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory(join(root, "sub")) == nil, "could not make sub")
	testing.expect(t, os.make_directory(join(root, "still")) == nil, "could not make still")
	put(t, join(root, "a.txt"), 100)
	put(t, join(root, "sub", "b.txt"), 5000)
	put(t, join(root, "still", "k.txt"), 3000)
	return root
}

@(private = "file")
join :: proc(parts: ..string) -> string {
	return strings.join(parts, scan.SEPARATOR, context.temp_allocator)
}

// Write a file of `size` bytes, for this package's tests.
@(private)
put :: proc(t: ^testing.T, path: string, size: int) {
	body := make([]byte, size, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
}

@(private)
read_tree :: proc(t: ^testing.T, root: string) -> scan.Tree {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
	testing.expect_value(t, walk.read(root, &tree, walk.Config{workers = 2}), walk.Error.None)
	return tree
}

// Each used node's path, what it holds on disk, and its flags.
@(private)
Record :: struct {
	disk:  u64,
	flags: scan.Node_Flags,
}

@(private)
seen :: proc(tree: ^scan.Tree) -> map[string]Record {
	out := make(map[string]Record, context.temp_allocator)
	for i in 0 ..< scan.slots(tree) {
		n := scan.node(tree, i)
		f := scan.node_flags(n)
		if .Used in f {
			out[scan.path(tree, i, context.temp_allocator)] = {n.disk, f}
		}
	}
	return out
}

@(private)
expect_same :: proc(t: ^testing.T, got, want: ^scan.Tree) {
	g, w := seen(got), seen(want)
	testing.expectf(t, len(g) == len(w), "%d nodes, want %d", len(g), len(w))
	for path, s in w {
		have, found := g[path]
		testing.expectf(t, found && have == s, "%s: %v, want %v", path, have, s)
	}
}

// The file each name a tree charged for a file with more than one names, by path.
@(private = "file")
linked_paths :: proc(tree: ^scan.Tree) -> map[string]scan.File_Id {
	out := make(map[string]scan.File_Id, context.temp_allocator)
	for l in tree.linked {
		out[scan.path(tree, l.node, context.temp_allocator)] = l.id
	}
	return out
}

// A baseline reads back as the tree that was kept, with its cursor, its flags,
// Shared among them, and the name a file of two names was charged under, which an
// update needs to charge it once beside a name it copies (walk.update).
@(test)
test_a_baseline_reads_back_what_was_kept :: proc(t: ^testing.T) {
	root := fixture(t, "keep")
	defer os.remove_all(root)
	file := join(root, "..", "leita_survey_keep.tree")
	defer os.remove(file)
	testing.expect(
		t,
		os.link(join(root, "sub", "b.txt"), join(root, "still", "b2.txt")) == nil,
		"could not link",
	)
	tree := read_tree(t, root)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, len(tree.linked), 1)
	// What a btrfs walk as root marks a reflinked copy: expect_same then sees the
	// flag come back.
	ix, _ := scan.index_make(&tree, context.temp_allocator)
	scan.node_mark(scan.node(&tree, scan.child_named(&tree, ix, tree.root, "a.txt")), {.Shared})

	cursor := changes.Cursor {
		source   = .Probe,
		volume   = {7, 9},
		journal  = 11,
		position = 13,
		full     = 17,
		updates  = 19,
	}
	testing.expect(t, baseline_save(file, root, &tree, cursor), "the baseline was not kept")
	back: scan.Tree
	got, why, ok := baseline_load(file, root, &back)
	defer scan.tree_destroy(&back)
	testing.expectf(t, ok, "not read back: %s", why)
	testing.expect_value(t, got, cursor)
	expect_same(t, &back, &tree)
	kept, want := linked_paths(&back), linked_paths(&tree)
	testing.expect_value(t, len(kept), len(want))
	for path, id in want {
		testing.expectf(t, kept[path] == id, "%s names %v, the tree %v", path, kept[path], id)
	}

	other: scan.Tree
	_, why, ok = baseline_load(file, join(root, "sub"), &other)
	testing.expect(t, !ok && why != "", "a baseline of another place was read")

	// Cut short, it is refused rather than read in part.
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, data[:len(data) - 3]) == nil)
	short: scan.Tree
	_, why, ok = baseline_load(file, root, &short)
	testing.expect(t, !ok && why != "", "a short baseline was read")

	// Counting fewer nodes than it holds, it is refused rather than read as a
	// smaller tree. The count follows the magic, the cursor and the place.
	fewer := slice.clone(data, context.temp_allocator)
	at := len(BASELINE_MAGIC) + CURSOR_SIZE + 4 + len(root)
	count, _ := endian.get_u32(fewer[at:], .Little)
	endian.put_u32(fewer[at:], .Little, count - 1)
	testing.expect(t, os.write_entire_file(file, fewer) == nil)
	smaller: scan.Tree
	_, why, ok = baseline_load(file, root, &smaller)
	testing.expect(t, !ok && why != "", "a baseline counting fewer nodes was read")
}

@(private = "file")
Saver :: struct {
	file, place: string,
	tree:        ^scan.Tree,
	kept:        int,
}

/*
Two writers saving the same place at once, as the monitor and the window finishing
a scan together do, each write a temporary file of their own: what is left is a whole
baseline, and no temporary file.
*/
@(test)
test_baselines_saved_at_once_leave_a_whole_one :: proc(t: ^testing.T) {
	root := fixture(t, "race")
	defer os.remove_all(root)
	dir := join(root, "..", "leita_survey_race_kept")
	os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil, "could not make the folder")
	defer os.remove_all(dir)
	file := join(dir, "place.tree")
	tree := read_tree(t, root)
	defer scan.tree_destroy(&tree)

	save := proc(s: ^Saver) {
		for _ in 0 ..< 50 {
			if baseline_save(s.file, s.place, s.tree, {}) {
				s.kept += 1
			}
		}
	}
	savers := [2]Saver{{file, root, &tree, 0}, {file, root, &tree, 0}}
	threads: [2]^thread.Thread
	for &s, i in savers {
		threads[i] = thread.create_and_start_with_poly_data(&s, save)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, savers[0].kept + savers[1].kept, 100)
	back: scan.Tree
	_, why, ok := baseline_load(file, root, &back)
	defer scan.tree_destroy(&back)
	testing.expectf(t, ok, "not read back: %s", why)
	expect_same(t, &back, &tree)
	left, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expectf(t, len(left) == 1, "files left beside the baseline: %d", len(left))
}

/*
Applying a change set, standing in for a journal, reads again the directories it
names, and copies the rest: a change where nothing was named is not seen. A path the
base does not have, a directory made since, is found from its parent.
*/
@(test)
test_a_change_set_updates_what_it_names :: proc(t: ^testing.T) {
	root := fixture(t, "apply")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	put(t, join(root, "sub", "new.txt"), 7000)
	testing.expect(t, os.make_directory(join(root, "sub", "fresh")) == nil, "no fresh")
	put(t, join(root, "sub", "fresh", "f.txt"), 9000)
	put(t, join(root, "still", "unseen.txt"), 4000)

	set := changes.Change_Set {
		shallow = make([dynamic]string, context.temp_allocator),
		deep    = make([dynamic]string, context.temp_allocator),
	}
	append(&set.deep, join(root, "sub", "fresh")) // not in the base
	append(&set.shallow, join(fmt.tprintf("%s_beside", root), "x")) // not in the place
	append(&set.shallow, join(root, "sub", "gone")) // not in the base: sub is read

	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	f := Fill {
		tree = &got,
		wcfg = {workers = 2},
	}
	testing.expect_value(t, apply(&f, root, &base, set, 0), walk.Error.None)

	g := seen(&got)
	testing.expect(t, join(root, "sub", "new.txt") in g, "new.txt was not read")
	testing.expect(t, join(root, "sub", "fresh", "f.txt") in g, "fresh was not walked")
	testing.expect(t, join(root, "still", "unseen.txt") not_in g, "still was read again")
	testing.expect(t, join(root, "still", "k.txt") in g, "k.txt was not copied")
	testing.expect(t, join(root, "a.txt") in g, "a.txt was not copied")
}

/*
A change set from the recorder names directories by a hash of their path, spelt from
its root with slashes: the directory of the base whose path hashes to one named is
read again, and the rest are copied. A hash nothing in the base has names nothing.
*/
@(test)
test_a_change_set_by_hash_reads_the_named_directories :: proc(t: ^testing.T) {
	root := fixture(t, "hashed")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	put(t, join(root, "sub", "new.txt"), 7000)
	put(t, join(root, "still", "unseen.txt"), 4000)

	spelt := "/as/the/recorder/spells/it"
	set := changes.Change_Set {
		shallow = make([dynamic]string, context.temp_allocator),
		deep    = make([dynamic]string, context.temp_allocator),
		by_hash = true,
		root    = spelt,
		hashes  = make(map[u64]struct{}, context.temp_allocator),
	}
	set.hashes[journal.hash_path(fmt.tprintf("%s/sub", spelt))] = {}
	set.hashes[journal.hash_path(fmt.tprintf("%s/nothing/here", spelt))] = {}

	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	f := Fill {
		tree = &got,
		wcfg = {workers = 2},
	}
	testing.expect_value(t, apply(&f, root, &base, set, 0), walk.Error.None)
	g := seen(&got)
	testing.expect(t, join(root, "sub", "new.txt") in g, "sub was not read again")
	testing.expect(t, join(root, "still", "unseen.txt") not_in g, "still was read again")
	testing.expect(t, join(root, "still", "k.txt") in g, "k.txt was not copied")
	testing.expect_value(t, f.reread, 1)
}

// The root "/" hashes its children without a second slash.
@(test)
test_a_change_set_by_hash_from_the_root :: proc(t: ^testing.T) {
	root := fixture(t, "hashed_root")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)
	put(t, join(root, "sub", "new.txt"), 7000)
	put(t, join(root, "still", "unseen.txt"), 4000)

	set := changes.Change_Set {
		shallow = make([dynamic]string, context.temp_allocator),
		deep    = make([dynamic]string, context.temp_allocator),
		by_hash = true,
		root    = "/",
		hashes  = make(map[u64]struct{}, context.temp_allocator),
	}
	set.hashes[journal.hash_path("/sub")] = {}
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	f := Fill {
		tree = &got,
		wcfg = {workers = 2},
	}
	testing.expect_value(t, apply(&f, root, &base, set, 0), walk.Error.None)
	g := seen(&got)
	testing.expect(t, join(root, "sub", "new.txt") in g, "sub was not read again")
	testing.expect(t, join(root, "still", "unseen.txt") not_in g, "still was read again")
	testing.expect_value(t, f.reread, 1)
}

/*
A Fill with a baseline reads a place whole the first time and keeps it, then updates
it from what the system says changed. FSEvents gives a change its id only once
fseventsd has it, so one it has not had yet when a run takes its cursor is read by a
later run, never lost; on macOS the update is run until it sees the change, for up
to ten seconds.
*/
@(test)
test_a_fill_with_a_baseline_updates_the_place :: proc(t: ^testing.T) {
	root := fixture(t, "fill")
	defer os.remove_all(root)
	file := join(root, "..", "leita_survey_fill.tree")
	defer os.remove(file)
	target, choice, err := scan.resolve(root)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)
	place := scan.location(target, context.temp_allocator)

	run :: proc(
		t: ^testing.T,
		target: scan.Target,
		engine: scan.Engine,
		file: string,
	) -> (
		scan.Tree,
		Fill_Kind,
		string,
	) {
		tree: scan.Tree
		testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
		f := Fill {
			target = target,
			engine = engine,
			wcfg = {workers = 2},
			tree = &tree,
			baseline = file,
		}
		defer fill_destroy(&f)
		fill_run(&f)
		testing.expectf(t, problem(&f) == "", "the fill failed: %s", problem(&f))
		testing.expect(t, f.saved, "the result was not kept")
		return tree, f.how, f.why
	}

	first, how, why := run(t, target, choice.engine, file)
	scan.tree_destroy(&first)
	testing.expect_value(t, how, Fill_Kind.Full)
	testing.expect(t, why != "", "no reason the first scan was whole")

	put(t, join(place, "sub", "new.txt"), 7000)
	start := time.tick_now()
	for {
		tree, again, why_again := run(t, target, choice.engine, file)
		defer scan.tree_destroy(&tree)
		testing.expectf(t, again == .Updated, "read whole again: %s", why_again)
		found := join(place, "sub", "new.txt") in seen(&tree)
		if found || ODIN_OS != .Darwin || time.tick_since(start) > 10 * time.Second {
			testing.expect(t, found, "the update did not see new.txt")
			want := read_tree(t, place)
			defer scan.tree_destroy(&want)
			expect_same(t, &tree, &want)
			break
		}
		time.sleep(250 * time.Millisecond)
	}
}

// Asked to read whole, a Fill with a baseline reads the place whole all the same,
// says so, and keeps what it read; the next run updates from it and says how much
// it read again, and since when.
@(test)
test_a_fill_asked_whole_reads_whole_and_keeps :: proc(t: ^testing.T) {
	root := fixture(t, "whole")
	defer os.remove_all(root)
	file := join(root, "..", "leita_survey_whole.tree")
	defer os.remove(file)
	target, choice, err := scan.resolve(root)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)
	// A baseline is kept only on a volume that can say what changed since.
	_, has_events := changes.now(root)
	if !testing.expect(t, has_events, "no cursor: the volume keeps no change history") {
		return
	}

	runs := [3]Fill{}
	for &f, i in runs {
		tree: scan.Tree
		testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
		defer scan.tree_destroy(&tree)
		f = Fill {
			target = target,
			engine = choice.engine,
			wcfg = {workers = 2},
			tree = &tree,
			baseline = file,
			whole = i == 1,
		}
		defer fill_destroy(&f)
		fill_run(&f)
		testing.expectf(t, problem(&f) == "", "the fill failed: %s", problem(&f))
		testing.expectf(t, f.saved, "run %d was not kept", i)
	}
	testing.expect_value(t, runs[1].how, Fill_Kind.Full)
	testing.expect_value(t, runs[1].why, "asked to read it whole")
	testing.expectf(t, runs[2].how == .Updated, "read whole: %s", runs[2].why)
	testing.expect(t, runs[2].taken != {}, "no time the base was kept")
	words := how_read(true, "", runs[2].reread, runs[2].taken)
	testing.expectf(t, strings.has_prefix(words, "updated: "), "%q", words)
}

/*
A 200 KB file rewritten in place between two updates, in a directory no probe reads
again, is measured again within SLICES updates, by its slice's turn. Each update
counts itself in the cursor it keeps, which turns the slice. The fixture's folders
are left SLACK to age, so the probe's window does not reach back to their making.
*/
when ODIN_OS == .Linux {
	@(test)
	test_a_small_file_written_in_place_is_measured_in_its_turn :: proc(t: ^testing.T) {
		// This test exercises Linux's folder-time probe and small-file slices.
		root := fixture(t, "turn")
		defer os.remove_all(root)
		file := join(root, "..", "leita_survey_turn.tree")
		defer os.remove(file)
		target, choice, err := scan.resolve(root)
		testing.expect_value(t, err, scan.Error.None)
		defer scan.target_destroy(&target)
		place := scan.location(target, context.temp_allocator)
		db := join(place, "still", "db.sqlite")
		put(t, db, 200_000)
		time.sleep(changes.SLACK + 200 * time.Millisecond)

		Ran :: struct {
			how:     Fill_Kind,
			by:      Read_Source,
			reread:  u64,
			disk:    u64, // what db.sqlite was charged
			updates: u64, // what the cursor kept counts
		}
		run :: proc(t: ^testing.T, target: scan.Target, engine: scan.Engine, file, db: string) -> Ran {
			tree: scan.Tree
			testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
			defer scan.tree_destroy(&tree)
			f := Fill {
				target = target,
				engine = engine,
				wcfg = {workers = 2},
				tree = &tree,
				baseline = file,
			}
			defer fill_destroy(&f)
			fill_run(&f)
			testing.expectf(t, problem(&f) == "", "the fill failed: %s", problem(&f))
			testing.expect(t, f.saved, "the result was not kept")
			kept: scan.Tree
			defer scan.tree_destroy(&kept)
			cursor, why, ok := baseline_load(file, scan.location(target, context.temp_allocator), &kept)
			testing.expectf(t, ok, "the baseline was not read back: %s", why)
			return {f.how, f.by, f.reread, seen(&tree)[db].disk, cursor.updates}
		}

		first := run(t, target, choice.engine, file, db)
		testing.expect_value(t, first.how, Fill_Kind.Full)
		testing.expect_value(t, first.updates, 0)
		second := run(t, target, choice.engine, file, db)
		testing.expect_value(t, second.how, Fill_Kind.Updated)
		testing.expect_value(t, second.updates, 1)

		put(t, db, 400_000)
		measured := false
		for i in 0 ..< SLICES {
			r := run(t, target, choice.engine, file, db)
			testing.expect_value(t, r.how, Fill_Kind.Updated)
			testing.expect_value(t, r.updates, u64(i + 2))
			if r.by == .Times {
				testing.expectf(t, r.reread == 0, "update %d read %d directories again", i, r.reread)
			}
			if r.disk != first.disk {
				testing.expectf(t, r.disk >= 400_000, "update %d charged db.sqlite %d", i, r.disk)
				measured = true
				break
			}
		}
		testing.expectf(t, measured, "db.sqlite kept %d over %d updates", first.disk, SLICES)
	}
}

// how_read words each way a place was read.
@(test)
test_how_a_place_was_read_is_said :: proc(t: ^testing.T) {
	taken := time.unix(1_760_000_000, 0)
	one := how_read(true, "", 1, taken)
	testing.expectf(
		t,
		strings.has_prefix(one, "updated: 1 directory read again since 20"),
		"%q",
		one,
	)
	many := how_read(true, "", 3, taken)
	testing.expectf(t, strings.has_prefix(many, "updated: 3 directories read again"), "%q", many)
	testing.expectf(t, !strings.has_suffix(many, ")"), "the system's journal is named: %q", many)
	recorded := how_read(true, "", 3, taken, .Recorded)
	testing.expectf(t, strings.has_suffix(recorded, " (recorded changes)"), "%q", recorded)
	times := how_read(true, "", 3, taken, .Times)
	testing.expectf(t, strings.has_suffix(times, " (folder times)"), "%q", times)
	testing.expect_value(t, how_read(true, ""), "updated from the last scan")
	testing.expect_value(
		t,
		how_read(false, "asked to read it whole"),
		"read whole: asked to read it whole",
	)
	testing.expect_value(t, how_read(false, ""), "read whole")
}

// One node of a baseline built by hand, in the order the file stores them.
@(private = "file")
Kept_Node :: struct {
	parent: u32,
	name:   string,
}

// A baseline of `nodes` for `place`, written under the temp directory. The caller
// removes the file.
@(private = "file")
keep_nodes :: proc(t: ^testing.T, name, place: string, root: u32, nodes: []Kept_Node) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	path := join(strings.trim_right(dir, `\/`), name)
	size := len(BASELINE_MAGIC) + CURSOR_SIZE + 4 + len(place) + 8 + 4 // 4: no links
	for n in nodes {
		size += 15 + len(n.name)
	}
	out := make([]u8, size, context.temp_allocator)
	copy(out, BASELINE_MAGIC)
	at := len(BASELINE_MAGIC) + CURSOR_SIZE
	endian.put_u32(out[at:], .Little, u32(len(place)))
	at += 4
	copy(out[at:], place)
	at += len(place)
	endian.put_u32(out[at:], .Little, u32(len(nodes)))
	at += 4
	endian.put_u32(out[at:], .Little, root)
	at += 4
	for n in nodes {
		endian.put_u32(out[at:], .Little, n.parent)
		at += 4
		at += 1 + 8
		endian.put_u16(out[at:], .Little, u16(len(n.name)))
		at += 2
		copy(out[at:], n.name)
		at += len(n.name)
	}
	endian.put_u32(out[at:], .Little, 0) // the links: none
	at += 4
	testing.expect(t, at == len(out), "the baseline size was miscounted")
	testing.expect(t, os.write_entire_file(path, out) == nil, "could not write the baseline")
	return path
}

// A count of every u32, on a file of a few nodes, is a short file. It is refused
// before a block is reserved: one block is 65536 nodes, and the count asks for
// all of them.
@(test)
test_a_count_the_file_cannot_hold_reserves_nothing :: proc(t: ^testing.T) {
	root := fixture(t, "huge")
	defer os.remove_all(root)
	file := join(root, "..", "leita_survey_huge.tree")
	defer os.remove(file)
	tree := read_tree(t, root)
	defer scan.tree_destroy(&tree)
	testing.expect(t, baseline_save(file, root, &tree, {}), "the baseline was not kept")
	data, _ := os.read_entire_file(file, context.temp_allocator)
	at := len(BASELINE_MAGIC) + CURSOR_SIZE + 4 + len(root)
	endian.put_u32(data[at:], .Little, 0xFFFF_FFFF)
	testing.expect(t, os.write_entire_file(file, data) == nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	// Put the caller's allocator back before the tracker is destroyed, so a
	// later test does not allocate through it.
	prev := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = prev

	back: scan.Tree
	_, why, ok := baseline_load(file, root, &back)
	defer scan.tree_destroy(&back)
	testing.expect(t, !ok, "a count past the file was read")
	testing.expect_value(t, why, "the scan kept of this place is cut short")
	testing.expectf(
		t,
		track.peak_memory_allocated < 1 << 20,
		"reserved from the count: peak %d",
		track.peak_memory_allocated,
	)
}

// A parent numbered above its node, and an orphan that holds itself, are what the
// writer stores. A parent that leads back to a node is not, and is refused.
@(test)
test_a_parent_loop_is_refused :: proc(t: ^testing.T) {
	place := "place"
	ahead := keep_nodes(t, "leita_survey_ahead.tree", place, 1, {
		{parent = 1, name = "a"},
		{parent = 1, name = place},
	})
	defer os.remove(ahead)
	kept: scan.Tree
	_, why, ok := baseline_load(ahead, place, &kept)
	defer scan.tree_destroy(&kept)
	testing.expectf(t, ok, "a parent above its node was refused: %s", why)
	testing.expect_value(t, scan.node(&kept, 0).parent, u32(1))
	testing.expect_value(t, scan.node(&kept, 1).parent, u32(1))

	orphan := keep_nodes(t, "leita_survey_orphan.tree", place, 1, {
		{parent = 0, name = "loose"},
		{parent = 1, name = place},
	})
	defer os.remove(orphan)
	loose: scan.Tree
	_, why, ok = baseline_load(orphan, place, &loose)
	defer scan.tree_destroy(&loose)
	testing.expectf(t, ok, "an orphan that holds itself was refused: %s", why)

	loop := keep_nodes(t, "leita_survey_loop.tree", place, 0, {
		{parent = 1, name = "a"},
		{parent = 0, name = "b"},
	})
	defer os.remove(loop)
	back: scan.Tree
	_, why, ok = baseline_load(loop, place, &back)
	defer scan.tree_destroy(&back)
	testing.expect(t, !ok, "a parent loop was read")
	testing.expect_value(t, why, "the scan kept of this place loops")
}

// A child named "../../.ssh", or with a backslash or a NUL, is joined onto its
// directory and would leave it. The root's own name is the place path.
@(test)
test_a_name_with_a_separator_or_nul_is_refused :: proc(t: ^testing.T) {
	place := "place"
	bad := [?]string{"../../.ssh", "..\\secret", "a\x00b"}
	for name, i in bad {
		path := keep_nodes(
			t,
			fmt.tprintf("leita_survey_name_%d.tree", i),
			place,
			0,
			{{parent = 0, name = place}, {parent = 0, name = name}},
		)
		back: scan.Tree
		_, why, ok := baseline_load(path, place, &back)
		testing.expectf(t, !ok, "a name %q was read", name)
		testing.expect_value(t, why, "the scan kept of this place holds a name that is not one entry")
		scan.tree_destroy(&back)
		os.remove(path)
	}
}

// A directory that is its own descendant must not keep the hashed walk going.
@(test)
test_a_parent_loop_ends_the_hashed_walk :: proc(t: ^testing.T) {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, scan.reserve(&tree, 2), scan.Error.None)
	w := scan.writer(&tree, 0)
	a := scan.node(&tree, 0)
	a.parent = 1
	a.name = scan.intern(&w, "a")
	scan.node_publish(a, {.Used, .Settled, .Directory})
	b := scan.node(&tree, 1)
	b.parent = 0
	b.name = scan.intern(&w, "b")
	scan.node_publish(b, {.Used, .Settled, .Directory})
	tree.root = 0

	ix, ix_err := scan.index_make(&tree)
	testing.expect_value(t, ix_err, scan.Error.None)
	defer scan.index_destroy(&ix)
	u := walk.Update {
		base   = &tree,
		index  = ix,
		marks  = make(map[u32]walk.Mark, context.temp_allocator),
	}
	set := changes.Change_Set {
		by_hash = true,
		root    = "/place",
		hashes  = make(map[u64]struct{}, context.temp_allocator),
	}
	set.hashes[journal.hash_path("/place")] = {}
	mark_hashed(&u, &tree, ix, set)
	testing.expect_value(t, u.marks[0], walk.Mark.List)
}
