#+build windows
package journeys_gui

import win "core:sys/windows"

foreign import advapi32 "system:Advapi32.lib"

@(default_calling_convention = "system")
foreign advapi32 {
	LookupPrivilegeValueW :: proc(system, name: win.LPCWSTR, luid: ^win.LUID) -> win.BOOL ---
	AdjustTokenPrivileges :: proc(token: win.HANDLE, disable_all: win.BOOL, new_state: ^Token_Privilege, length: win.DWORD, previous: rawptr, returned: ^win.DWORD) -> win.BOOL ---
}

// Token_Privilege is TOKEN_PRIVILEGES holding the one privilege it changes.
Token_Privilege :: struct {
	count:     win.DWORD,
	privilege: win.LUID_AND_ATTRIBUTES,
}

SE_PRIVILEGE_ENABLED :: 0x2

/*
allow_backup turns this process's backup and restore privileges on or off. An
administrator's process on the hosted runner holds both enabled, and with them a
directory opened for backup, as the walk opens one, is read whatever its access
list says (CI run 40191152318): the folder a story shuts would be read in full.
false when either could not be changed.
*/
allow_backup :: proc(on: bool) -> bool {
	token: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_ADJUST_PRIVILEGES, &token) {
		return false
	}
	defer win.CloseHandle(token)

	ok := true
	for name in ([]string{"SeBackupPrivilege", "SeRestorePrivilege"}) {
		tp := Token_Privilege {
			count = 1,
		}
		if !LookupPrivilegeValueW(nil, win.utf8_to_wstring(name), &tp.privilege.Luid) {
			ok = false
			continue
		}
		tp.privilege.Attributes = SE_PRIVILEGE_ENABLED if on else 0
		ok &&= bool(AdjustTokenPrivileges(token, false, &tp, 0, nil, nil))
	}
	return ok
}
