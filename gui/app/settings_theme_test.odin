package leita_app

import "core:testing"

import "jm:sqlite3"

import "../../settings"
import "../query"

// Nothing stored follows the OS. Light, dark and auto are kept; unset is not.
@(test)
an_absent_theme_follows_the_os_and_a_choice_is_kept :: proc(t: ^testing.T) {
	d: Desk
	testing.expect_value(t, settings_answer(&d).theme, query.Theme_Choice.Auto)
	remember_theme(&d, {choice = u8(query.Theme_Choice.Dark)})
	testing.expect(t, settings_answer(&d).theme == .Auto, "nothing was open to keep it")

	settings_open(&d, sqlite3.MEMORY)
	defer settings_close(&d)
	testing.expect_value(t, settings_answer(&d).theme, query.Theme_Choice.Auto)

	remember_theme(&d, {choice = u8(query.Theme_Choice.Dark)})
	testing.expect_value(t, settings_answer(&d).theme, query.Theme_Choice.Dark)
	got, ok := settings.get(d.settings, settings.THEME, context.temp_allocator)
	testing.expect(t, ok && got == "dark")

	remember_theme(&d, {choice = u8(query.Theme_Choice.Light)})
	testing.expect_value(t, settings_answer(&d).theme, query.Theme_Choice.Light)

	remember_theme(&d, {choice = u8(query.Theme_Choice.Auto)})
	testing.expect_value(t, settings_answer(&d).theme, query.Theme_Choice.Auto)
	got, ok = settings.get(d.settings, settings.THEME, context.temp_allocator)
	testing.expect(t, ok && got == "auto")

	remember_theme(&d, {choice = u8(query.Theme_Choice.Dark)})
	remember_theme(&d, {})
	testing.expect(t, settings_answer(&d).theme == .Dark, "unset is not written")

	testing.expect(t, settings.set(d.settings, settings.THEME, "nope") == nil)
	testing.expect(t, settings_answer(&d).theme == .Auto, "anything else follows the OS")
}
