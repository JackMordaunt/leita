package leita_cli

import "core:crypto/ed25519"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:sqlite3"

import "../changes"
import "../history"
import "../journal"
import "../licence"
import "../scan"
import "../settings"
import "../survey"
import "../testtmp"

/*
Every earlier on-disk format, read by this build. The fixtures in testdata/compat
are files the earlier code wrote (tools/compat-fixtures/generate.py says how each
was made), so a format change that strands a file already on someone's disk fails
here, not on their machine. Each family is checked the same way: an older version
loads or migrates, keeping what it held; a future or damaged file is refused with
a message, or read as far as it can be, and never crashes the process; and none of
it deletes the file.

Fixtures, version by version:

	baseline/bl1..bl4.tree     LEITABL1..4, survey.baseline_save at 67625ca6, 80fc6339,
	                           c8b65130, a4745f64; bl5 is a version not made yet
	history/h1, h2             history.db before and after the disk columns (cd369da0)
	settings/s1..s6            settings.db as it grew: setting alone, the monitor
	                           tables, then the columns ALTERed in; s6 is this build's
	licence, .line files    the draft leita2 vectors (never issued), this format's
	firstuse, receipt          the trial's start and the licence key kept beside the line
	journal, .log files      LEITAJL1
	-future, -truncated,       a newer version, the file cut in half, and bit flips
	-bitflip
*/

@(private = "file")
FIXTURES :: #directory + "/testdata/compat"

@(private = "file")
PLACE :: "/compat/place"

// A folder for one test; the caller removes it.
@(private = "file")
folder :: proc(t: ^testing.T) -> string {
	dir, err := testtmp.make_dir("", "leita-compat-*", context.temp_allocator)
	testing.expect(t, err == nil, "could not make a folder")
	return dir
}

// bytes_of is the fixture rel as the earlier code wrote it, in the temp allocator.
@(private = "file")
bytes_of :: proc(t: ^testing.T, rel: string) -> []u8 {
	path, _ := filepath.join({FIXTURES, rel}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, err == nil, "fixture %s is missing", rel)
	return data
}

// A copy of fixture rel at dir/as, so a test that opens it never changes the one
// checked in. The path, and what the file held.
@(private = "file")
copy_of :: proc(t: ^testing.T, dir, rel, as: string) -> (path: string, data: []u8) {
	data = bytes_of(t, rel)
	path, _ = filepath.join({dir, as}, context.temp_allocator)
	if parent := filepath.dir(path); !os.exists(parent) {
		_ = os.make_directory_all(parent)
	}
	testing.expect(t, os.write_entire_file(path, data) == nil, "could not copy the fixture")
	return
}

// expect_unchanged fails unless the file at path is there holding exactly data.
@(private = "file")
expect_unchanged :: proc(t: ^testing.T, path: string, data: []u8, what: string) {
	now, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, err == nil, "%s: the file was deleted", what)
	testing.expectf(t, slice.equal(now, data), "%s: the file was changed", what)
}

// ---- baselines ------------------------------------------------------------------

@(private = "file")
BASELINE_CURSOR :: changes.Cursor {
	source   = .Probe,
	volume   = {0x801, 0x1},
	place    = {0x77, 0x1234},
	journal  = 5,
	position = 1_700_000_000,
	full     = 1_700_000_000,
	updates  = 2,
}

// The one version this build reads, LEITABL4, reads back as the tree and the
// cursor it was made with, links included.
@(test)
compat_baseline_current_version_loads :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	path, data := copy_of(t, dir, "baseline/bl4.tree", "a.tree")

	tree: scan.Tree
	cursor, why, ok := survey.baseline_load(path, PLACE, &tree)
	defer if ok {
		scan.tree_destroy(&tree)
	}

	testing.expectf(t, ok, "LEITABL4 was refused: %s", why)
	testing.expect_value(t, cursor, BASELINE_CURSOR)
	testing.expect_value(t, scan.slots(&tree), 4)
	testing.expect_value(t, scan.name_of(&tree, 0), PLACE)
	testing.expect_value(t, scan.name_of(&tree, 1), "docs")
	testing.expect_value(t, scan.name_of(&tree, 2), "a.txt")
	testing.expect_value(t, scan.name_of(&tree, 3), "b.bin")
	testing.expect_value(t, len(tree.linked), 1)
	expect_unchanged(t, path, data, "bl4")
}

