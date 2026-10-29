package leita_view

import "jm:i18n"
import "jm:ui"
import "jm:ui/primer"

import "../../version"
import "../command"
import "../query"

/*
The window opens as the person left it: the language they picked and the theme
they chose, which the host keeps between runs (gui/app/settings.odin). The view
asks once. Until that answer, and when the choice is auto or was never made,
the theme follows the OS (apply_theme). A stored light or dark choice overrides
it, including one pinned before the answer (pin_theme). Each choice is sent to
the host as it is made (language_menu, theme_menu).
*/

// recall_settings puts what the person chose in an earlier run in use, once.
@(private)
recall_settings :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if m.settings_read {
		return
	}
	r, _ := ui.need(gtx, query.Settings{}, query.Settings_Result)
	if r == nil {
		return
	}
	m.settings_read = true
	if r.language != "" {
		if locale, ok := i18n.locale_match(r.language); ok {
			set_language(m, locale)
		}
	}
	// A light or dark choice wins over one pinned for a capture or a story.
	// Auto does not, so that pin is not undone by an absent setting.
	switch r.theme {
	case .Light, .Dark:
		m.theme = r.theme
	case .Auto, .Unset:
		if m.theme != .Light && m.theme != .Dark {
			m.theme = .Auto
		}
	}
}

// tell_window asks the platform to match the appearance this frame draws:
// the caption and the taskbar icon. Call it after apply_theme, before a
// choice in the frame can change m.dark. The first frame asks, and a
// later one when that appearance changes.
@(private)
tell_window :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if gtx.router == nil || (m.told && m.told_dark == m.dark) {
		return
	}
	m.told = true
	m.told_dark = m.dark
	ui.set_window_theme(gtx, m.dark, primer.color(.Bg_Color_Default))
}

// apply_theme resolves the choice into the appearance this frame draws.
// Unset and Auto follow the OS, so a change there shows on a later frame.
@(private)
apply_theme :: proc(m: ^Model) {
	switch m.theme {
	case .Light:
		m.dark = false
	case .Dark:
		m.dark = true
	case .Unset, .Auto:
		m.dark = system_dark()
	}
}

// pin_theme forces light or dark, rather than following the OS.
pin_theme :: proc(m: ^Model, dark: bool) {
	m.theme = .Dark if dark else .Light
	m.dark = dark
}

// set_theme puts choice in use and asks the host to keep it.
@(private)
set_theme :: proc(gtx: ^ui.Ctx, m: ^Model, choice: query.Theme_Choice) {
	m.theme = choice
	apply_theme(m)
	ui.command(gtx, command.Command(command.Theme{choice = u8(choice)}))
}

