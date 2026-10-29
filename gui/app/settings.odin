package leita_app

import "core:fmt"
import "core:strings"

import "jm:i18n"
import "jm:sqlite3"

import "../../settings"
import "../command"
import "../query"

/*
What the person chose, kept between runs in the settings store beside the
history store: the language picked from the toolbar's menu and the theme. The
window asks for them once (query.Settings) and opens as they were left; each
choice it sends is written at once.

A store that cannot be opened leaves the language at the system's and the theme
following the OS for the session: nothing else depends on it.
*/

// settings_open opens the store at path, or leaves settings unkept for "".
settings_open :: proc(d: ^Desk, path: string) {
	if path == "" {
		return
	}
	st := new(settings.Store)
	if err := settings.open(st, path); err != nil {
		fmt.eprintln("leita: settings will not be kept:", path, err)
		free(st)
		return
	}
	d.settings = st
	update_restore(d)
}

// update_restore reads the shared check and the dismissed version. Absent
// stays off: an older store has no updates key.
update_restore :: proc(d: ^Desk, allocator := context.allocator) {
	d.update_checked = update_checked_load(d)
	delete(d.update_dismissed, allocator)
	d.update_dismissed = update_dismissed_load(d, allocator)
}

settings_close :: proc(d: ^Desk) {
	if d.settings != nil {
		settings.close(d.settings)
		free(d.settings)
		d.settings = nil
	}
}

// These are command.Theme's choice. command does not import this package.
#assert(u8(query.Theme_Choice.Unset) == 0)
#assert(u8(query.Theme_Choice.Light) == 1)
#assert(u8(query.Theme_Choice.Dark) == 2)
#assert(u8(query.Theme_Choice.Auto) == 3)

settings_answer :: proc(d: ^Desk, allocator := context.temp_allocator) -> query.Settings_Result {
	r: query.Settings_Result
	// Absent, unreadable, and anything that is not light or dark follow the OS.
	r.theme = .Auto
	// The unsaved flag is reported even when nothing is kept, so About can
	// say that checks are off for this session.
	if d.update_save_failed {
		r.automatic_checks_unsaved = true
	}
	if d.settings == nil {
		return r
	}
	if tag, ok := settings.get(d.settings, settings.LANGUAGE, allocator); ok {
		r.language = tag
	}
	if theme, ok := settings.get(d.settings, settings.THEME, allocator); ok {
		switch theme {
		case "light":
			r.theme = .Light
		case "dark":
			r.theme = .Dark
		case "auto":
			r.theme = .Auto
		}
	}
	// A choice this session could not write stays off, whatever the store says.
	if !d.update_save_failed {
		if value, found := settings.get(d.settings, settings.UPDATES, allocator); found {
			r.automatic_checks = value == "on"
		}
	}
	return r
}

// remember_language keeps the language the person picked.
remember_language :: proc(d: ^Desk, c: command.Language) {
	if d.settings == nil || !c.chosen || int(c.locale) >= len(i18n.Locale) {
		return
	}
	keep_setting(d, settings.LANGUAGE, i18n.locale_tag(i18n.Locale(c.locale)))
}

// remember_theme keeps the theme the person picked. Unset is not a choice.
remember_theme :: proc(d: ^Desk, c: command.Theme) {
	if d.settings == nil {
		return
	}
	value: string
	switch query.Theme_Choice(c.choice) {
	case .Light:
		value = "light"
	case .Dark:
		value = "dark"
	case .Auto:
		value = "auto"
	case .Unset:
		return
	}
	keep_setting(d, settings.THEME, value)
}

// remember_updates keeps the opt-in. Off is written, so a later run stays
// off; a store that never had the key stays off without this write. A
// missing store or a failed write leaves checks off for this session and
// leaves the stored choice for the next launch. It does not try again.
remember_updates :: proc(d: ^Desk, on: bool) {
	if d.settings == nil {
		d.update_save_failed = true
		fmt.eprintln("leita: could not keep the update choice: settings are not open")
		return
	}
	if err := settings.set(d.settings, settings.UPDATES, "on" if on else "off"); err != nil {
		d.update_save_failed = true
		fault := err.(sqlite3.Fault) or_else sqlite3.Fault{}
		fmt.eprintln("leita: could not keep the update choice:", fault.text)
		delete(fault.text, d.settings.db.allocator)
		return
	}
	d.update_save_failed = false
}

// remember_dismiss hides the notice for version until a different one is
// published. About can still show it.
remember_dismiss :: proc(d: ^Desk, version: string, allocator := context.allocator) {
	if d.settings != nil {
		keep_setting(d, settings.UPDATE_DISMISSED, version)
	}
	delete(d.update_dismissed, allocator)
	d.update_dismissed = strings.clone(version, allocator)
}

@(private = "file")
keep_setting :: proc(d: ^Desk, key, value: string) {
	if err := settings.set(d.settings, key, value); err != nil {
		fmt.eprintln("leita: could not keep the setting", key, err)
	}
}