// The entry count read from a baseline's head alone: the current version's, and
// nothing for an earlier or a future one (it reads the head alone, so a cut body still counts).
@(test)
compat_baseline_entry_count_reads_only_the_current_version :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	path, _ := copy_of(t, dir, "baseline/bl4.tree", "a.tree")
	n, ok := survey.baseline_entries(path, PLACE).?
	testing.expect(t, ok, "the current baseline gave no count")
	testing.expect_value(t, n, 4)

	for rel in ([]string{"baseline/bl1.tree", "baseline/bl2.tree", "baseline/bl3.tree", "baseline/bl5-future.tree"}) {
		path, _ = copy_of(t, dir, rel, "b.tree")
		_, ok = survey.baseline_entries(path, PLACE).?
		testing.expectf(t, !ok, "%s gave a count", rel)
	}
}

// A baseline of an earlier version is not read: the place is read whole once and
// a baseline of the current version replaces it. It says why, and loading leaves
// the file where it is.
@(test)
compat_baseline_earlier_versions_are_refused_clearly :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	for rel in ([]string{"baseline/bl1.tree", "baseline/bl2.tree", "baseline/bl3.tree"}) {
		path, data := copy_of(t, dir, rel, "old.tree")
		tree: scan.Tree
		_, why, ok := survey.baseline_load(path, PLACE, &tree)
		testing.expectf(t, !ok, "%s was read", rel)
		testing.expectf(
			t,
			strings.contains(why, "another version"),
			"%s: the reason is %q",
			rel,
			why,
		)
		expect_unchanged(t, path, data, rel)
	}
}

// A version this build has not heard of is refused the same way.
@(test)
compat_baseline_future_version_is_refused_clearly :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	for rel in ([]string{"baseline/bl5-future.tree", "baseline/bl4-magic-bitflip.tree"}) {
		path, data := copy_of(t, dir, rel, "new.tree")
		tree: scan.Tree
		_, why, ok := survey.baseline_load(path, PLACE, &tree)
		testing.expectf(t, !ok, "%s was read", rel)
		testing.expectf(t, strings.contains(why, "another version"), "%s: %q", rel, why)
		expect_unchanged(t, path, data, rel)
	}
}

// A damaged baseline of the current version is refused with a reason, whole.
@(test)
compat_baseline_damaged_copies_are_refused_clearly :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	for rel in ([]string{"baseline/bl4-truncated.tree", "baseline/bl4-bitflip.tree"}) {
		path, data := copy_of(t, dir, rel, "bad.tree")
		tree: scan.Tree
		_, why, ok := survey.baseline_load(path, PLACE, &tree)
		testing.expectf(t, !ok, "%s was read", rel)
		testing.expectf(t, why != "", "%s was refused without a reason", rel)
		expect_unchanged(t, path, data, rel)
	}
	// A file that is not there at all says so rather than failing.
	missing, _ := filepath.join({dir, "none.tree"}, context.temp_allocator)
	tree: scan.Tree
	_, why, ok := survey.baseline_load(missing, PLACE, &tree)
	testing.expect(t, !ok && why != "")
}

// Every cut of a good baseline, and every single flipped bit of it, is read or
// refused with a reason: none crashes, and none reads as a tree it is not.
@(test)
compat_baseline_every_cut_and_flip_is_survived :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	good := bytes_of(t, "baseline/bl4.tree")
	path, _ := filepath.join({dir, "swept.tree"}, context.temp_allocator)

	for n in 0 ..< len(good) {
		testing.expect(t, os.write_entire_file(path, good[:n]) == nil)
		tree: scan.Tree
		_, why, ok := survey.baseline_load(path, PLACE, &tree)
		testing.expectf(t, !ok && why != "", "a baseline cut to %d bytes was read", n)
	}
	flipped := slice.clone(good, context.temp_allocator)
	for at in 0 ..< len(good) {
		for bit in 0 ..< u8(8) {
			flipped[at] ~= 1 << bit
			testing.expect(t, os.write_entire_file(path, flipped) == nil)
			tree: scan.Tree
			_, why, ok := survey.baseline_load(path, PLACE, &tree)
			if ok {
				// A flip in a size, a cursor field or the root's index still
				// makes a whole tree of the same nodes.
				testing.expect_value(t, scan.slots(&tree), 4)
				scan.tree_destroy(&tree)
			} else {
				testing.expectf(t, why != "", "byte %d bit %d: refused without a reason", at, bit)
			}
			flipped[at] ~= 1 << bit
		}
	}
	testing.expect(t, os.exists(path), "the swept file was deleted")
}

