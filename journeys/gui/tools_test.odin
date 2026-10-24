package journeys_gui

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "jm:ui"

// A person searches for a file by name, reads where it is and how big, and
// opens it; a made-up disk's file is not there to open, and the window says so.
@(test)
a_search_finds_a_file_by_name_and_says_where_it_is :: proc(t: ^testing.T) {
	budget(t, 120)
	w: Window
	open(&w, t, "search", 0)
	defer close(&w)

	testing.expect(t, settle(&w, "Done"))

	testing.expect(t, click(&w, "Search"), "the magnifier")
	ui.probe_type(&w.p, "Docker.raw")
	frames(&w, 2)
	hit := `list item "Docker.raw, 32.7 GB, in /Users/alex/Users/alex/Library/Containers/com.docker.docker/Data/vms/0/data" at`
	testing.expectf(t, settle_said(&w, hit), "the hit says its size and folder:\n%s", show(&w))
	testing.expectf(
		t,
		strings.contains(said(&w), `text field "Search" value "Docker.raw" focused`),
		"the field keeps the focus while typing:\n%s",
		show(&w),
	)
	keep(&w, "hit")

	ui.probe_key(&w.p, .Enter)
	frames(&w, 2)
	testing.expectf(
		t,
		settle(&w, "Could not open it: this disk is made up, so its files are not on disk"),
		"the made-up file is not opened:\n%s",
		show(&w),
	)
}

// Reclaim offers what a project's tools make again, sized, chosen by age; a
// person unchooses one, and the clean up is refused on a made-up disk.
@(test)
reclaim_offers_what_rebuilds_and_cleans_only_a_real_disk :: proc(t: ^testing.T) {
	budget(t, 120)
	w: Window
	open(&w, t, "reclaim", 0)
	defer close(&w)

	testing.expect(t, settle(&w, "Done"))

	testing.expect(t, click(&w, "Reclaim"))
	testing.expectf(
		t,
		settle(&w, "6.0 GB in 28 folders chosen"),
		"the offers start chosen but for the recent:\n%s",
		show(&w),
	)
	said_now := said(&w)
	for line in ([]string{`text "6.3 GB charged here. Deleting a folder does not always free that."`, `checkbox "All Installed dependencies" checked`, `checkbox "Users/alex/Source/atlas-web/node_modules" desc "Modified 12 days ago" checked`, `text "1.2 GB"`, `checkbox "Users/alex/Source/orbit/.next" desc "Modified 4 days ago, so likely in use" at`}) {
		testing.expectf(
			t,
			strings.contains(said_now, line),
			"Reclaim says %s:\n%s",
			line,
			said_now,
		)
	}
	keep(&w, "offered")

	testing.expect(t, click(&w, "Users/alex/Source/atlas-web/node_modules"))
	testing.expectf(
		t,
		settle(&w, "4.8 GB in 27 folders chosen"),
		"one unchosen leaves the rest:\n%s",
		show(&w),
	)
	testing.expectf(
		t,
		strings.contains(said(&w), `checkbox "All Installed dependencies" mixed`) ||
		strings.contains(said(&w), `checkbox "All Installed dependencies" at`),
		"the group is no longer all chosen:\n%s",
		show(&w),
	)

	testing.expect(t, click(&w, "Clean up"))
	frames(&w, 4)
	keep(&w, "confirm")
	testing.expectf(t, click_top(&w, "Delete"), "the dialog asks first:\n%s", show(&w))
	testing.expectf(
		t,
		settle(&w, "Nothing was changed: this disk is made up, so its files are not on disk"),
		"the clean up is refused:\n%s",
		show(&w),
	)
	testing.expect(
		t,
		ui.probe_tagged(&w.p, "Users/alex/Source/sketchpad/node_modules"),
		"the offers stay",
	)
}

