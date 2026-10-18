package leita_msg

import "core:testing"

import "jm:i18n"

// Every offered language has every message English has, no other, with the
// same arguments, and every plural form its rules need.
@(test)
every_locale_translates_every_message :: proc(t: ^testing.T) {
	base: i18n.Table(Msg)
	err, line := i18n.load(&base, .English, SOURCES[.English])
	testing.expectf(t, err == .None, "en.txt line %d: %v", line, err)
	defer free_all(context.temp_allocator)
	for locale in OFFERED {
		testing.expectf(
			t,
			offered(locale),
			"%s is offered but has no text",
			i18n.locale_tag(locale),
		)
		for issue in i18n.check(Msg, locale, SOURCES[locale], &base, context.temp_allocator) {
			testing.expectf(t, false, "%s: %v", i18n.locale_tag(locale), issue)
		}
	}
}

// The system's first language on offer wins, BCP 47 or POSIX; C, or none on
// offer, is English.
@(test)
pick_locale_takes_the_first_offered :: proc(t: ^testing.T) {
	offer := []i18n.Locale{.English, .German, .Portuguese_Brazil}
	testing.expect_value(t, pick_locale({"fr", "de_AT.UTF-8", "en"}, offer), i18n.Locale.German)
	testing.expect_value(t, pick_locale({"pt-BR", "de"}, offer), i18n.Locale.Portuguese_Brazil)
	testing.expect_value(t, pick_locale({"", "C", "en_GB.UTF-8"}, offer), i18n.Locale.English)
	testing.expect_value(t, pick_locale({"fr"}, offer), i18n.Locale.English)
	testing.expect_value(t, pick_locale({}, offer), i18n.Locale.English)
}

// A count picks its message's form and is grouped as the language groups it; a
// message with no count is the same text whatever is passed.
@(test)
counts_pick_the_form_and_group_their_digits :: proc(t: ^testing.T) {
	s := new(Strings)
	defer free(s)
	init(s, .English)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, trf(s, .Count_Items, 1), "1 item")
	testing.expect_value(t, trf(s, .Count_Items, 0), "0 items")
	testing.expect_value(t, trf(s, .Count_Items, 813073), "813,073 items")
	testing.expect_value(t, trf(s, .Listing_Summary, 2, "274.4 kB"), "274.4 kB in 2 items")
	testing.expect_value(
		t,
		trf(s, .Cleaned_Partly, 0, 1),
		"Deleted 0 folders; 1 could not be deleted in full. How much disk space that frees is unknown.",
	)
	testing.expect_value(t, tr(s, .Language), "Language")
	use(s, .Chinese_Traditional)
	testing.expect_value(t, locale(s), i18n.Locale.English) // not offered
}
