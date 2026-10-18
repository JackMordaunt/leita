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
asks once; until the answer comes, and for anything never chosen, it keeps its
defaults, the system's language and the light theme. Each choice is sent to the
host as it is made (language_menu, the theme item in settings_menu).
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
	switch r.theme {
	case .Light:
		m.dark = false
	case .Dark:
		m.dark = true
	case .Unset:
	}
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
settings_menu :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	// The menu hangs from the gear, drawn after it in one stack, as
	// primer.action_menu_button asks of its menu (jm/ui/primer/menus.odin).
	ui.stack(gtx)
	if primer.icon_button(gtx, .Gear, tr(.Settings), .Invisible, expanded = m.settings_open) {
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
		if primer.action_menu_item(&menu, tr(.Rescan), leading = .Sync, hint = "Mod+R") {
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
	if primer.action_menu_item(
		&menu,
		tr(.Theme_Light) if m.dark else tr(.Theme_Dark),
		leading = .Sun if m.dark else .Moon,
	) {
		m.dark = !m.dark
		ui.command(gtx, command.Command(command.Theme{dark = m.dark}))
	}
	if primer.action_menu_item(&menu, trf(gtx, .About, version.PRODUCT), leading = .Info) {
		m.settings_dialog = .About
	}
	language_menu(gtx, &menu, m)
}

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
