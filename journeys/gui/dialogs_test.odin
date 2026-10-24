package journeys_gui

import "core:strings"
import "core:testing"

import "jm:ui"

// Each dialog of the settings menu opens with the keyboard in it, says what it
// is for, and closes on Escape with the focus given back. About says the build
// and the evaluation's days; the licence dialog offers Buy; the language chosen
// is the window's at once.
@(test)
every_dialog_opens_says_what_it_is_and_closes :: proc(t: ^testing.T) {
	budget(t, 120)
	w: Window
	open(&w, t, "dialogs", 0)
	defer close(&w)

	testing.expect(t, settle(&w, "Done"))

	Dialog :: struct {
		item, title, says: string,
	}
	dialogs := []Dialog {
		{"About Leita", `dialog "About Leita" modal`, `text "Version `},
		{"Licence", `dialog "Licence" modal`, `text "You can try Pro for 30 more days."`},
		{"Monitoring", `dialog "Monitoring" modal`, `text "No place is watched yet."`},
		{
			"History",
			`dialog "History" modal`,
			`text "Nothing has been deleted, moved to the Trash or renamed yet.`,
		},
	}
	for d in dialogs {
		testing.expect(t, click(&w, "Settings"))
		frames(&w, 10)
		testing.expectf(t, click_top(&w, d.item), "the menu offers %s:\n%s", d.item, show(&w))
		frames(&w, 20)
		testing.expectf(
			t,
			settle_said(&w, d.title, seconds = 10) && settle_said(&w, d.says, seconds = 10),
			"%s opened and says %s:\n%s",
			d.item,
			d.says,
			show(&w),
		)
		testing.expectf(
			t,
			strings.contains(said(&w), `button "Close" focused`),
			"%s holds the keyboard:\n%s",
			d.item,
			show(&w),
		)
		keep(&w, d.item)
		ui.probe_key(&w.p, .Escape)
		frames(&w, 20)
		testing.expectf(
			t,
			!strings.contains(said(&w), d.title),
			"Escape closed %s:\n%s",
			d.item,
			show(&w),
		)
		testing.expectf(
			t,
			strings.contains(said(&w), `button "Settings" expandable focused`),
			"the keyboard is back on the menu %s came from:\n%s",
			d.item,
			show(&w),
		)
	}

	// Deutsch, chosen in the menu, is the window's language the next frame.
	testing.expect(t, click(&w, "Settings"))
	frames(&w, 10)
	testing.expect(t, click_top(&w, "Language"))
	frames(&w, 20)
	testing.expect(t, ui.probe_tagged(&w.p, "日本語"), "each language by its own name")
	testing.expect(t, click_top(&w, "Deutsch"))
	frames(&w, 4)
	testing.expectf(t, settle(&w, "Fertig"), "the window speaks German:\n%s", show(&w))
	keep(&w, "deutsch")
}
