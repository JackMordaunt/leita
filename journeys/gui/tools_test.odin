package journeys_gui

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:ui"

// Story: a person searches for a file by name, reads where it is and how big,
// and opens it; a made-up disk's file is not there to open, and the window
// says so.
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

/*
Story: a developer frees space. Reclaim offers what a project's tools make
again, sized, chosen by age; they unchoose one, and the clean up is refused on a
made-up disk. On a real folder of projects, in every scenario, it deletes what
was chosen, says so, and leaves each project's own files and what it did not
offer.
*/
@(test)
reclaim_offers_what_rebuilds_and_cleans_only_a_real_disk :: proc(t: ^testing.T) {
	budget(t, 180)
	offer_on_the_made_up_disk(t)
	for scenario in SCENARIOS {
		testing.expectf(
			t,
			clean_real_projects(t, scenario),
			"%s: the story was told to its end",
			scenario.name,
		)
	}
}

offer_on_the_made_up_disk :: proc(t: ^testing.T) {
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

/*
clean_real_projects scans a real folder of three: web, whose node_modules sits
beside package.json and was last touched a month ago; rust, whose target beside
Cargo.toml, tagged as a cache, was built today; and plain, whose build folder belongs to no project.
*/
clean_real_projects :: proc(t: ^testing.T, scenario: Scenario) -> bool {
	root := real_folder(t, "projects")
	defer os.remove_all(root)

	for d in ([][]string{{"web"}, {"web", "node_modules"}, {"web", "node_modules", "lib"}, {"rust"}, {"rust", "target"}, {"plain"}, {"plain", "build"}}) {
		make_folder(t, within(root, ..d))
	}
	write_file(t, within(root, "web", "package.json"), 2)
	write_file(t, within(root, "web", "node_modules", "lib", "index.js"), 64 * 1024)
	write_file(t, within(root, "rust", "Cargo.toml"), 2)
	write_file(t, within(root, "rust", "target", "app"), 128 * 1024)
	write_file(t, within(root, "rust", "target", "CACHEDIR.TAG"), 4 * 1024)
	write_file(t, within(root, "plain", "build", "out.o"), 32 * 1024)
	age(t, within(root, "web", "node_modules"), 30)
	modules := within("web", "node_modules")
	target := within("rust", "target")

	w: Window
	open(&w, t, "projects", REAL, path = root, scenario = scenario)
	defer close(&w)

	testing.expect(t, settle(&w, tr(&w, .Done)))
	testing.expect(t, click(&w, tr(&w, .Mode_Reclaim)))
	testing.expectf(
		t,
		settle(&w, trf(&w, .Reclaim_Chosen, 1, "65.5 kB")),
		"node_modules starts chosen, the target built today does not:\n%s",
		show(&w),
	)
	said_now := said(&w)
	for line in ([]string{fmt.tprintf(`checkbox "%s" desc "`, modules), fmt.tprintf(`checkbox "%s" desc "`, target)}) {
		testing.expectf(
			t,
			strings.contains(said_now, line),
			"Reclaim offers %s:\n%s",
			line,
			said_now,
		)
	}
	testing.expectf(
		t,
		!strings.contains(said_now, fmt.tprintf(`checkbox "%s"`, within("plain", "build"))),
		"a build folder of no project is not offered:\n%s",
		said_now,
	)
	keep(&w, "offered")

	testing.expect(t, click(&w, tr(&w, .Clean_Up)))
	frames(&w, 4)
	testing.expectf(t, click_top(&w, tr(&w, .Delete)), "the dialog asks first:\n%s", show(&w))
	testing.expectf(
		t,
		settle(&w, trf(&w, .Cleaned, 1)),
		"the window says what it deleted:\n%s",
		show(&w),
	)
	testing.expect(t, settle(&w, modules, present = false), "node_modules leaves the list")
	keep(&w, "cleaned")
	testing.expect(t, !os.exists(within(root, "web", "node_modules")), "and the disk")
	testing.expect(t, os.exists(within(root, "web", "package.json")), "its project stays")
	testing.expect(t, os.exists(within(root, "rust", "target", "app")), "the unchosen stays")
	testing.expect(t, os.exists(within(root, "plain", "build", "out.o")), "the unoffered stays")
	return true
}

// age sets the times of path and what it holds to days ago.
age :: proc(t: ^testing.T, path: string, days: int) {
	then := time.time_add(time.now(), -time.Duration(days) * 24 * time.Hour)
	testing.expectf(t, os.change_times(path, then, then) == nil, "could not age %s", path)
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	testing.expect(t, err == nil)
	for e in entries {
		testing.expect(t, os.change_times(e.fullpath, then, then) == nil)
	}
}

/*
Story: a technician hands a client a report of their disk before and after.
The settings menu's Export writes the first scan up where they choose, with the
made-up disk's exact totals. Days later the same place is opened again: the
window says what grew since the scan before, from the history it kept, and the
second report holds that comparison.
*/
@(test)
a_technician_reports_a_disk_before_and_after :: proc(t: ^testing.T) {
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

		before, ok := export_json(t, &w, "before.json")
		if !ok {
			return
		}
		totals, _ := before["totals"].(json.Object)
		bytes, _ := totals["bytes"].(json.Integer)
		files, _ := totals["files"].(json.Integer)
		testing.expect_value(t, bytes, 320838590464)
		testing.expect_value(t, files, 778414)
		target, _ := before["target"].(json.Object)
		engine, _ := target["engine"].(json.String)
		testing.expect_value(t, engine, "synthetic")
		_, compared := before["compared"].(json.Object)
		testing.expect(t, !compared, "the first report compares with nothing")
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

	after, ok := export_json(t, &w, "after.json")
	if !ok {
		return
	}
	totals, _ := after["totals"].(json.Object)
	now, _ := totals["bytes"].(json.Integer)
	compared, has := after["compared"].(json.Object)
	if !testing.expect(t, has, "the second report compares with the first scan") {
		return
	}
	was, _ := compared["bytes"].(json.Integer)
	taken, _ := compared["taken"].(json.String)
	testing.expect_value(t, was, 320838590464)
	testing.expectf(t, now > was, "it grew: %d after %d", now, was)
	testing.expect(t, strings.has_prefix(taken, "20"), "it says when the first was taken")
}

/*
export_json exports the scan as JSON through the settings menu's Export and the
save dialog, answered with name in the window's data folder, and reads the
report back.
*/
export_json :: proc(t: ^testing.T, w: ^Window, name: string) -> (report: json.Object, ok: bool) {
	testing.expect(t, click(w, "Settings"))
	testing.expect(t, click_top(w, "Export"), "the menu offers Export")
	frames(w, 10)
	testing.expectf(
		t,
		strings.contains(said(w), `heading "Export report"`),
		"the dialog opened:\n%s",
		show(w),
	)
	testing.expect(t, click(w, "JSON"))
	keep(w, "dialog")
	testing.expect(t, click_top(w, "Export"), "the dialog's Export")
	q, asked := ui.probe_picking(&w.p)
	testing.expect(t, asked, "the save dialog opened")
	testing.expect_value(t, q.kind, ui.Pick_Kind.Save)
	testing.expectf(t, strings.has_suffix(q.name, ".json"), "%s is a JSON name", q.name)

	chosen := fmt.tprintf("%s/%s", w.dir, name)
	testing.expect(t, ui.probe_pick(&w.p, chosen))
	frames(w, 2)
	testing.expectf(
		t,
		settle(w, fmt.tprintf("Saved report to %s", chosen)),
		"the notice names the file:\n%s",
		show(w),
	)
	keep(w, "saved")
	// The notice times out, so the next one is not mistaken for it.
	ui.probe_advance(&w.p, 400, 1.0 / 60)

	data, err := os.read_entire_file(chosen, context.temp_allocator)
	if !testing.expect(t, err == nil, "the report is where it was put") {
		return
	}
	v, jerr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	testing.expect_value(t, jerr, json.Error.None)
	report, ok = v.(json.Object)
	return
}
