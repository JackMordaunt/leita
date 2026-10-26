package durability

import "core:fmt"
import "core:math/rand"
import jm_path "jm:path"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:sqlite3"

import "../history"
import "../licence"
import "../report"
import "../scan"
import "../settings"
import "../survey"
import "../walk"

// WAIT is as long as a child is given to finish a case before it is taken as hung.
WAIT :: 60 * time.Second

// workdir is a fresh directory for one run of a case.
@(private = "file")
workdir :: proc(t: ^testing.T, name: string) -> string {
	parent := os.temp_directory(context.temp_allocator) or_else "."
	// macOS names its temp directory under /var, a link, and a delete refuses a
	// path through one (files.open_directory; Delete_Tree said "it is not a
	// directory" on macos-latest, run 40145355033): it is named link-free.
	if info, err := os.stat(parent, context.temp_allocator); err == nil && info.fullpath != "" {
		parent = info.fullpath
	}
	dir, err := jm_path.make_directory_temp(parent, fmt.tprintf("leita-durability-%s-*", name), context.temp_allocator)
	testing.expectf(t, err == nil, "no work directory: %v", err)
	return dir
}

// Outcome is how a child's run of a case ended.
@(private = "file")
Outcome :: struct {
	done:      bool, // it finished the case and wrote DONE
	crossings: int, // the calls it made through the seam, when done
	said:      string, // its standard error
	exit:      int, // its exit code
	wait:      os.Error, // how waiting for it failed, nil if it did not
}

// start runs case c in dir in a child, to be killed at the at'th call it makes
// through the seam, 0 for none.
@(private = "file")
start :: proc(t: ^testing.T, c: Case, dir: string, at := 0) -> (child: os.Process, ok: bool) {
	// The binary itself, wherever it was started from.
	self, aerr := os.get_executable_path(context.temp_allocator)
	testing.expectf(t, aerr == nil, "cannot find this binary: %v", aerr)
	base, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, 0, len(base) + 4, context.temp_allocator)
	for v in base {
		// The child's own are set below, so each is in its environment once.
		if !strings.has_prefix(v, "XDG_DATA_HOME=") && !strings.has_prefix(v, "LEITA_DURABILITY_") {
			append(&env, v)
		}
	}
	append(&env, fmt.tprintf("%s=%v", ENV_CASE, c))
	append(&env, fmt.tprintf("%s=%s", ENV_DIR, dir))
	append(&env, fmt.tprintf("%s=%d", ENV_AT, at))
	append(&env, fmt.tprintf("XDG_DATA_HOME=%s", in_dir(dir, DATA)))
	// A child killed or sent on its way leaks what it held, by design.
	append(&env, "ASAN_OPTIONS=detect_leaks=0")

	stderr, oerr := os.open(in_dir(dir, "stderr"), {.Write, .Create, .Trunc})
	testing.expectf(t, oerr == nil, "cannot capture the child: %v", oerr)
	defer os.close(stderr)

	err: os.Error
	child, err = os.process_start({command = {self}, env = env[:], stderr = stderr})
	testing.expectf(t, err == nil, "cannot start a child: %v", err)
	return child, err == nil
}

// wait_for_exit waits for child to exit, and says how, for as long as WAIT.
// After a non-timeout wait error, query the child's state until it has exited
// or the deadline has passed.
@(private = "file")
wait_for_exit :: proc(child: os.Process) -> (state: os.Process_State, err: os.Error) {
	state, err = os.process_wait(child, WAIT)
	if err == nil || err == os.General_Error.Timeout {
		return
	}

	deadline := time.time_add(time.now(), WAIT)
	for {
		state, err = os.process_wait(child, 0)
		if err != os.General_Error.Timeout || time.diff(time.now(), deadline) <= 0 {
			return
		}
		// Still running: ask again a moment on.
		time.sleep(time.Millisecond)
	}
}

