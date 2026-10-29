#+build windows
package leita_view

import win "core:sys/windows"

@(private)
PERSONALIZE :: "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"

@(private)
APPS_USE_LIGHT :: "AppsUseLightTheme"

// system_dark reports whether Windows paints apps dark. AppsUseLightTheme is
// 0 for dark; a missing value is light.
system_dark :: proc() -> bool {
	key_buf: [80]u16
	name_buf: [24]u16
	key := win.utf8_to_wstring(key_buf[:], PERSONALIZE)
	name := win.utf8_to_wstring(name_buf[:], APPS_USE_LIGHT)
	if key == nil || name == nil {
		return false
	}
	value: u32 = 1
	size := win.DWORD(size_of(value))
	status := win.RegGetValueW(
		win.HKEY_CURRENT_USER,
		key,
		name,
		win.RRF_RT_REG_DWORD,
		nil,
		&value,
		&size,
	)
	return status == 0 && value == 0
}