// Two days apart the same place is opened again, and the window says what grew
// since the scan before, from the history it kept.
@(test)
a_second_day_is_compared_with_the_first :: proc(t: ^testing.T) {
	budget(t, 180)
	dir := folder("compare")
	defer forget(dir)

	{
		w: Window
		open(&w, t, "compare", 0, dir = dir)
		defer close(&w, keep = true)

		testing.expect(t, settle(&w, "Done"))
		testing.expect(t, click(&w, "Change"))
		testing.expectf(
			t,
			settle(
				&w,
				"No earlier scan of this folder yet: the next scan will be compared with this one",
			),
			"the first day has nothing to compare with:\n%s",
			show(&w),
		)
		keep(&w, "first")
	}

	w: Window
	open(&w, t, "compare-day6", 6, dir = dir)
	defer close(&w, keep = true)

	testing.expect(t, settle(&w, "Done"))
	testing.expect(t, click(&w, "Change"))
	frames(&w, 4)
	// Day 6 holds 325.5 GB, 4.6 GB more than day 0's 320.8 GB: Users grew,
	// Applications did not.
	testing.expectf(
		t,
		settle_said(&w, `text "325.5 GB · +4.6 GB since then"`),
		"the total says what it grew by:\n%s",
		show(&w),
	)
	for line in ([]string{`button "Since `, `  tree item "Users, 210.5 GB, 64.7% of alex, +4.5 GB since then" level 1`, `  tree item "Applications, 40.2 GB, 12.4% of alex, unchanged" level 1`, `text "325.5 GB in 17 items · +4.6 GB since then"`}) {
		testing.expectf(
			t,
			strings.contains(said(&w), line),
			"the window says %s:\n%s",
			line,
			show(&w),
		)
	}
	keep(&w, "second")
}

// The settings menu's Export writes the scan up where the person chooses, and
// the report holds the made-up disk's exact totals.
@(test)
a_report_is_exported_where_chosen :: proc(t: ^testing.T) {
	budget(t, 120)
	w: Window
	open(&w, t, "export", 0)
	defer close(&w)

	testing.expect(t, settle(&w, "Done"))

	testing.expect(t, click(&w, "Settings"))
	testing.expect(t, click_top(&w, "Export"), "the menu offers Export")
	frames(&w, 10)
	testing.expectf(
		t,
		strings.contains(said(&w), `heading "Export report"`),
		"the dialog opened:\n%s",
		show(&w),
	)
	testing.expect(t, click(&w, "JSON"))
	keep(&w, "dialog")
	testing.expect(t, click_top(&w, "Export"), "the dialog's Export")
	q, asked := ui.probe_picking(&w.p)
	testing.expect(t, asked, "the save dialog opened")
	testing.expect_value(t, q.kind, ui.Pick_Kind.Save)
	testing.expectf(t, strings.has_suffix(q.name, ".json"), "%s is a JSON name", q.name)

	chosen := fmt.tprintf("%s/mine.json", w.dir)
	testing.expect(t, ui.probe_pick(&w.p, chosen))
	frames(&w, 2)
	testing.expectf(
		t,
		settle(&w, fmt.tprintf("Saved report to %s", chosen)),
		"the notice names the file:\n%s",
		show(&w),
	)
	keep(&w, "saved")

	data, err := os.read_entire_file(chosen, context.temp_allocator)
	if !testing.expect(t, err == nil, "the report is where it was put") {
		return
	}
	v, jerr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	testing.expect_value(t, jerr, json.Error.None)
	top, _ := v.(json.Object)
	totals, _ := top["totals"].(json.Object)
	bytes, _ := totals["bytes"].(json.Integer)
	files, _ := totals["files"].(json.Integer)
	testing.expect_value(t, bytes, 320838590464)
	testing.expect_value(t, files, 778414)
	target, _ := top["target"].(json.Object)
	engine, _ := target["engine"].(json.String)
	testing.expect_value(t, engine, "synthetic")
}