/*
settings_menu is the gear at the end of the toolbar and the menu it opens, which
holds everything the bar does but search: Export, Stop or Rescan, Monitoring,
History, the licence, the language, the theme and About. Kept in one menu, the
bar is the location and the gear whatever the window's width or the scan's
state.

A choice that opens a dialog waits for the menu to hand focus back to the gear,
which it does the frame after it closes: opened at once, the dialog would lose
its focus to the gear, and give it back on closing to the menu item that is no
longer there.
*/
@(private)
settings_menu :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result, size := primer.Button_Size.Medium) {
	// The menu hangs from the gear, drawn after it in one stack, as
	// primer.action_menu_button asks of its menu (jm/ui/primer/menus.odin).
	ui.stack(gtx)
	if primer.icon_button(gtx, .Gear, tr(.Settings), .Invisible, size, expanded = m.settings_open) {
		m.settings_open = !m.settings_open
	}
	gear := ui.last_widget(gtx)
	if m.settings_open {
		m.settings_dialog = .None
	} else if m.settings_dialog != .None && ui.focused(gtx) == gear.id {
		switch m.settings_dialog {
		case .None:
		case .Export:
			export_show(gtx, m)
		case .Monitoring:
			monitor_show(m, prog)
		case .Licence:
			licence_show(m)
		case .History:
			m.record_open = true
		case .About:
			m.about_open = true
		}
		m.settings_dialog = .None
	}
	menu := primer.action_menu_open(gtx, &m.settings_open, gear, align = .End, name = tr(.Settings))
	defer primer.action_menu_close(&menu)
	if !menu.visible {
		return
	}
	if export_item(&menu, m, prog) {
		m.settings_dialog = .Export
	}
	switch {
	case prog != nil && prog.state == .Scanning:
		if primer.action_menu_item(&menu, tr(.Stop), leading = .Square_Fill, variant = .Danger) {
			ui.command(gtx, command.Command(command.Stop{}))
		}
	case can_rescan(prog):
		if primer.action_menu_item(
			&menu,
			tr(.Rescan),
			leading = .Sync,
			trailing_text = RESCAN_TEXT,
			hint = RESCAN_HINT,
		) {
			rescan(gtx, prog)
		}
	}
	if primer.action_menu_item(&menu, tr(.Monitoring), leading = .Pulse) {
		m.settings_dialog = .Monitoring
	}
	if primer.action_menu_item(&menu, tr(.History), leading = .History) {
		m.settings_dialog = .History
	}
	primer.action_menu_divider(&menu)
	if licence_item(gtx, &menu) {
		m.settings_dialog = .Licence
	}
	language_item(&menu, m)
	theme_item(&menu, m)
	if primer.action_menu_item(&menu, trf(gtx, .About, version.PRODUCT), leading = .Info) {
		m.settings_dialog = .About
	}
	language_menu(gtx, &menu, m)
	theme_menu(gtx, &menu, m)
}

// theme_item is the settings menu's Theme and the submenu it opens. The
// submenu is drawn after every other item, so settings_menu calls theme_menu.
@(private)
theme_item :: proc(menu: ^primer.Action_Menu, m: ^Model) {
	primer.action_menu_item(
		menu,
		tr(.Theme),
		leading = .Moon if m.dark else .Sun,
		submenu = &m.theme_open,
	)
}

// theme_menu is the submenu of themes that theme_item opens: Auto follows
// the OS, and Light and Dark stay.
@(private)
theme_menu :: proc(gtx: ^ui.Ctx, parent: ^primer.Action_Menu, m: ^Model) {
	menu := primer.action_menu_submenu_open(parent, &m.theme_open, selection = .Single)
	defer primer.action_menu_close(&menu)
	if !menu.visible {
		return
	}
	if primer.action_menu_item(
		&menu,
		tr(.Theme_Auto),
		selected = m.theme == .Auto || m.theme == .Unset,
	) {
		set_theme(gtx, m, .Auto)
	}
	if primer.action_menu_item(&menu, tr(.Theme_Light), selected = m.theme == .Light) {
		set_theme(gtx, m, .Light)
	}
	if primer.action_menu_item(&menu, tr(.Theme_Dark), selected = m.theme == .Dark) {
		set_theme(gtx, m, .Dark)
	}
}

// RESCAN_HINT and RESCAN_TEXT are Rescan's shortcut in the menu: key caps on
// macOS, the words elsewhere. jm's condensed hint writes Ctrl as U+2303 on every
// system (key_label, jm/ui/primer/actions.odin). Liberation Sans, the Linux
// default face (jm/ui/font.odin), has no U+2303 in its cmap, checked with
// fontTools on 2026-10-24, so the menu drew a blank box; Windows menus spell
// the key out too.
RESCAN_HINT :: "Mod+R" when ODIN_OS == .Darwin else ""
RESCAN_TEXT :: "" when ODIN_OS == .Darwin else "Ctrl+R"

// Settings_Dialog is the dialog a choice in the settings menu opens once the menu
// has given focus back to the gear.
Settings_Dialog :: enum u8 {
	None,
	Export,
	Monitoring,
	Licence,
	History,
	About,
}
