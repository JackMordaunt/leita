#+build windows
package home

import "core:os"
import win32 "core:sys/windows"

// user is the person at the keyboard: their profile directory, which USERPROFILE
// names, or HOME where a shell sets it instead, and the account's SID string.
user :: proc(allocator := context.allocator) -> User {
	dir := os.get_env("USERPROFILE", allocator)
	if dir == "" {
		dir = os.get_env("HOME", allocator)
	}
	return {dir, sid(allocator)}
}

// sid is this process's user SID as ConvertSidToStringSidW writes it, or "".
@(private)
sid :: proc(allocator := context.allocator) -> string {
	token: win32.HANDLE
	if !win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &token) {
		return ""
	}
	defer win32.CloseHandle(token)
	needed: win32.DWORD
	win32.GetTokenInformation(token, .TokenUser, nil, 0, &needed)
	if needed == 0 {
		return ""
	}
	buf := make([]byte, needed, context.temp_allocator)
	if !win32.GetTokenInformation(token, .TokenUser, raw_data(buf), needed, &needed) {
		return ""
	}
	who := (^win32.TOKEN_USER)(raw_data(buf))
	wide: win32.wstring
	if !win32.ConvertSidToStringSidW((^win32.SID)(who.User.Sid), &wide) {
		return ""
	}
	defer win32.LocalFree(rawptr(wide))
	out, err := win32.wstring_to_utf8(wide, -1, allocator)
	return out if err == nil else ""
}

// user_destroy frees what user made.
user_destroy :: proc(u: ^User, allocator := context.allocator) {
	delete(u.dir, allocator)
	delete(u.uid, allocator)
}