// finish waits for child and says how its run in dir ended.
@(private = "file")
finish :: proc(t: ^testing.T, child: os.Process, dir: string) -> (out: Outcome) {
	state, werr := wait_for_exit(child)
	if werr == os.General_Error.Timeout {
		_ = os.process_kill(child)
		_, werr = os.process_wait(child)
		testing.expectf(t, false, "the child in %s hung", dir)
	}
	out.exit = state.exit_code
	out.wait = werr

	said, _ := os.read_entire_file(in_dir(dir, "stderr"), context.temp_allocator)
	out.said = string(said)
	done, derr := os.read_entire_file(in_dir(dir, DONE), context.temp_allocator)
	if derr == nil {
		out.done = true
		out.crossings, _ = strconv.parse_int(string(done))
	}
	return
}

// run runs case c in dir to its end, or to the at'th call it makes through the seam.
@(private = "file")
run_child :: proc(t: ^testing.T, c: Case, dir: string, at := 0) -> Outcome {
	child, ok := start(t, c, dir, at)
	if !ok {
		return {}
	}
	out := finish(t, child, dir)
	if at == 0 {
		testing.expectf(t, out.done, "%v did not finish (exit %d, wait %v): %s", c, out.exit, out.wait, out.said)
	} else {
		testing.expectf(t, !out.done, "%v was not killed at %d: %s", c, at, out.said)
	}
	return out
}

/*
each_point runs case c once to its end, to count the calls it makes through the seam,
then once killed at each of those calls, setting up a fresh directory with setup
before every run and checking it with check after, told whether the case finished.
*/
@(private = "file")
each_point :: proc(
	t: ^testing.T,
	c: Case,
	setup: proc(t: ^testing.T, dir: string),
	check: proc(t: ^testing.T, dir: string, at: int),
) -> (
	points: int,
) {
	dir := workdir(t, fmt.tprint(c))
	setup(t, dir)
	whole := run_child(t, c, dir)
	check(t, dir, 0)
	os.remove_all(dir)
	testing.expectf(t, whole.crossings > 0, "%v made no call through the seam", c)

	for at in 1 ..= whole.crossings {
		dir = workdir(t, fmt.tprint(c))
		setup(t, dir)
		run_child(t, c, dir, at)
		check(t, dir, at)
		os.remove_all(dir)
	}
	return whole.crossings
}

LINE_BEFORE :: "leita.the-line-kept-before"
LINE_AFTER :: "leita.the-line-saved-after"

// A licence save killed at any point leaves the line before or the one saved, whole,
// and the next save holds and leaves no staging file.
@(test)
a_licence_save_killed_anywhere_keeps_a_whole_line :: proc(t: ^testing.T) {
	setup :: proc(t: ^testing.T, dir: string) {
		testing.expect_value(t, licence.save(in_dir(dir, LICENCE), LINE_BEFORE), licence.Error.None)
		testing.expect(t, os.write_entire_file(in_dir(dir, NEXT_LICENCE), LINE_AFTER) == nil)
	}
	check :: proc(t: ^testing.T, dir: string, at: int) {
		path := in_dir(dir, LICENCE)
		got, err := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, err == nil, "killed at %d: the licence is gone", at)
		line := string(got)
		testing.expectf(
			t,
			line == LINE_BEFORE + "\n" || line == LINE_AFTER + "\n",
			"killed at %d: the licence holds %q",
			at,
			line,
		)
		if at == 0 {
			testing.expectf(t, line == LINE_AFTER + "\n", "the save did not hold")
		}
		testing.expect(t, os.exists(in_dir(dir, NEXT_LICENCE)), "a file the save does not own went")
		testing.expect_value(t, licence.save(path, LINE_AFTER), licence.Error.None)
		testing.expect(t, !os.exists(fmt.tprintf("%s.new", path)), "the next save left its staging file")
	}
	points := each_point(t, .Licence_Save, setup, check)
	testing.expectf(t, points >= 4, "a licence save made %d calls, not its open, write, sync and rename", points)
}

