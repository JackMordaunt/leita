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
	said := ui.probe_semantics(p, context.temp_allocator)
	when ODIN_OS == .Darwin {
		testing.expect(t, strings.contains(said, "Command"), said)
		testing.expect(t, !strings.contains(said, "Ctrl+R"), said)
	} else {
		testing.expect(t, strings.contains(said, "Ctrl+R"), said)
		testing.expect(t, !strings.contains(said, "⌃"), said)
	}
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
// after, the theme, and the languages in a submenu; a choice closes the menu.
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
	for item in ([]string{"Export", "Stop", "Monitoring", "Licence", "Language", "Dark theme", "About Leita"}) {
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

	testing.expect(t, choose(p, &c.m, "Dark theme"))
	testing.expect(t, c.m.dark, "the theme turned dark")
	testing.expect_value(t, sent(p, command.Theme), Maybe(command.Theme)(command.Theme{dark = true}))

	testing.expect(t, choose(p, &c.m, "Language"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, c.m.language_open, "Language opens its submenu")
	testing.expect(t, ui.probe_click_top(p, "Deutsch"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect_value(t, c.m.locale, i18n.Locale.German)
	testing.expect(t, !c.m.settings_open && !c.m.language_open, "the choice closed both menus")
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
