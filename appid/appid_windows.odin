#+build windows
package leita_appid

import win32 "core:sys/windows"

foreign import shell32 "system:Shell32.lib"

@(default_calling_convention = "system")
foreign shell32 {
	SetCurrentProcessExplicitAppUserModelID :: proc(AppID: win32.PCWSTR) -> win32.HRESULT ---
}

// set gives this process ID as its AppUserModelID, before it shows a window or
// a notification, and says whether Windows took it. Nothing depends on the
// answer; a caller may ignore it.
set :: proc() -> bool {
	return win32.SUCCEEDED(
		SetCurrentProcessExplicitAppUserModelID(win32.utf8_to_wstring(ID, context.temp_allocator)),
	)
}