// ---- history store --------------------------------------------------------------

@(private = "file")
expect_history_rows :: proc(t: ^testing.T, st: ^history.Store, disk: history.Disk, what: string) {
	snaps, err := history.list(st, PLACE)
	testing.expectf(t, err == nil, "%s: list: %v", what, err)
	if !testing.expectf(t, len(snaps) == 2, "%s: %d snapshots, want 2", what, len(snaps)) {
		return
	}
	testing.expect_value(t, snaps[0].taken, 1_700_086_400)
	testing.expect_value(t, snaps[0].bytes, 5048)
	testing.expect_value(t, snaps[0].items, 4)
	testing.expect_value(t, snaps[0].disk, disk)
	testing.expect_value(t, snaps[1].bytes, 3048)
	entries, lerr := history.load(st, snaps[0].id)
	defer history.forget(entries)
	testing.expectf(t, lerr == nil, "%s: load: %v", what, lerr)
	testing.expect_value(t, entries["docs"], 3000)
	acts, aerr := history.actions(st)
	testing.expectf(t, aerr == nil, "%s: actions: %v", what, aerr)
	if testing.expectf(t, len(acts) == 1, "%s: %d actions, want 1", what, len(acts)) {
		testing.expect_value(t, acts[0].kind, history.Action_Kind.Trash)
		testing.expect_value(t, acts[0].path, "/compat/place/old")
		testing.expect_value(t, acts[0].bytes, 512)
	}
}

// A store from before the disk was kept (h1) and the current one (h2) both open,
// keep every row, and open again to the same; the first gains the disk columns.
// Saving to either afterwards works, and the baselines beside them stay.
@(test)
compat_history_earlier_stores_open_and_keep_their_rows :: proc(t: ^testing.T) {
	for version in 1 ..= 2 {
		dir := folder(t)
		defer os.remove_all(dir)

		rel := fmt.tprintf("history/h%d.db", version)
		path, _ := copy_of(t, dir, rel, "history.db")
		// A baseline of every version beside the store, as a data folder holds
		// them. Opening prunes by age alone, and these are new.
		bases := make([dynamic]string, context.temp_allocator)
		for b in ([]string{"bl1", "bl2", "bl3", "bl4"}) {
			p, _ := copy_of(t, dir, fmt.tprintf("baseline/%s.tree", b), fmt.tprintf("baselines/%s.tree", b))
			append(&bases, p)
		}
		for _ in 0 ..< 2 {
			st: history.Store
			err := history.open(&st, path)
			testing.expectf(t, err == nil, "%s: open: %v", rel, err)
			if err != nil {
				return
			}
			expect_history_rows(t, &st, {} if version == 1 else {7, 7}, rel)
			history.close(&st)
		}
		st: history.Store
		testing.expect(t, history.open(&st, path) == nil)
		_, serr := history.save(&st, PLACE, 1_700_172_800, 9, 1, {{"docs", 9}}, history.Disk{100, 40})
		testing.expectf(t, serr == nil, "%s: save: %v", rel, serr)
		snaps, _ := history.list(&st, PLACE)
		testing.expect_value(t, len(snaps), 3)
		testing.expect_value(t, snaps[0].disk, history.Disk{100, 40})
		history.close(&st)
		for p in bases {
			testing.expectf(t, os.exists(p), "%s: opening the store deleted %s", rel, p)
		}
	}
}

