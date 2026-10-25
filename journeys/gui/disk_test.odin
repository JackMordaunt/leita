package journeys_gui

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

/*
Disk is the state of the disk a person opens Leita on that the made-up disk
cannot be: a folder with nothing in it, one with a folder Leita may not open,
one whose folder is deleted while the scan reads it; and the made-up disk with
its scan stopped half way. Each but Stopped is a real folder, read by the real
walk.
*/
Disk :: enum {
	Empty,
	Locked,
	Vanishing,
	Stopped,
}

/*
Story: a person whose disk is full opens Leita on it, whatever state it is in.
The window always ends by saying what it read and what it could not: an empty
folder holds nothing, and nothing fails; a folder it may not open is counted,
and the chart says what that leaves short; a folder deleted while it reads does
not fail the scan, and the next scan says exactly what is left; a scan stopped
half way says its chart is incomplete. Each disk in every scenario: light, dark,
the smallest window, and German. The locked folder is not told on Windows, where
the hosted runner's account read it whatever was done to shut it; read_a_disk
says so as a warning.
*/
@(test)
a_disk_is_read_whatever_state_it_is_in :: proc(t: ^testing.T) {
	budget(t, 240)
	for scenario in SCENARIOS {
		for disk in Disk {
			testing.expectf(
				t,
				read_a_disk(t, disk, scenario),
				"%v, %s: the story was told to its end",
				disk,
				scenario.name,
			)
		}
	}
}

// read_a_disk tells the story on disk in scenario: false when it could not be
// told to its end.
read_a_disk :: proc(t: ^testing.T, disk: Disk, scenario: Scenario) -> bool {
	switch disk {
	case .Empty:
		return read_an_empty_folder(t, scenario)
	case .Locked:
		when ODIN_OS == .Windows {
			fmt.eprintfln(
				"::warning title=journey scenario not told::%s: a locked folder is not told on Windows: the hosted runner's administrator read a folder whose access list held only SYSTEM, with its backup privileges off (CI run 40194359084)",
				scenario.name,
			)
			return true
		} else {
			return read_a_folder_with_one_locked(t, scenario)
		}
	case .Vanishing:
		return read_a_folder_that_loses_one(t, scenario)
	case .Stopped:
		return stop_a_scan_half_way(t, scenario)
	}
	return false
}

// An empty folder is read to the end, and every panel says it holds nothing.
read_an_empty_folder :: proc(t: ^testing.T, scenario: Scenario) -> bool {
	root := real_folder(t, "empty")
	defer os.remove_all(root)

	name := filepath.base(root)

	w: Window
	open(&w, t, "empty", REAL, path = root, scenario = scenario)
	defer close(&w)

	testing.expectf(
		t,
		settle(&w, tr(&w, .Done)),
		"the scan of an empty folder ends:\n%s",
		show(&w),
	)
	frames(&w)

	for line in ([]string{fmt.tprintf(`text "%s · 0 B · `, trf(&w, .Count_Items, 0)), fmt.tprintf(`tree "%s" at`, trf(&w, .Chart_Title, 0, tr(&w, .Mode_Sunburst), name, "0 B")), fmt.tprintf(`text "%s"`, trf(&w, .Listing_Summary, 0, "0 B")), fmt.tprintf(`text "%s"`, tr(&w, .Listing_Empty)), fmt.tprintf(`text "%s"`, tr(&w, .Largest_None))}) {
		testing.expectf(
			t,
			strings.contains(said(&w), line),
			"an empty folder says %s:\n%s",
			line,
			show(&w),
		)
	}

	testing.expectf(
		t,
		!strings.contains(said(&w), tr(&w, .Incomplete)),
		"nothing is said to be missing:\n%s",
		show(&w),
	)
	keep(&w, "empty")
	return true
}