// A forget killed at any point leaves the line whole or gone, never part of it.
@(test)
a_licence_forget_killed_anywhere_leaves_it_whole_or_gone :: proc(t: ^testing.T) {
	setup :: proc(t: ^testing.T, dir: string) {
		path := in_dir(dir, LICENCE)
		testing.expect_value(t, licence.save(path, LINE_BEFORE), licence.Error.None)
		testing.expect_value(t, licence.save_receipt(path, "LEITA-KEY"), licence.Error.None)
		testing.expect(t, os.write_entire_file(in_dir(dir, NEXT_LICENCE), LINE_AFTER) == nil)
	}
	check :: proc(t: ^testing.T, dir: string, at: int) {
		got, err := os.read_entire_file(in_dir(dir, LICENCE), context.temp_allocator)
		if err == nil {
			testing.expectf(t, string(got) == LINE_BEFORE + "\n", "killed at %d: the licence holds %q", at, got)
		}
		testing.expectf(t, at > 0 || err != nil, "the forget did not hold")
		testing.expect(t, os.exists(in_dir(dir, NEXT_LICENCE)), "a file the forget does not own went")
	}
	points := each_point(t, .Licence_Forget, setup, check)
	testing.expectf(t, points >= 2, "a forget made %d calls, not its two removes", points)
}

// A baseline save killed at any point leaves the baseline before or the new one,
// whole, the place it was of untouched; a temporary file it leaves is the prune's.
@(test)
a_baseline_save_killed_anywhere_keeps_a_whole_baseline :: proc(t: ^testing.T) {
	setup :: proc(t: ^testing.T, dir: string) {
		place := in_dir(dir, TREE)
		testing.expect(t, os.make_directory(place) == nil)
		testing.expect(t, os.write_entire_file(in_dir(place, "a"), strings.repeat("a", 100, context.temp_allocator)) == nil)
		tree: scan.Tree
		defer scan.tree_destroy(&tree)

		testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
		testing.expect_value(t, walk.read(place, &tree, walk.Config{workers = 2}), walk.Error.None)
		testing.expect(t, survey.baseline_save(in_dir(dir, BASELINE), place, &tree, {}))
		testing.expect(t, os.write_entire_file(in_dir(place, "b"), strings.repeat("b", 5000, context.temp_allocator)) == nil)
	}
	check :: proc(t: ^testing.T, dir: string, at: int) {
		place := in_dir(dir, TREE)
		count, kept := survey.baseline_entries(in_dir(dir, BASELINE), place).?
		testing.expectf(t, kept, "killed at %d: no baseline reads", at)
		// The place and a, before; and b too, after.
		testing.expectf(t, count == 2 || count == 3, "killed at %d: the baseline kept %d entries", at, count)
		testing.expectf(t, at > 0 || count == 3, "the save did not hold")
		tree: scan.Tree
		defer scan.tree_destroy(&tree)

		_, why, ok := survey.baseline_load(in_dir(dir, BASELINE), place, &tree)
		testing.expectf(t, ok, "killed at %d: the baseline does not load: %s", at, why)
		testing.expect(t, os.exists(in_dir(place, "a")) && os.exists(in_dir(place, "b")), "the place lost a file")
	}
	points := each_point(t, .Baseline_Save, setup, check)
	testing.expectf(t, points >= 3, "a baseline save made %d calls, not its open, write and rename", points)
}

// SELECTED is each file setup_selection makes under the selection.
SELECTED :: [?]string{"a", "b", "sub/c", "sub/deeper/d"}

// setup_selection makes a selection to delete or trash, and a file beside it.
@(private)
setup_selection :: proc(t: ^testing.T, dir: string) {
	selection := in_dir(dir, SELECTION)
	testing.expect(t, os.make_directory_all(in_dir(selection, "sub/deeper")) == nil)

	for name in SELECTED {
		testing.expect(t, os.write_entire_file(in_dir(selection, name), name) == nil)
	}

	testing.expect(t, os.write_entire_file(in_dir(dir, OUTSIDE), OUTSIDE) == nil)
}