// A store a newer leita made, with a column and a table this one does not know,
// opens and reads what it knows, and still holds what it does not.
@(test)
compat_history_future_store_is_read_and_left_whole :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	path, _ := copy_of(t, dir, "history/h-future.db", "history.db")
	st: history.Store
	err := history.open(&st, path)
	if !testing.expectf(t, err == nil, "open: %v", err) {
		return
	}
	defer history.close(&st)

	expect_history_rows(t, &st, {7, 7}, "h-future")
	_, serr := history.save(&st, PLACE, 1_700_172_800, 9, 1, {{"docs", 9}}, history.Disk{})
	testing.expectf(t, serr == nil, "save into a newer store: %v", serr)
	rows, qerr := sqlite3.query(st.db, "SELECT v FROM tomorrow", allocator = context.temp_allocator)
	testing.expect(t, qerr == nil)
	testing.expect(t, sqlite3.next(&rows), "the newer store's table lost its row")
	testing.expect_value(t, sqlite3.text(rows, 0), "yes")
	_ = sqlite3.finish(&rows)
}

// A damaged store is reported or read as far as it reads: the open or a read says
// what went wrong, the process goes on, and the file is not deleted.
@(test)
compat_history_damaged_stores_are_survived :: proc(t: ^testing.T) {
	// A refused open hands back an error whose text is the caller's to free; the
	// temp allocator takes it here.
	context.allocator = context.temp_allocator
	for rel in ([]string{"history/h2-truncated.db", "history/h2-bitflip.db", "history/h2-bitflip-body.db"}) {
		dir := folder(t)
		defer os.remove_all(dir)

		path, data := copy_of(t, dir, rel, "history.db")
		st: history.Store
		err := history.open(&st, path)
		if err != nil {
			testing.expectf(t, history.describe(err) != "", "%s: an error without words", rel)
		} else {
			snaps, lerr := history.list(&st, PLACE)
			if lerr != nil {
				testing.expectf(t, history.describe(lerr) != "", "%s: an error without words", rel)
			}
			_ = snaps
			_, _ = history.actions(&st)
			history.close(&st)
		}
		testing.expectf(t, os.exists(path), "%s: the store was deleted", rel)
		if rel == "history/h2-bitflip.db" {
			testing.expectf(t, err != nil, "%s: a file that is not a database opened", rel)
			expect_unchanged(t, path, data, rel)
		}
	}
}

// ---- settings store ------------------------------------------------------------------

@(private = "file")
expect_settings_rows :: proc(t: ^testing.T, st: ^settings.Store, version: int, what: string) {
	language, found := settings.get(st, settings.LANGUAGE, context.temp_allocator)
	testing.expect(t, found && language == "de", what)
	theme, _ := settings.get(st, settings.THEME, context.temp_allocator)
	testing.expect_value(t, theme, "dark")
	testing.expect_value(t, settings.monitoring(st), version >= 2)
	watches, werr := settings.watches(st, context.temp_allocator)
	testing.expectf(t, werr == nil, "%s: watches: %v", what, werr)
	runs, rerr := settings.runs(st, PLACE, allocator = context.temp_allocator)
	testing.expectf(t, rerr == nil, "%s: runs: %v", what, rerr)
	raised, aerr := settings.alerts(st, allocator = context.temp_allocator)
	testing.expectf(t, aerr == nil, "%s: alerts: %v", what, aerr)
	hooks, herr := settings.hooks(st, context.temp_allocator)
	testing.expectf(t, herr == nil, "%s: hooks: %v", what, herr)
	waiting, derr := settings.due(st, 2_000_000_000, allocator = context.temp_allocator)
	testing.expectf(t, derr == nil, "%s: due: %v", what, derr)
	testing.expect_value(t, len(hooks), 1 if version >= 7 else 0)
	testing.expect_value(t, len(waiting), 1 if version >= 7 else 0)
	if version >= 7 && len(hooks) == 1 {
		testing.expect_value(t, hooks[0].url, "https://hooks.example/leita")
		testing.expect(t, hooks[0].paths)
	}
	if version < 2 {
		testing.expect_value(t, len(watches), 0)
		testing.expect_value(t, len(runs), 0)
		return
	}
	if testing.expectf(t, len(watches) == 1, "%s: %d watches", what, len(watches)) {
		testing.expect_value(t, watches[0].place, PLACE)
		testing.expect_value(t, watches[0].every, settings.Frequency.Daily)
		testing.expect_value(t, watches[0].added, 1_700_000_000)
	}
	if testing.expectf(t, len(runs) == 1, "%s: %d runs", what, len(runs)) {
		testing.expect_value(t, runs[0].bytes, 3048)
	}
	testing.expect_value(t, len(raised), 1 if version >= 4 else 0)
}

