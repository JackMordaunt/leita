#+build windows
package changes

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(private = "file")
fresh :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf(`%s\leita_changes_%s`, strings.trim_right(dir, `\/`), name)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	return root
}

@(private = "file")
put :: proc(t: ^testing.T, path: string, size: int) {
	body := make([]byte, size, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
}

/*
The journal names the directories whose entries changed after the cursor, spelt
from the place as given, and none that did not. The temp directory's own spelling
may be an 8.3 short name, which the journal never uses, so this also shows a
change is spelt back from the place.
*/
@(test)
test_the_journal_names_the_directories_that_changed :: proc(t: ^testing.T) {
	root := fresh(t, "usn")
	defer os.remove_all(root)
	sub := fmt.tprintf(`%s\sub`, root)
	still := fmt.tprintf(`%s\still`, root)
	testing.expect(t, os.make_directory(sub) == nil, "could not make sub")
	testing.expect(t, os.make_directory(still) == nil, "could not make still")
	put(t, fmt.tprintf(`%s\k.txt`, still), 100)

	c, ok := now(root)
	if !testing.expect(t, ok, "no cursor: the temp directory's volume keeps no change journal") {
		return
	}
	put(t, fmt.tprintf(`%s\new.txt`, sub), 5000)
	testing.expect(t, os.make_directory(fmt.tprintf(`%s\fresh`, root)) == nil, "no fresh")

	set, next, err := since(root, c)
	defer change_set_destroy(&set)
	testing.expect_value(t, err, Error.None)
	testing.expectf(t, !set.rescan, "rescan: %s", set.why)
	testing.expectf(t, slice.contains(set.shallow[:], sub), "sub is not named: %v", set.shallow)
	testing.expectf(
		t,
		slice.contains(set.shallow[:], root),
		"the root is not named: %v",
		set.shallow,
	)
	testing.expectf(t, !slice.contains(set.shallow[:], still), "still is named: %v", set.shallow)
	testing.expect_value(t, len(set.deep), 0)
	testing.expect(t, next.position > c.position, "the cursor did not move")

	// Nothing more under the place since: nothing named.
	again, _, again_err := since(root, next)
	defer change_set_destroy(&again)
	testing.expect_value(t, again_err, Error.None)
	testing.expectf(t, !again.rescan, "rescan: %s", again.why)
	testing.expectf(t, len(again.shallow) == 0, "named again: %v", again.shallow)
}

// A cursor from another journal, another volume, or past either end of this
// journal says the place must be scanned whole, and why.
@(test)
test_a_journal_cursor_that_cannot_be_trusted_rescans :: proc(t: ^testing.T) {
	root := fresh(t, "usn_bad")
	defer os.remove_all(root)
	c, ok := now(root)
	if !testing.expect(t, ok, "no cursor: the temp directory's volume keeps no change journal") {
		return
	}
	other_journal := c
	other_journal.journal += 1
	other_volume := c
	other_volume.volume[0] += 1
	other_place := c
	other_place.place[0] += 1
	behind := c
	behind.position = -1
	ahead := c
	ahead.position = max(i64)
	for bad in ([]Cursor{{}, other_journal, other_volume, other_place, behind, ahead}) {
		set, _, err := since(root, bad)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, set.rescan && set.why != "", "%v: no rescan", bad)
	}
}

/*
Another directory renamed onto the place is recorded only against the place's
parent, and what it holds has no record since the cursor: the place's file id
differs, and it is scanned whole.
*/
@(test)
test_a_directory_renamed_onto_the_place_rescans :: proc(t: ^testing.T) {
	root := fresh(t, "usn_renamed")
	other := fresh(t, "usn_renamed_other")
	aside := fmt.tprintf("%s_aside", root)
	os.remove_all(aside)
	defer os.remove_all(root)
	defer os.remove_all(other)
	defer os.remove_all(aside)
	put(t, fmt.tprintf(`%s\old.txt`, other), 100)
	c, ok := now(root)
	if !testing.expect(t, ok, "no cursor: the temp directory's volume keeps no change journal") {
		return
	}
	testing.expect(t, os.rename(root, aside) == nil, "could not move the place aside")
	testing.expect(t, os.rename(other, root) == nil, "could not rename onto the place")
	set, _, err := since(root, c)
	defer change_set_destroy(&set)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, set.why, "another directory is in the place than when it was read")
}

// A whole volume's place is its drive, C:, which must be read as its root, not as
// the current directory on it: a change in the temp directory is named under it.
@(test)
test_a_drive_place_is_its_root :: proc(t: ^testing.T) {
	root := fresh(t, "usn_drive")
	defer os.remove_all(root)
	drive := root[:2]
	c, ok := now(drive)
	if !testing.expect(t, ok, "no cursor for the drive") {
		return
	}
	put(t, fmt.tprintf(`%s\new.txt`, root), 100)
	set, _, err := since(drive, c)
	defer change_set_destroy(&set)
	testing.expect_value(t, err, Error.None)
	testing.expectf(t, !set.rescan, "rescan: %s", set.why)
	named := false
	for p in set.shallow {
		rest, inside := under(drive, p)
		named ||= inside && strings.has_suffix(rest, `leita_changes_usn_drive`)
	}
	testing.expectf(t, named, "the temp directory is not named: %v", set.shallow)
}