// every file left of the selection at selection is whole, and the file beside it
// is there.
@(private)
expect_whole :: proc(t: ^testing.T, dir, selection: string, at: int) -> (left: int) {
	for name in SELECTED {
		got, err := os.read_entire_file(in_dir(selection, name), context.temp_allocator)
		if err == nil {
			left += 1
			testing.expectf(t, string(got) == name, "killed at %d: %s holds %q", at, name, got)
		}
	}

	beside, _ := os.read_entire_file(in_dir(dir, OUTSIDE), context.temp_allocator)
	testing.expectf(t, string(beside) == OUTSIDE, "killed at %d: the file beside the selection went", at)
	return
}

// A delete killed at any point deletes nothing outside its selection, and leaves
// what it had not reached whole.
@(test)
a_delete_killed_anywhere_touches_nothing_outside_the_selection :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux && ODIN_OS != .Darwin {
		// The Windows delete makes its own calls, not through the seam.
		return
	}
	check :: proc(t: ^testing.T, dir: string, at: int) {
		left := expect_whole(t, dir, in_dir(dir, SELECTION), at)
		testing.expectf(t, at > 0 || (left == 0 && !os.exists(in_dir(dir, SELECTION))), "the delete did not hold")
	}
	points := each_point(t, .Delete_Tree, setup_selection, check)
	testing.expectf(t, points == len(SELECTED) + 3, "a delete made %d unlinks, not one for each file and folder", points)
}

// A move to the Trash killed at any point leaves the selection where it was or in
// the Trash, whole, and one there has its info file, so it can be put back.
@(test)
a_trash_killed_anywhere_keeps_the_selection_whole :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		// macOS and Windows move to the Trash through the system, not the seam.
		return
	}
	check :: proc(t: ^testing.T, dir: string, at: int) {
		trashed := in_dir(dir, DATA + "/Trash/files/" + SELECTION)
		here := expect_whole(t, dir, in_dir(dir, SELECTION), at)
		there := expect_whole(t, dir, trashed, at)
		testing.expectf(t, here + there == len(SELECTED), "killed at %d: %d here and %d in the Trash", at, here, there)
		if there > 0 {
			info := in_dir(dir, DATA + "/Trash/info/" + SELECTION + ".trashinfo")
			testing.expectf(t, os.exists(info), "killed at %d: the Trash cannot put it back", at)
		}
		testing.expectf(t, at > 0 || there == len(SELECTED), "the trash did not hold")
	}
	each_point(t, .Trash, setup_selection, check)
}

REPORT_BEFORE :: "the report kept before"

// A report save killed at any point leaves the report before or the new one, whole.
@(test)
a_report_save_killed_anywhere_keeps_a_whole_report :: proc(t: ^testing.T) {
	setup :: proc(t: ^testing.T, dir: string) {
		testing.expect(t, os.write_entire_file(in_dir(dir, REPORT), REPORT_BEFORE) == nil)
	}
	check :: proc(t: ^testing.T, dir: string, at: int) {
		got, err := os.read_entire_file(in_dir(dir, REPORT), context.temp_allocator)
		testing.expectf(t, err == nil, "killed at %d: the report is gone", at)
		text := string(got)
		r := sample_report()
		b := strings.builder_make(context.temp_allocator)
		testing.expect_value(t, report.export(strings.to_writer(&b), &r, .Json), report.Error.None)
		whole := text == strings.to_string(b)
		testing.expectf(t, text == REPORT_BEFORE || whole, "killed at %d: the report holds %q", at, text)
		testing.expectf(t, at > 0 || whole, "the save did not hold")
	}
	points := each_point(t, .Report_Save, setup, check)
	testing.expectf(t, points >= 4, "a report save made %d calls, not its open, write, sync and rename", points)
}

// ROUNDS is how many times each SQLite store's child is killed, each after its own
// delay.
ROUNDS :: 6

// acked is each number a looping child in dir wrote whole to ACKS.
@(private = "file")
acked :: proc(dir: string) -> []int {
	data, _ := os.read_entire_file(in_dir(dir, ACKS), context.temp_allocator)
	lines := strings.split(string(data), "\n", context.temp_allocator)
	out := make([dynamic]int, context.temp_allocator)
	// The last is empty, or a line the kill cut short.
	for line in lines[:max(len(lines) - 1, 0)] {
		if n, ok := strconv.parse_int(line); ok {
			append(&out, n)
		}
	}
	return out[:]
}