// A folder Leita may not open is counted in the status, the chart says it is
// short, and what could be read is read in full.
read_a_folder_with_one_locked :: proc(t: ^testing.T, scenario: Scenario) -> bool {
	root := real_folder(t, "locked")
	defer os.remove_all(root)

	name := filepath.base(root)
	make_folder(t, within(root, "photos"))
	write_file(t, within(root, "photos", "big.raw"), 256 * 1024)
	locked := within(root, "locked")
	make_folder(t, locked)
	write_file(t, within(root, "locked", "secret.dat"), 64 * 1024)
	if !lock(t, locked) {
		return false
	}
	defer unlock(locked)

	w: Window
	open(&w, t, "locked", REAL, path = root, scenario = scenario)
	defer close(&w)

	testing.expectf(t, settle(&w, tr(&w, .Done)), "the scan ends:\n%s", show(&w))
	frames(&w)

	for line in ([]string{fmt.tprintf(`text "%s"`, trf(&w, .Unread_Folders, 1)), fmt.tprintf(`tree "%s, %s" at`, trf(&w, .Chart_Title, 1, tr(&w, .Mode_Sunburst), name, "262.1 kB"), tr(&w, .Incomplete)), fmt.tprintf(`tree item "%s" level 1`, trf(&w, .Chart_Item, "photos", "262.1 kB", "100.0", name)), fmt.tprintf(`text "%s"`, trf(&w, .Listing_Summary, 2, "262.1 kB")), `button "locked" at`, `button "big.raw" at`}) {
		testing.expectf(
			t,
			strings.contains(said(&w), line),
			"the window says %s:\n%s",
			line,
			show(&w),
		)
	}
	keep(&w, "locked")
	return true
}

// Vanish is a folder the walk deletes once it has listed the folder above it.
Vanish :: struct {
	above, doomed: string, // in the heap, for the walk's thread
	done:          bool, // atomic
}

vanish_after_list :: proc(path: string, data: rawptr) {
	v := (^Vanish)(data)
	if sync.atomic_load(&v.done) {
		return
	}
	// The Windows walk names what it lists by the \\?\ form of the root.
	if path != v.above && path != fmt.tprintf(`\\?\%s`, v.above) {
		return
	}
	os.remove_all(v.doomed)
	sync.atomic_store(&v.done, true)
}

/*
A folder deleted after the walk listed it, before it read it, as a build being
cleaned does: the scan still ends Done, never Failed, with the rest read in full;
the folder is said not to have been read, if the walk had not reached it. The
next scan says exactly what is left, and that nothing was missed.
*/
read_a_folder_that_loses_one :: proc(t: ^testing.T, scenario: Scenario) -> bool {
	root := real_folder(t, "vanishing")
	defer os.remove_all(root)

	name := filepath.base(root)
	make_folder(t, within(root, "kept"))
	write_file(t, within(root, "kept", "notes.txt"), 64 * 1024)
	doomed := within(root, "build")
	make_folder(t, doomed)

	for i in 0 ..< 4 {
		dir := within(doomed, fmt.tprintf("part%d", i))
		make_folder(t, dir)
		write_file(t, within(dir, "out.o"), 128 * 1024)
	}

	v := Vanish {
		above  = strings.clone(root),
		doomed = strings.clone(doomed),
	}
	defer delete(v.above)
	defer delete(v.doomed)

	w: Window
	open(
		&w,
		t,
		"vanishing",
		REAL,
		path = root,
		scenario = scenario,
		after_list = vanish_after_list,
		after_list_data = &v,
	)
	defer close(&w)

	testing.expectf(
		t,
		settle(&w, tr(&w, .Done)),
		"the scan ends, though build went:\n%s",
		show(&w),
	)
	testing.expect(t, sync.atomic_load(&v.done), "build was deleted while the scan read")
	frames(&w)
	testing.expectf(
		t,
		!strings.contains(said(&w), tr(&w, .Failed)),
		"the scan did not fail:\n%s",
		show(&w),
	)
	testing.expectf(
		t,
		strings.contains(said(&w), trf(&w, .Chart_Item, "kept", "65.5 kB", "100.0", name)) ||
		strings.contains(said(&w), `tree item "kept, 65.5 kB, `),
		"what was not deleted is read in full:\n%s",
		show(&w),
	)
	keep(&w, "vanished")

	// The next scan, Rescan in the settings menu, reads only what is there.
	testing.expect(t, click(&w, tr(&w, .Settings)))
	frames(&w, 10)
	testing.expectf(t, click_top(&w, tr(&w, .Rescan)), "the menu offers Rescan:\n%s", show(&w))
	frames(&w, 4)
	testing.expectf(
		t,
		settle_said(&w, fmt.tprintf(`text "%s"`, trf(&w, .Listing_Summary, 1, "65.5 kB"))),
		"the rescan says only kept is left:\n%s",
		show(&w),
	)
	testing.expect(t, settle(&w, tr(&w, .Done)))
	frames(&w)

	for line in ([]string{fmt.tprintf(`text "%s · 65.5 kB · `, trf(&w, .Count_Items, 2)), fmt.tprintf(`tree "%s" at`, trf(&w, .Chart_Title, 1, tr(&w, .Mode_Sunburst), name, "65.5 kB"))}) {
		testing.expectf(
			t,
			strings.contains(said(&w), line),
			"the rescan says %s:\n%s",
			line,
			show(&w),
		)
	}

	testing.expectf(
		t,
		!strings.contains(said(&w), `button "build"`) &&
		!strings.contains(said(&w), trf(&w, .Unread_Folders, 1)),
		"build is gone, and nothing is said to be unread:\n%s",
		show(&w),
	)
	keep(&w, "rescanned")
	return true
}