// Every settings.db the monitor's tables have been through opens, gains the
// columns it lacks, keeps every row, and opens again to the same. The columns it
// gained read as their defaults, and a watch can be added afterwards.
@(test)
compat_settings_earlier_stores_open_and_keep_their_rows :: proc(t: ^testing.T) {
	for version in 1 ..= 7 {
		dir := folder(t)
		defer os.remove_all(dir)

		rel := fmt.tprintf("settings/s%d.db", version)
		path, _ := copy_of(t, dir, rel, "settings.db")
		for _ in 0 ..< 2 {
			st: settings.Store
			err := settings.open(&st, path)
			testing.expectf(t, err == nil, "%s: open: %v", rel, err)
			if err != nil {
				return
			}
			expect_settings_rows(t, &st, version, rel)
			settings.close(&st)
		}
		st: settings.Store
		testing.expect(t, settings.open(&st, path) == nil)
		werr := settings.watch(&st, settings.Watch{place = "/compat/other", every = .Weekly, added = 1_700_100_000, limits = {warn_used = 80, growth = true}})
		testing.expectf(t, werr == nil, "%s: watch: %v", rel, werr)
		watches, _ := settings.watches(&st, context.temp_allocator)
		testing.expect_value(t, len(watches), 2 if version >= 2 else 1)
		settings.close(&st)
	}
}

// A newer leita's settings.db, with a column on watch this one does not know,
// still reads and takes a new watch beside its own.
@(test)
compat_settings_future_store_is_read_and_takes_a_watch :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	path, _ := copy_of(t, dir, "settings/s-future.db", "settings.db")
	st: settings.Store
	err := settings.open(&st, path)
	if !testing.expectf(t, err == nil, "open: %v", err) {
		return
	}
	defer settings.close(&st)

	expect_settings_rows(t, &st, 7, "s-future")
	werr := settings.watch(&st, settings.Watch{place = "/compat/other", every = .Hourly, added = 1_700_100_000})
	testing.expectf(t, werr == nil, "watch into a newer store: %v", werr)
}

// A damaged settings.db is reported or read as far as it reads, never fatal, and
// is not deleted: the window follows its defaults rather than the person's lost
// choices being erased.
@(test)
compat_settings_damaged_stores_are_survived :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // as the history test above
	for rel in ([]string{"settings/s7-truncated.db", "settings/s7-bitflip.db", "settings/s7-bitflip-body.db"}) {
		dir := folder(t)
		defer os.remove_all(dir)

		path, data := copy_of(t, dir, rel, "settings.db")
		st: settings.Store
		err := settings.open(&st, path)
		if err == nil {
			_, _ = settings.get(&st, settings.LANGUAGE, context.temp_allocator)
			_, _ = settings.watches(&st, context.temp_allocator)
			_, _ = settings.runs(&st, PLACE, allocator = context.temp_allocator)
			_ = settings.monitoring(&st)
			settings.close(&st)
		}
		testing.expectf(t, os.exists(path), "%s: the store was deleted", rel)
		if rel == "settings/s7-bitflip.db" {
			testing.expectf(t, err != nil, "%s: a file that is not a database opened", rel)
			expect_unchanged(t, path, data, rel)
		}
	}
}

// ---- licence, trial, receipt ----------------------------------------------------------------

@(private = "file")
throwaway_key :: proc(t: ^testing.T) -> [ed25519.PUBLIC_KEY_SIZE]byte {
	raw, ok := hex.decode(transmute([]byte)strings.trim_space(THROW_PUB), context.temp_allocator)
	testing.expect(t, ok && len(raw) == ed25519.PUBLIC_KEY_SIZE)
	key: [ed25519.PUBLIC_KEY_SIZE]byte
	copy(key[:], raw)
	return key
}

