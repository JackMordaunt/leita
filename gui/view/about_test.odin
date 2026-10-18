package leita_view

import "core:fmt"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../../version"
import "../notices"

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
