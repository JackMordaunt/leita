#+build linux, darwin
package survey

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "../changes"
import "../scan"
import "../walk"

/*
A baseline kept from a scan that could not open a directory does not pass that
directory off as empty: the next fill, updating from it, reads the directory again
and finds what it holds once it can be opened.

	<root>/a.txt               100 bytes
	<root>/locked/big.bin      1 MiB, behind a mode 000 directory

Root opens anything, so the test skips there. On macOS the chmod itself is named by
FSEvents and relists the directory, which reaches the same answer by another road
(2026-10-16: this test passed with walk.job_of's Unread check removed, while
walk/unix_test.odin's update test failed), so that test is the one that pins the
update with no change named at all.
*/
@(test)
test_a_baseline_does_not_keep_an_unread_directory_as_empty :: proc(t: ^testing.T) {
	if posix.geteuid() == 0 {
		log.info("skipped: root can open any directory")
		return
	}
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_survey_unread_%d", strings.trim_right(dir, "/"), os.get_pid())
	locked := fmt.tprintf("%s/locked", root)
	os.chmod(locked, {.Read_User, .Write_User, .Execute_User})
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory(locked) == nil, "could not make locked")
	put(t, fmt.tprintf("%s/a.txt", root), 100)
	put(t, fmt.tprintf("%s/big.bin", locked), 1 << 20)
	testing.expect(t, os.chmod(locked, {}) == nil, "could not lock the directory")
	defer os.chmod(locked, {.Read_User, .Write_User, .Execute_User})

	file := fmt.tprintf("%s.tree", root)
	defer os.remove(file)
	target, choice, err := scan.resolve(root)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)
	if _, has_events := changes.now(root); !has_events {
		log.info("skipped: the volume keeps no change history, so no baseline is kept")
		return
	}

	run  :: proc(t: ^testing.T, target: scan.Target, engine: scan.Engine, file: string) -> Fill {
		tree := new(scan.Tree)
		testing.expect_value(t, scan.tree_init(tree, 2), scan.Error.None)
		f := Fill {
			target = target,
			engine = engine,
			wcfg = {workers = 2},
			tree = tree,
			baseline = file,
		}
		fill_run(&f)
		testing.expectf(t, problem(&f) == "", "the fill failed: %s", problem(&f))
		testing.expect(t, f.saved, "the result was not kept")
		return f
	}
	done :: proc(f: ^Fill) {
		fill_destroy(f)
		scan.tree_destroy(f.tree)
		free(f.tree)
	}

	first := run(t, target, choice.engine, file)
	defer done(&first)
	count, denied := scan.unread(first.tree)
	testing.expect_value(t, count, 1)
	testing.expect(t, denied, "a mode 000 directory was not refused for permission")
	// Spelt as the tree spells it: the temp directory may be reached through a link.
	big := fmt.tprintf("%s/locked/big.bin", scan.location(target, context.temp_allocator))
	testing.expect(t, big not_in seen(first.tree), "a locked directory's file was read")

	testing.expect(
		t,
		os.chmod(locked, {.Read_User, .Write_User, .Execute_User}) == nil,
		"no unlock",
	)
	second := run(t, target, choice.engine, file)
	defer done(&second)
	testing.expectf(t, second.how == .Updated, "read whole again: %s", second.why)
	again, _ := scan.unread(second.tree)
	testing.expect_value(t, again, 0)
	got, found := seen(second.tree)[big]
	testing.expect(t, found, "the update kept the directory empty")
	testing.expectf(t, got.disk >= 1 << 20, "big.bin charged %d", got.disk)
}

/*
A directory whose entries could not be asked about (a mode 0644 directory, which
lists its names but refuses a statx of each) keeps its Unread mark through a
baseline saved and loaded, so the update from that baseline reads the directory
again rather than copying it, and finds the file once it can be asked about.

	<root>/a.txt               100 bytes
	<root>/listing/big.bin     1 MiB, in a mode 0644 directory

Linux only: the macOS reader is not yet held to this. Root asks about anything, so
the test skips there.
*/
@(test)
test_a_baseline_keeps_a_directory_whose_entries_were_not_asked :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		log.info("skipped: only the Linux reader leaves out what statx could not size")
		return
	}
	if posix.geteuid() == 0 {
		log.info("skipped: root can ask about any entry")
		return
	}
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_survey_listing_%d", strings.trim_right(dir, "/"), os.get_pid())
	listing := fmt.tprintf("%s/listing", root)
	searchable := os.Permissions{.Read_User, .Write_User, .Execute_User}
	os.chmod(listing, searchable)
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory(listing) == nil, "could not make listing")
	put(t, fmt.tprintf("%s/a.txt", root), 100)
	put(t, fmt.tprintf("%s/big.bin", listing), 1 << 20)
	testing.expect(
		t,
		os.chmod(listing, {.Read_User, .Write_User, .Read_Group, .Read_Other}) == nil,
		"could not take search off the directory",
	)
	defer os.chmod(listing, searchable)

	first := read_tree(t, root)
	defer scan.tree_destroy(&first)
	count, _ := scan.unread(&first)
	testing.expect_value(t, count, 1)
	big := fmt.tprintf("%s/big.bin", listing)
	testing.expect(t, big not_in seen(&first), "a file statx could not size was recorded")

	file := fmt.tprintf("%s.tree", root)
	defer os.remove(file)
	testing.expect(t, baseline_save(file, root, &first, {}), "the baseline was not kept")
	base: scan.Tree
	_, why, ok := baseline_load(file, root, &base)
	defer scan.tree_destroy(&base)
	testing.expectf(t, ok, "not read back: %s", why)
	kept, found := seen(&base)[listing]
	testing.expect(t, found && .Unread in kept.flags, "the baseline lost the unread mark")

	testing.expect(t, os.chmod(listing, searchable) == nil, "could not give search back")
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
	defer scan.tree_destroy(&tree)
	u := walk.Update {
		base = &base,
	}
	defer delete(u.marks)
	testing.expect_value(t, walk.update(root, &u, &tree, walk.Config{workers = 2}), walk.Error.None)
	again, _ := scan.unread(&tree)
	testing.expect_value(t, again, 0)
	got, charged := seen(&tree)[big]
	testing.expect(t, charged, "the update copied the directory instead of reading it")
	testing.expectf(t, got.disk >= 1 << 20, "big.bin charged %d", got.disk)
}
