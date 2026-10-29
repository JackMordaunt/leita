#+build linux
package leita_view

import "core:testing"

@(test)
gtk_and_kde_text_names_a_dark_theme :: proc(t: ^testing.T) {
	dark, ok := text_dark("gtk-application-prefer-dark-theme=1\n")
	testing.expect(t, ok && dark)
	light, lok := text_dark("gtk-application-prefer-dark-theme=0\ngtk-theme-name=Adwaita-dark\n")
	testing.expect(t, lok && !light, "the prefer key wins over the theme name")
	named, nok := text_dark("[Settings]\ngtk-theme-name=Adwaita-dark\n")
	testing.expect(t, nok && named)
	plain, pok := text_dark("gtk-theme-name=Adwaita\n")
	testing.expect(t, pok && !plain)
	kde, kok := text_dark("[General]\nColorScheme=BreezeDark\n")
	testing.expect(t, kok && kde)
	breeze, bok := text_dark("ColorScheme=Breeze\n")
	testing.expect(t, bok && !breeze)
	_, none := text_dark("[Other]\nName=Breeze\n")
	testing.expect(t, !none)
}
