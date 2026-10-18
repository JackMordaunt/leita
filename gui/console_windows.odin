#+build windows
package main

import "core:os"
import win32 "core:sys/windows"

// ATTACH_PARENT_PROCESS is AttachConsole's process id for the console of the
// process that started this one.
ATTACH_PARENT_PROCESS :: ~win32.DWORD(0)

/*
attach_console gives Leita, built for Windows's GUI subsystem so that starting
the window opens no console behind it, the console of the terminal that started
it (AttachConsole with ATTACH_PARENT_PROCESS, on learn.microsoft.com), so that
leita's command line can print there. A standard stream that came redirected, to
a file or a pipe, is left as it is; one that did not is opened on the console.
It does nothing when there is no parent console to attach, as when the Start menu
or a scheduled task started Leita.
ASSUMPTION: a GUI-subsystem process is given no standard handles unless they are
redirected, which is why they are opened; the Windows runner's check of
Leita.exe --version covers the redirected case only.
*/
attach_console :: proc() {
	if !win32.AttachConsole(ATTACH_PARENT_PROCESS) {
		return
	}
	reopen :: proc(f: ^^os.File, code: win32.DWORD, name: string, flags: os.File_Flags) {
		if h := win32.GetStdHandle(code); h != nil && h != win32.INVALID_HANDLE_VALUE {
			return
		}
		if opened, err := os.open(name, flags); err == nil {
			f^ = opened
		}
	}
	reopen(&os.stdin, win32.STD_INPUT_HANDLE, "CONIN$", {.Read})
	reopen(&os.stdout, win32.STD_OUTPUT_HANDLE, "CONOUT$", {.Write})
	reopen(&os.stderr, win32.STD_ERROR_HANDLE, "CONOUT$", {.Write})
}
