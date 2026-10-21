package leita_view

import "core:fmt"
import "core:strings"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../../version"
import "../command"
import "../notices"
import "../query"

@(private = "file")
about_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	m := (^Model)(user)
	scheme := primer.theme_scheme(.Light)
	primer.use(&scheme, .Light)
	defer primer.use(nil) // scheme is this frame's own
	primer.use_fonts(FONTS)
	if ui.row(gtx, gap = 8) {
		settings_menu(gtx, m, nil)
	}
	about_dialog(gtx, m)
	notices_dialog(gtx, m)
}

// About in the settings menu opens About, which names the product, its version,
// its maker and the year of the build, and links to its page; Close closes it.
@(test)
about_names_the_product_and_its_maker :: proc(t: ^testing.T) {
	m: Model
	defer model_destroy(&m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, about_frame, &m, {900, 700}, fonts)
	defer render.headless_destroy(&h)

	copyright := fmt.tprintf("© %d %s", version.YEAR, BUSINESS)
	testing.expect(t, !ui.probe_tagged(&h.p, copyright), "closed to begin with")
	testing.expect(t, choose(&h.p, &m, "About Leita"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, m.about_open)
	testing.expect(t, ui.probe_tagged(&h.p, copyright), "the maker and the year")
	testing.expect(t, ui.probe_tagged(&h.p, "mordaunt.dev/leita"), "the product's page")
	testing.expect(t, ui.probe_click_top(&h.p, "Close"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, !m.about_open, "Close closed it")
}

// About's licences link opens, in its place, every component's notice from the
// copies in the binary; Close closes it.
@(test)
about_opens_the_licences_of_what_leita_is_built_on :: proc(t: ^testing.T) {
	m: Model
	defer model_destroy(&m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, about_frame, &m, {900, 700}, fonts)
	defer render.headless_destroy(&h)

	testing.expect(t, choose(&h.p, &m, "About Leita"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, ui.probe_click_top(&h.p, "Open-source licences"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, !m.about_open, "the licences took About's place")
	testing.expect(t, m.notices_open)
	for n in notices.ALL {
		testing.expectf(t, ui.probe_tagged(&h.p, n.name), "%s is listed", n.name)
		testing.expectf(t, len(n.text) > 0, "%s has its notice", n.name)
	}
	// WINDOWS is in the binary on every OS so THIRD_PARTY.md can name it.
	// The dialog shows it only where this build links those libraries.
	// "zlib" also occurs in kb_text_shape's notice, so the url is the mark.
	when ODIN_OS == .Windows {
		testing.expect(t, ui.probe_tagged(&h.p, "Mbed TLS"))
		testing.expect(t, ui.probe_tagged(&h.p, "https://zlib.net"))
	} else {
		testing.expect(t, !ui.probe_tagged(&h.p, "Mbed TLS"), "Mbed TLS stays off this build")
		testing.expect(t, !ui.probe_tagged(&h.p, "https://zlib.net"), "zlib stays off this build")
	}
	testing.expect(t, ui.probe_tagged(&h.p, notices.ALL[0].text), "a notice is shown whole")
	testing.expect(t, ui.probe_click_top(&h.p, "Close"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, !m.notices_open, "Close closed it")
}

// About checks for updates only when asked: opening it sends nothing; Check
// for updates sends Check_Update; and what the host found is shown, with Update
// where this copy can be replaced in place and Download, the release page,
// where it cannot.
@(test)
about_checks_for_updates_on_request_and_shows_the_result :: proc(t: ^testing.T) {
	m: Model
	defer model_destroy(&m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, about_frame, &m, {900, 700}, fonts)
	defer render.headless_destroy(&h)

	PAGE :: "https://example.test/releases/latest"
	testing.expect(t, choose(&h.p, &m, "About Leita"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&h.p, "Check for updates"), "the button is there")
	testing.expect(t, sent(&h.p, command.Check_Update) == nil, "opening About checks nothing")
	testing.expect(
		t,
		!ui.probe_tagged(&h.p, "This is the latest version of Leita."),
		"and says nothing of a check",
	)
	testing.expect(
		t,
		ui.probe_tagged(
			&h.p,
			"Checks stay off until you turn them on. A check asks GitHub for the public release only. Nothing about you or your disks is sent, and Leita never installs a release by itself.",
		),
	)
	testing.expect(
		t,
		ui.probe_tagged(&h.p, "Check for updates automatically"),
		"automatic checks are offered, off until chosen",
	)
	testing.expect(t, sent(&h.p, command.Automatic_Checks) == nil, "opening About does not opt in")
	testing.expect(t, ui.probe_click_top(&h.p, "Check for updates automatically"))
	if got, ok := sent(&h.p, command.Automatic_Checks).?;
	   testing.expect(t, ok, "the checkbox opts in") {
		testing.expect(t, got.on)
	}

	testing.expect(t, ui.probe_click_top(&h.p, "Check for updates"))
	testing.expect(t, sent(&h.p, command.Check_Update) != nil, "the click asks the host to check")
	if auto, ok := sent(&h.p, command.Automatic_Checks).?; ok {
		testing.expect(t, !auto.on, "the manual check does not turn automatic checks on")
	}

	// A check under way cannot be started again.
	ui.probe_deliver(&h.p, query.Update{}, query.Update_Result{state = .Checking, page = PAGE})
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&h.p, "Checking for updates…"))

	ui.probe_deliver(
		&h.p,
		query.Update{},
		query.Update_Result{state = .Current, latest = "v1.0.0", page = PAGE},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(&h.p, "This is the latest version of Leita."),
		"current is said",
	)
	testing.expect(t, !ui.probe_tagged(&h.p, "Update"), "and offers no update")

	// Newer, and this copy can be replaced: Update runs the update.
	ui.probe_deliver(
		&h.p,
		query.Update{},
		query.Update_Result{state = .Available, latest = "v9.9.9", can_apply = true, page = PAGE},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(&h.p, "Version v9.9.9 of Leita is available."),
		"the newer version is named",
	)
	testing.expect(t, !ui.probe_tagged(&h.p, "Download the update"))
	testing.expect(t, ui.probe_click_top(&h.p, "Update"))
	testing.expect(
		t,
		sent(&h.p, command.Apply_Update) != nil,
		"Update asks the host to replace this copy",
	)

	// Newer, and this copy is not Leita's to replace: Download opens the page.
	ui.probe_deliver(
		&h.p,
		query.Update{},
		query.Update_Result{state = .Available, latest = "v9.9.9", page = PAGE},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&h.p, "Version v9.9.9 of Leita is available."))
	testing.expect(
		t,
		!ui.probe_tagged(&h.p, "Update"),
		"no Update button for a copy that cannot be replaced",
	)
	testing.expect_value(t, ui.probe_opened_url(&h.p), "")
	testing.expect(t, ui.probe_click_top(&h.p, "Download the update"))
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect_value(t, ui.probe_opened_url(&h.p), PAGE)

	ui.probe_deliver(
		&h.p,
		query.Update{},
		query.Update_Result{state = .Applied, latest = "v9.9.9", page = PAGE},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&h.p, "Updated. Restart Leita to use the new version."))

	ui.probe_deliver(
		&h.p,
		query.Update{},
		query.Update_Result{state = .Failed, problem = .No_Library, page = PAGE},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(
			&h.p,
			"Leita needs libcurl to check for updates, and this system has none. Install the curl package, or download the update from the release page.",
		),
	)

	ui.probe_deliver(
		&h.p,
		query.Update{},
		query.Update_Result {
			state = .Failed,
			problem = .Other,
			detail = "cannot move the file aside",
			page = PAGE,
		},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(&h.p, "The update failed: cannot move the file aside"),
		"an error the window has no words for is said as it was",
	)
}

@(private = "file")
checks_box_line :: proc(p: ^ui.Probe) -> string {
	said := ui.probe_semantics(p, context.temp_allocator)
	mark := `checkbox "Check for updates automatically"`
	at := strings.index(said, mark)
	if at < 0 {
		return ""
	}
	rest := said[at:]
	if nl := strings.index(rest, "\n"); nl >= 0 {
		return rest[:nl]
	}
	return rest
}

// The checkbox shows the click at once. A host answer that could not save
// the choice clears that, leaves the box off, and says checks are off for
// this session. It does not say the click was kept.
@(test)
a_failed_update_choice_clears_the_optimistic_checkbox :: proc(t: ^testing.T) {
	m: Model
	defer model_destroy(&m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, about_frame, &m, {900, 700}, fonts)
	defer render.headless_destroy(&h)

	warning := fmt.tprintf(
		"Automatic checks are off for this session. The choice could not be saved. The saved choice applies the next time %s opens.",
		version.PRODUCT,
	)
	testing.expect(t, choose(&h.p, &m, "About Leita"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, !ui.probe_tagged(&h.p, warning), "a saved session shows no warning")
	testing.expect(t, !strings.contains(checks_box_line(&h.p), " checked"), "the box starts off")

	testing.expect(t, ui.probe_click_top(&h.p, "Check for updates automatically"))
	if got, ok := sent(&h.p, command.Automatic_Checks).?;
	   testing.expect(t, ok, "the click asks to opt in") {
		testing.expect(t, got.on)
	}
	want, optimistic := m.checks_want.?
	testing.expect(t, optimistic && want, "the box is optimistic on until the host answers")
	testing.expect(t, strings.contains(checks_box_line(&h.p), " checked"), "the click shows on")

	ui.probe_deliver(
		&h.p,
		query.Settings{},
		query.Settings_Result{automatic_checks = false, automatic_checks_unsaved = true},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	_, still := m.checks_want.?
	testing.expect(t, !still, "the failed answer drops the optimistic box")
	testing.expect(t, !strings.contains(checks_box_line(&h.p), " checked"), "the box resolves off")
	testing.expect(
		t,
		ui.probe_tagged(&h.p, warning),
		"the warning says checks are off this session",
	)
}

// About names the free boundary: once the Pro evaluation has ended, scanning
// and a current-scan export stay free; while it runs, the line says so.
@(test)
about_says_disk_work_stays_free :: proc(t: ^testing.T) {
	m: Model
	defer model_destroy(&m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, about_frame, &m, {900, 700}, fonts)
	defer render.headless_destroy(&h)

	testing.expect(t, choose(&h.p, &m, "About Leita"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	ui.probe_deliver(&h.p, query.Licence{}, query.Licence_Result{unlocked = false})
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(&h.p, "Free to scan, chart, search, clean up and export this scan."),
		"after the evaluation, disk work stays free",
	)
	testing.expect(
		t,
		!ui.probe_tagged(&h.p, "You can try Pro"),
		"and the evaluation is not still running",
	)

	ui.probe_deliver(&h.p, query.Licence{}, query.Licence_Result{unlocked = true, trial_left = 12})
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(
			&h.p,
			"Free to scan, chart, search, clean up and export this scan. You can try Pro for 12 more days.",
		),
		"the evaluation is named on the same line",
	)
	testing.expect(
		t,
		!ui.probe_tagged(&h.p, "Free to scan, chart, search, clean up and export this scan."),
		"the ended line is replaced while the evaluation runs",
	)
}

@(private = "file")
notice_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	scheme := primer.theme_scheme(.Light)
	primer.use(&scheme, .Light)
	defer primer.use(nil)
	primer.use_fonts(FONTS)
	update_notice(gtx)
	_ = user
}

// A release outside the paid-through date is explained and downloaded, not
// installed. Dismissing the banner names that version.
@(test)
a_release_after_paid_through_is_explained_and_not_installed :: proc(t: ^testing.T) {
	m: Model
	defer model_destroy(&m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, notice_frame, &m, {900, 700}, fonts)
	defer render.headless_destroy(&h)

	PAGE :: "https://example.test/releases/latest"
	ui.probe_deliver(
		&h.p,
		query.Update{},
		query.Update_Result {
			state = .Available,
			latest = "v9",
			can_apply = true,
			page = PAGE,
			notice = true,
			coverage = .Later,
			paid_through = "2026-10-19T00:00:00Z",
			released = "2026-10-19T00:00:01Z",
		},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&h.p, "Version v9 of Leita is available."))
	testing.expect(
		t,
		ui.probe_tagged(
			&h.p,
			"Leita stays Pro through 2026-10-19T00:00:00Z. Version v9 was released 2026-10-19T00:00:01Z, which is after that, so it was not installed.",
		),
	)
	testing.expect(t, !ui.probe_tagged(&h.p, "Update"), "the banner does not install it")
	testing.expect_value(t, ui.probe_opened_url(&h.p), "")
	testing.expect(t, ui.probe_click_top(&h.p, "Download the update"))
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect_value(t, ui.probe_opened_url(&h.p), PAGE)
	testing.expect(t, sent(&h.p, command.Apply_Update) == nil)

	testing.expect(t, ui.probe_click_top(&h.p, "Dismiss banner"))
	if got, ok := sent(&h.p, command.Dismiss_Update).?;
	   testing.expect(t, ok, "dismiss names the version") {
		testing.expect_value(t, command.text_of(&got.version), "v9")
	}
}
