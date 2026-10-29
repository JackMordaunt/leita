package leita_view

import "core:strings"
import "core:testing"

import "jm:i18n"
import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../command"
import "../query"

// choose opens the settings menu, unless it is open, and chooses item in it.
@(private)
choose :: proc(p: ^ui.Probe, m: ^Model, item: string) -> bool {
	if !m.settings_open {
		ui.probe_frame(p)
		if !ui.probe_click(p, "Settings") {
			return false
		}
		ui.probe_advance(p, 10, 1.0 / 60)
	}
	return ui.probe_click_top(p, item)
}

@(private = "file")
Settings_Case :: struct {
	m:    Model,
	prog: query.Progress_Result,
}

@(private = "file")
settings_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	c := (^Settings_Case)(user)
	scheme := primer.theme_scheme(.Light)
	primer.use(&scheme, .Light)
	defer primer.use(nil) // scheme is this frame's own
	primer.use_fonts(FONTS)
	if ui.row(gtx, gap = 8) {
		settings_menu(gtx, &c.m, &c.prog)
	}
	about_dialog(gtx, &c.m)
}

// Rescan's shortcut is written in words off macOS: Linux's default face has no
// glyph for the Ctrl key cap the hint would draw.
@(test)
rescan_says_its_shortcut_in_letters_the_font_has :: proc(t: ^testing.T) {
	c: Settings_Case
	c.prog = {generation = 1, state = .Done, target = "/data"}
	defer model_destroy(&c.m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, settings_frame, &c, {800, 600}, fonts)
	defer render.headless_destroy(&h)
	p := &h.p
	testing.expect(t, ui.probe_click(p, "Settings"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(p, "Rescan"), "the menu is open")
	// The words are read with Rescan; macOS keeps its key caps.
	said := ui.probe_semantics(p, context.temp_allocator)
	testing.expect(t, strings.contains(said, "Ctrl+R") == (ODIN_OS != .Darwin), said)
}

// An unset choice follows the OS. Light and dark stay where they were set.
@(test)
an_unset_theme_follows_the_os :: proc(t: ^testing.T) {
	m: Model
	apply_theme(&m)
	testing.expect_value(t, m.dark, system_dark())
	m.theme = .Light
	apply_theme(&m)
	testing.expect(t, !m.dark)
	m.theme = .Dark
	apply_theme(&m)
	testing.expect(t, m.dark)
	m.theme = .Auto
	apply_theme(&m)
	testing.expect_value(t, m.dark, system_dark())
}

// sent is the last Command of type T the last frame sent, if it sent one.
@(private)
sent :: proc(p: ^ui.Probe, $T: typeid) -> (got: Maybe(T)) {
	for cmd in ui.probe_commands(p) {
		if v, ok := ui.command_as(cmd, command.Command); ok {
			if e, is := v.(T); is {
				got = e
			}
		}
	}
	return
}

// The gear's menu holds what the bar did: Stop while a scan runs and Rescan
// after, the theme in a submenu, and the languages in a submenu; a choice
// closes the menu. Auto follows the OS.
@(test)
settings_menu_holds_the_bar_actions :: proc(t: ^testing.T) {
	c: Settings_Case
	c.prog = {generation = 1, state = .Scanning, target = "/data"}
	defer model_destroy(&c.m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, settings_frame, &c, {800, 600}, fonts)
	defer render.headless_destroy(&h)
	p := &h.p

	testing.expect(t, !ui.probe_tagged(p, "Monitoring"), "closed to begin with")
	testing.expect(t, ui.probe_click(p, "Settings"))
	ui.probe_advance(p, 10, 1.0 / 60)
	for item in ([]string{"Export", "Stop", "Monitoring", "Licence", "Language", "Theme", "About Leita"}) {
		testing.expectf(t, ui.probe_tagged(p, item), "the menu has %s", item)
	}
	testing.expect(t, !ui.probe_tagged(p, "Rescan"), "no Rescan while a scan runs")
	testing.expect(t, ui.probe_click_top(p, "Stop"))
	testing.expect(t, sent(p, command.Stop) != nil, "Stop stops the scan")
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, !c.m.settings_open, "a choice closes the menu")

	c.prog.state = .Done
	testing.expect(t, choose(p, &c.m, "Rescan"))
	scan, scanned := sent(p, command.Scan).?
	testing.expect(t, scanned, "Rescan scans again")
	testing.expect_value(t, command.text_of(&scan.path), "/data")

	testing.expect(t, choose(p, &c.m, "Theme"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, c.m.theme_open, "Theme opens its submenu")
	for item in ([]string{"Auto", "Light theme", "Dark theme"}) {
		testing.expectf(t, ui.probe_tagged(p, item), "the theme menu has %s", item)
	}
	testing.expect(t, ui.probe_click_top(p, "Dark theme"))
	testing.expect(t, c.m.dark, "the theme turned dark")
	testing.expect_value(t, c.m.theme, query.Theme_Choice.Dark)
	testing.expect_value(t, sent(p, command.Theme), Maybe(command.Theme)(command.Theme{choice = u8(query.Theme_Choice.Dark)}))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, !c.m.settings_open && !c.m.theme_open, "the choice closed both menus")

	testing.expect(t, choose(p, &c.m, "Theme"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, ui.probe_click_top(p, "Auto"))
	testing.expect_value(t, c.m.theme, query.Theme_Choice.Auto)
	testing.expect(t, c.m.dark == system_dark(), "auto follows the OS")
	testing.expect_value(t, sent(p, command.Theme), Maybe(command.Theme)(command.Theme{choice = u8(query.Theme_Choice.Auto)}))

	testing.expect(t, choose(p, &c.m, "Language"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, c.m.language_open, "Language opens its submenu")
	testing.expect(t, ui.probe_click_top(p, "Deutsch"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect_value(t, c.m.locale, i18n.Locale.German)
	testing.expect(t, !c.m.settings_open && !c.m.language_open, "the choice closed both menus")
}

@(private = "file")
caption_is_dark :: proc(caption: [3]u8) -> bool {
	return caption[0] < 128
}

// The full window tells the platform its appearance on the first frame, and
// again when a light or dark choice, or auto following the OS, changes it.
@(test)
the_window_is_told_when_the_appearance_changes :: proc(t: ^testing.T) {
	m: Model
	model_init(&m, "")
	m.settings_read = true
	defer model_destroy(&m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, view, &m, {1000, 700}, fonts)
	defer render.headless_destroy(&h)
	p := &h.p

	dark, caption, set := ui.probe_window_theme(p)
	testing.expect(t, set && dark == system_dark(), "the first frame tells the OS appearance")
	testing.expect(t, caption_is_dark(caption) == system_dark(), "the caption is that page")

	pin_theme(&m, !system_dark())
	ui.probe_frame(p)
	dark, caption, set = ui.probe_window_theme(p)
	testing.expect(t, set && dark == !system_dark(), "an explicit choice overrides the OS")
	testing.expect(t, caption_is_dark(caption) == dark, "the caption follows the choice")

	m.theme = .Auto
	ui.probe_frame(p)
	dark, caption, set = ui.probe_window_theme(p)
	testing.expect(t, set && dark == system_dark(), "auto follows the OS again")
	testing.expect(t, caption_is_dark(caption) == system_dark(), "the caption follows the OS")

	// The choice lands during the frame, after the caption was told. The
	// next frame tells the page it draws.
	testing.expect(t, choose(p, &m, "Theme"))
	ui.probe_advance(p, 10, 1.0 / 60)
	pick := "Dark theme" if !system_dark() else "Light theme"
	testing.expect(t, ui.probe_click_top(p, pick))
	ui.probe_frame(p)
	dark, caption, set = ui.probe_window_theme(p)
	testing.expect(t, set && dark == !system_dark(), "a menu choice is told with the frame that draws it")
	testing.expect(t, caption_is_dark(caption) == dark, "the caption is that page")
}

// A dialog chosen from the menu takes the focus, though the menu gives it back
// to the gear as it closes, and gives it back to the gear in turn.
@(test)
a_dialog_from_the_settings_menu_keeps_the_focus :: proc(t: ^testing.T) {
	c: Settings_Case
	defer model_destroy(&c.m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, settings_frame, &c, {800, 600}, fonts)
	defer render.headless_destroy(&h)
	p := &h.p

	testing.expect(t, choose(p, &c.m, "About Leita"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, c.m.about_open)
	said := ui.probe_semantics(p, context.temp_allocator)
	testing.expectf(t, strings.contains(said, `button "Close" focused`), "the dialog has the focus:\n%s", said)
	ui.probe_key(p, .Escape)
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, !c.m.about_open, "Escape closed it")
	said = ui.probe_semantics(p, context.temp_allocator)
	testing.expectf(t, strings.contains(said, `button "Settings" expandable focused`), "back to the gear:\n%s", said)
}
