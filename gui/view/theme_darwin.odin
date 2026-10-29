#+build darwin
package leita_view

import "base:runtime"

import "core:c"
import "core:time"

foreign import core_foundation "system:CoreFoundation.framework"

@(private)
UTF8 :: c.uint(0x08000100)

@(default_calling_convention = "c")
foreign core_foundation {
	kCFPreferencesAnyApplication: rawptr
	kCFPreferencesCurrentUser:    rawptr
	kCFPreferencesAnyHost:        rawptr
	CFStringCreateWithCString :: proc(alloc: rawptr, cStr: cstring, encoding: c.uint) -> rawptr ---
	CFStringGetTypeID         :: proc() -> uint ---
	CFGetTypeID               :: proc(cf: rawptr) -> uint ---
	CFStringCompare           :: proc(a, b: rawptr, flags: c.uint) -> c.long ---
	CFPreferencesCopyValue    :: proc(key, app, user, host: rawptr) -> rawptr ---
	CFPreferencesAppSynchronize :: proc(applicationID: rawptr) ---
	CFRelease                 :: proc(cf: rawptr) ---
}

@(private)
style_key: rawptr

@(private)
dark_value: rawptr

@(private, thread_local)
synced_at: i64

@(private, init)
theme_init :: proc "contextless" () {
	context = runtime.default_context()
	style_key = CFStringCreateWithCString(nil, "AppleInterfaceStyle", UTF8)
	dark_value = CFStringCreateWithCString(nil, "Dark", UTF8)
}

// system_dark reports whether macOS is drawing dark. AppleInterfaceStyle is
// "Dark" then, and absent for light. The global domain is re-read at most
// once a second, so a change shows up on a later frame.
system_dark :: proc() -> bool {
	if style_key == nil || dark_value == nil {
		return false
	}
	now := time.tick_now()._nsec
	if synced_at == 0 || now - synced_at >= i64(time.Second) {
		CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
		synced_at = now
	}
	style := CFPreferencesCopyValue(
		style_key,
		kCFPreferencesAnyApplication,
		kCFPreferencesCurrentUser,
		kCFPreferencesAnyHost,
	)
	if style == nil || CFGetTypeID(style) != CFStringGetTypeID() {
		if style != nil {
			CFRelease(style)
		}
		return false
	}
	defer CFRelease(style)
	return CFStringCompare(style, dark_value, 0) == 0
}