// A licence line kept as a file, as the app keeps it: the current format is the
// one it takes; the drafts, a future prefix and damaged copies each say why not,
// and the file stays.
@(test)
compat_licence_kept_lines :: proc(t: ^testing.T) {
	key := throwaway_key(t)
	dir := folder(t)
	defer os.remove_all(dir)

	path, data := copy_of(t, dir, "licence/current.line", "licence")
	l, from, err := licence.in_use(path, "", key[:])
	testing.expect_value(t, err, licence.Error.None)
	testing.expect_value(t, from, licence.Source.Kept)
	testing.expect_value(t, l.licensee, "ada@example.com")
	expect_unchanged(t, path, data, "current.line")

	Case :: struct {
		rel:  string,
		want: licence.Error,
	}
	for c in ([]Case {
			{"licence/draft-leita2-vector-1.line", .Version},
			{"licence/draft-leita2-vector-2.line", .Version},
			{"licence/future-prefix.line", .Version},
			{"licence/current-truncated.line", .Malformed},
			{"licence/current-bitflip.line", .Signature},
		}) {
		path, data = copy_of(t, dir, c.rel, "licence")
		_, from, err = licence.in_use(path, "", key[:])
		testing.expectf(t, err == c.want, "%s: %v, want %v", c.rel, err, c.want)
		testing.expectf(t, licence.describe(err) != "", "%s: no words for %v", c.rel, err)
		testing.expect_value(t, from, licence.Source.Kept)
		expect_unchanged(t, path, data, c.rel)
	}
}

// The licence key kept beside the line: a key is read; one with whitespace inside,
// or longer than a key can be, is not a key, and its file stays.
@(test)
compat_receipt_files :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	line, _ := filepath.join({dir, "licence"}, context.temp_allocator)

	_, data := copy_of(t, dir, "receipt/licence-key", "licence-key")
	key, ok := licence.read_receipt(line)
	testing.expect(t, ok && key == "ABCD-1234-EFGH-5678", "the kept key was not read")
	expect_unchanged(t, licence.receipt_path(line, context.temp_allocator), data, "licence-key")

	for rel in ([]string{"receipt/licence-key-garbled", "receipt/licence-key-long"}) {
		_, data = copy_of(t, dir, rel, "licence-key")
		_, ok = licence.read_receipt(line)
		testing.expectf(t, !ok, "%s was taken for a key", rel)
		expect_unchanged(t, licence.receipt_path(line, context.temp_allocator), data, rel)
	}
}

// The trial's start: a number is the start; a garbled file ends the trial, fails
// closed, and is not rewritten.
@(test)
compat_first_use_files :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	now := time.unix(1_790_000_000 + 86_400, 0)

	path, data := copy_of(t, dir, "firstuse/first-use", "first-use")
	start := licence.first_use(path, {}, now)
	testing.expect_value(t, time.to_unix_seconds(start), 1_790_000_000)
	expect_unchanged(t, path, data, "first-use")

	path, data = copy_of(t, dir, "firstuse/first-use-garbled", "first-use")
	start = licence.first_use(path, {}, now)
	testing.expect_value(t, start, licence.TRIAL_OVER)
	expect_unchanged(t, path, data, "first-use-garbled")
}

// ---- journal ------------------------------------------------------------------------

// The change journal's log header: LEITAJL1 is read, another magic, a cut header
// and a length that runs past its bound are not, and compacting a log it cannot
// read fails and leaves it alone.
@(test)
compat_journal_logs :: proc(t: ^testing.T) {
	dir := folder(t)
	defer os.remove_all(dir)

	path, data := copy_of(t, dir, "journal/current.log", "a.log")
	mount, size, ok := journal.header_read(data)
	testing.expect(t, ok, "the current header was refused")
	testing.expect_value(t, mount, "/home")
	testing.expect_value(t, size, 15)

	for rel in ([]string{"journal/future.log", "journal/truncated.log", "journal/bitflip.log"}) {
		path, data = copy_of(t, dir, rel, "b.log")
		_, _, ok = journal.header_read(data)
		testing.expectf(t, !ok, "%s: the header was read", rel)
		_, err := journal.compact(path, 0)
		testing.expectf(t, err != nil, "%s: compact went ahead", rel)
		expect_unchanged(t, path, data, rel)
	}
}