// The made-up disk's scan, stopped from the settings menu while it reads, says
// it was stopped and that its chart is incomplete.
stop_a_scan_half_way :: proc(t: ^testing.T, scenario: Scenario) -> bool {
	w: Window
	open(&w, t, "stopped", 0, scenario = scenario)
	defer close(&w)

	// A second of the walk's nine.
	deadline := time.tick_now()._nsec + i64(time.Second)
	for time.tick_now()._nsec < deadline {
		frames(&w, 1)
		time.sleep(10 * time.Millisecond)
	}

	testing.expect(t, click(&w, tr(&w, .Settings)))
	frames(&w, 10)
	testing.expectf(
		t,
		click_top(&w, tr(&w, .Stop)),
		"while it reads, the menu offers Stop:\n%s",
		show(&w),
	)
	testing.expectf(t, settle(&w, tr(&w, .Stopped)), "the scan stops:\n%s", show(&w))
	frames(&w)

	for line in ([]string{fmt.tprintf(`text "%s"`, tr(&w, .Stopped_Incomplete)), fmt.tprintf(`, %s" at`, tr(&w, .Incomplete))}) {
		testing.expectf(
			t,
			strings.contains(said(&w), line),
			"the stopped scan says %s:\n%s",
			line,
			show(&w),
		)
	}

	testing.expectf(
		t,
		!strings.contains(said(&w), `text "806,693 items · `),
		"it stopped short of the whole disk:\n%s",
		show(&w),
	)
	keep(&w, "stopped")
	return true
}

/*
lock shuts the folder at path to the user the test runs as by clearing its
mode. false, and a failure, when the user can still list it, as root can.
*/
lock :: proc(t: ^testing.T, path: string) -> bool {
	testing.expect(t, os.chmod(path, {}) == nil, "could not shut the folder")

	if dir, err := os.open(path); err == nil {
		defer os.close(dir)

		if _, read_err := os.read_dir(dir, -1, context.temp_allocator); read_err == nil {
			unlock(path)
			testing.expectf(t, false, "%s is listed whatever its mode says", path)
			return false
		}
	}
	return true
}

// unlock lets the user in to the folder lock shut, so it can be removed.
unlock :: proc(path: string) {
	_ = os.chmod(path, {.Read_User, .Write_User, .Execute_User})
}
