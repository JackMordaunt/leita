package journeys_gui

import "core:fmt"
import "core:strings"
import "core:testing"

import "jm:ui"

/*
Story: a person whose disk is filling opens Leita and reads what fills it. Each
chart says the same top layer, with the made-up disk's exact sizes, and so do
the Contents and the Largest files beside it; coloured by type, each entry says
its kind. In every scenario: light, dark, and the smallest window.
*/
//review:ignore test-no-assertion read_what_fills_the_disk asserts, once per scenario
@(test)
a_scan_is_said_the_same_in_every_chart :: proc(t: ^testing.T) {
	budget(t, 240)
	for scenario in SCENARIOS {
		read_what_fills_the_disk(t, scenario)
	}
}

read_what_fills_the_disk :: proc(t: ^testing.T, scenario: Scenario) {
	w: Window
	open(&w, t, "charts", 0, scenario = scenario)
	defer close(&w)

	testing.expect(t, settle(&w, "Done"), "the scan of the made-up disk finished")
	frames(&w)
	testing.expectf(
		t,
		strings.contains(
			said(&w),
			`text "806,693 items · 320.8 GB · 151.0 GB free of 494.4 GB · `,
		),
		"the status names the disk:\n%s",
		show(&w),
	)
	testing.expectf(
		t,
		strings.contains(said(&w), `text "320.8 GB in 17 items"`),
		"Contents totals the top:\n%s",
		show(&w),
	)
	testing.expectf(
		t,
		strings.contains(said(&w), `button "Docker.raw" at`) &&
		strings.contains(said(&w), `text "32.7 GB"`) &&
		strings.contains(
			said(&w),
			`desc "/Users/alex/Users/alex/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"`,
		),
		"the largest file is Docker.raw, 32.7 GB, at its path as the Mac writes it:\n%s",
		show(&w),
	)
	keep(&w, "sunburst")

	for chart in ([?]string{"Sunburst", "Treemap", "Icicle"}) {
		if chart != "Sunburst" {
			testing.expect(t, click(&w, chart))
			frames(&w)
			keep(&w, chart)
		}
		tree := fmt.tprintf(`tree "%s of alex, 320.8 GB, 7 items" at`, chart)
		users := `  tree item "Users, 206.0 GB, 64.2% of alex" level 1 expandable at`
		system := `  tree item "System, 40.0 GB, 12.5% of alex" level 1 expandable at`
		testing.expectf(
			t,
			said_after(said(&w), tree, users, system),
			"the %s says its top layer:\n%s",
			chart,
			show(&w),
		)
	}

	// Coloured by type, each entry says its kind as well.
	testing.expect(t, click(&w, "Type"))
	frames(&w, 3)
	testing.expectf(
		t,
		strings.contains(said(&w), `  tree item "Users, 206.0 GB, 64.2% of alex, Folder" level 1`),
		"Users says it is a folder:\n%s",
		show(&w),
	)
	keep(&w, "by-type")
}

// Story: a person goes into a folder. A screen reader opens one of the chart
// with its expand action, a click on a Contents row opens it in the window, and
// Back goes up again.
@(test)
a_folder_opens_for_a_reader_and_for_a_click :: proc(t: ^testing.T) {
	budget(t, 120)
	w: Window
	open(&w, t, "open", 0)
	defer close(&w)

	testing.expect(t, settle(&w, "Done"))
	frames(&w)

	users := node(&w, "Users, ")
	testing.expect(t, users != 0, "Users is an item of the chart's tree")
	reader_does(&w, .Expand, users)
	// Each item says its share of the whole chart, not of its folder.
	testing.expectf(
		t,
		settle_said(&w, `    tree item "alex, 205.1 GB, 63.9% of alex" level 2`),
		"Users, opened, says what is in it:\n%s",
		show(&w),
	)
	keep(&w, "expanded")
	reader_does(&w, .Collapse, users)
	testing.expect_value(t, node(&w, "alex, 205.1 GB"), 0)

	testing.expect(t, open_row(&w, "Contents", "Users"), "Contents lists Users")
	testing.expectf(
		t,
		settle_said(&w, `navigation "Location" value "/Users/alex/Users"`),
		"the location is Users:\n%s",
		show(&w),
	)
	testing.expectf(
		t,
		settle_said(&w, `tree "Sunburst of Users, 206.0 GB`),
		"the chart is of Users:\n%s",
		show(&w),
	)
	keep(&w, "users")

	ui.probe_key(&w.p, .Browser_Back)
	frames(&w, 2)
	testing.expectf(
		t,
		settle_said(&w, `tree "Sunburst of alex, 320.8 GB, 7 items"`),
		"Back is at the top again:\n%s",
		show(&w),
	)
}

// Story: a person tidies a folder by hand. A right click offers Rename and
// Trash; a made-up disk's files are not on disk, so either is refused, and the
// window says why.
@(test)
a_made_up_file_is_not_renamed_or_trashed :: proc(t: ^testing.T) {
	budget(t, 120)
	w: Window
	open(&w, t, "refuse", 0)
	defer close(&w)

	testing.expect(t, settle(&w, "Done"))
	frames(&w)

	REFUSED :: "Nothing was changed: this disk is made up, so its files are not on disk"
	for item in ([?]string{"Rename", "Trash"}) {
		testing.expect(t, open_row(&w, "Contents", "Library", .Right))
		frames(&w, 2)
		testing.expectf(t, click_top(&w, item), "the row's menu offers %s:\n%s", item, show(&w))
		frames(&w, 4)
		keep(&w, item)
		if item == "Rename" {
			ui.probe_type(&w.p, "Archive")
			ui.probe_key(&w.p, .Enter)
		} else {
			testing.expectf(t, click_top(&w, "Trash"), "the dialog asks first:\n%s", show(&w))
		}
		frames(&w, 2)
		testing.expectf(t, settle(&w, REFUSED), "%s is refused:\n%s", item, show(&w))
		testing.expect(t, settle(&w, "Library"), "Library is still there")
		ui.probe_advance(&w.p, 400, 1.0 / 60) // the notice times out
	}
}

// said_after reports whether report holds each of lines, in order.
said_after :: proc(report: string, lines: ..string) -> bool {
	rest := report
	for line in lines {
		i := strings.index(rest, line)
		if i < 0 {
			return false
		}
		rest = rest[i + len(line):]
	}
	return true
}
