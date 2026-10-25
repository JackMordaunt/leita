package leita_msg

import "core:os"
import "core:strings"
import "core:testing"

import "jm:i18n"

// system_locale reads the environment in the order gettext gives it (LANGUAGE, then
// LC_ALL, LC_MESSAGES, LANG), whatever the byte encoding the locale names, and
// "C" or "POSIX" names no language, so English, however LANGUAGE is set. A
// language the window does not offer, Turkish among them, is English too.
@(test)
the_environment_picks_the_window_language :: proc(t: ^testing.T) {
	// Windows adds the user's own locale after these, which the test cannot set.
	when ODIN_OS == .Windows {
		return
	}
	Env :: struct {
		set:  []string,
		want: i18n.Locale,
	}
	cases := [?]Env {
		{{"LANG=de_DE.UTF-8"}, .German},
		{{"LANG=ja_JP.UTF-8"}, .Japanese},
		{{"LANG=ja_JP.eucJP"}, .Japanese},
		{{"LANG=ja_JP.UTF-8", "LC_MESSAGES=de_DE"}, .German},
		{{"LANG=ja_JP.UTF-8", "LC_ALL=de_DE.UTF-8", "LC_MESSAGES=ru_RU"}, .German},
		{{"LANG=tr_TR.UTF-8"}, .English},
		{{"LANG=tr_TR.UTF-8", "LANGUAGE=de"}, .German},
		{{"LANG=de_DE.UTF-8", "LC_ALL=C"}, .English},
		{{"LANG=de_DE.UTF-8", "LC_ALL=POSIX"}, .English},
		{{"LANG=de_DE.UTF-8", "LC_ALL=C.UTF-8"}, .English},
		{{"LC_ALL=C", "LANGUAGE=ja"}, .English},
		{{"LANGUAGE=ja:de"}, .Japanese},
		{{}, .English},
	}
	names := [?]string{"LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"}
	saved: [len(names)]Maybe(string)
	for name, i in names {
		if v, found := os.lookup_env(name, context.allocator); found {
			saved[i] = v
		}
	}
	defer for name, i in names {
		if v, ok := saved[i].?; ok {
			os.set_env(name, v)
			delete(v)
		} else {
			os.unset_env(name)
		}
	}

	for c in cases {
		for name in names {
			os.unset_env(name)
		}
		for kv in c.set {
			key, _, value := strings.partition(kv, "=")
			testing.expect(t, os.set_env(key, value) == nil)
		}
		testing.expectf(t, system_locale() == c.want, "%v: %v, want %v", c.set, system_locale(), c.want)
	}
}