// integrity is what SQLite's integrity check says of db, "ok" when it is sound.
@(private)
integrity :: proc(db: sqlite3.Db) -> string {
	rows, err := sqlite3.query(db, "PRAGMA integrity_check", allocator = context.temp_allocator)
	if err != nil {
		return history.describe(err)
	}
	defer sqlite3.finish(&rows)

	if !sqlite3.next(&rows) {
		return "no answer"
	}
	return strings.clone(sqlite3.text(rows, 0), context.temp_allocator)
}

/*
kill_rounds runs case c in a fresh directory ROUNDS times, killing it each time after
a delay drawn from the test's seed, longer each round, and hands the directory and
what the child acked to check. Some round must have acked a write, or the kills only
ever landed before the first.
*/
@(private = "file")
kill_rounds :: proc(t: ^testing.T, c: Case, check: proc(t: ^testing.T, dir: string, acks: []int)) {
	r := rand.create(u64(t.seed))
	any_acked := false
	for round in 0 ..< ROUNDS {
		dir := workdir(t, fmt.tprint(c))
		defer os.remove_all(dir)

		child, ok := start(t, c, dir)
		if !ok {
			return
		}
		jitter := rand.int_max(400, rand.default_random_generator(&r))
		delay := time.Duration(100 * (round + 1) + jitter) * time.Millisecond
		_, werr := os.process_wait(child, delay)
		testing.expectf(t, werr == os.General_Error.Timeout, "%v ended before it was killed", c)
		testing.expect(t, os.process_kill(child) == nil, "could not kill the child")
		out := finish(t, child, dir)
		testing.expectf(t, !out.done, "%v finished %d writes before it was killed", c, LOOPS)
		acks := acked(dir)
		any_acked ||= len(acks) > 0
		check(t, dir, acks)
	}
	testing.expectf(t, any_acked, "%v was killed before it wrote anything, every round", c)
}

// A settings store killed mid-write opens whole, holding every setting it said it
// wrote.
@(test)
a_settings_store_killed_mid_write_holds_what_it_acked :: proc(t: ^testing.T) {
	kill_rounds(t, .Settings_Set, proc(t: ^testing.T, dir: string, acks: []int) {
		st: settings.Store
		err := settings.open(&st, in_dir(dir, SETTINGS))
		testing.expectf(t, err == nil, "the store does not open: %s", history.describe(err))
		if err != nil {
			return
		}
		defer settings.close(&st)

		testing.expect_value(t, integrity(st.db), "ok")
		for i in acks {
			value, found := settings.get(&st, fmt.tprintf("key-%d", i), context.temp_allocator)
			testing.expectf(t, found && len(value) == i % 512, "setting %d of %d acked is lost", i, len(acks))
		}
	})
}

// A history store killed mid-keep opens whole, holding every scan it said it kept,
// each with all its entries.
@(test)
a_history_store_killed_mid_keep_holds_what_it_acked :: proc(t: ^testing.T) {
	kill_rounds(t, .History_Keep, proc(t: ^testing.T, dir: string, acks: []int) {
		st: history.Store
		err := history.open(&st, in_dir(dir, HISTORY))
		testing.expectf(t, err == nil, "the store does not open: %s", history.describe(err))
		if err != nil {
			return
		}
		defer history.close(&st)

		testing.expect_value(t, integrity(st.db), "ok")
		for i in acks {
			snaps, _ := history.list(&st, place_of(i))
			if !testing.expectf(t, len(snaps) == 1, "scan %d of %d acked is lost", i, len(acks)) {
				continue
			}
			kept, _ := history.load(&st, snaps[0].id, context.temp_allocator)
			testing.expectf(t, len(kept) == len(entries_of(i)), "scan %d kept %d entries", i, len(kept))
		}
	})
}
