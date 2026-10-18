package leita_alert

import "core:strings"

import "../appid"
import "../version"

/*
A desktop notification for each alert raised, through what each system has
without installing anything or registering an application:

	Linux    notify-send (libnotify), which calls Notify on the session bus's
	         org.freedesktop.Notifications, the Desktop Notifications
	         Specification (specifications.freedesktop.org); where it is
	         missing, gdbus calls the same method itself.
	Windows  a toast, through ToastNotificationManager.CreateToastNotifier
	         with an application id Windows already knows, since a toast under
	         an unregistered id is not shown (Microsoft's "Send a local toast
	         notification from desktop apps"): Leita's own, appid.ID, where
	         the installer's Start menu shortcut registered it, so the toast
	         says Leita; PowerShell's where it did not, a run from the zip.
	macOS    osascript's display notification (the StandardAdditions
	         dictionary), which needs no application bundle, where
	         UNUserNotificationCenter needs one and the person's permission.

The command lines are pure procedures, so the tests read them on any system;
notify runs them through a runner a test replaces.
*/

// System is a desktop a notification is shown on.
System :: enum u8 {
	Freedesktop,
	Windows,
	Macos,
}

when ODIN_OS == .Windows {
	SYSTEM :: System.Windows
} else when ODIN_OS == .Darwin {
	SYSTEM :: System.Macos
} else {
	SYSTEM :: System.Freedesktop
}

// Runner runs argv and says whether it ran.
Runner :: #type proc(argv: []string, user: rawptr) -> bool

// POWERSHELL_APP is the application id of the Windows PowerShell shortcut that
// Windows installs in the Start menu, so toasts under it are shown, and the one
// used when Leita's own is not registered.
POWERSHELL_APP :: `{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe`

// notify shows title and body on system, trying the next way when one does not
// run, and says whether one did.
notify :: proc(system: System, title, body: string, run: Runner, user: rawptr = nil) -> bool {
	for argv in commands(system, title, body) {
		if run(argv, user) {
			return true
		}
	}
	return false
}

// commands are the ways to show title and body on system, the first to try
// first, in the temp allocator.
commands :: proc(system: System, title, body: string) -> [][]string {
	out := make([dynamic][]string, context.temp_allocator)
	switch system {
	case .Freedesktop:
		append(
			&out,
			clone(
				{
					"notify-send",
					"--app-name=" + version.NAME,
					"--icon=drive-harddisk",
					title,
					body,
				},
			),
		)
		append(
			&out,
			clone(
				{
					"gdbus",
					"call",
					"--session",
					"--dest=org.freedesktop.Notifications",
					"--object-path=/org/freedesktop/Notifications",
					"--method=org.freedesktop.Notifications.Notify",
					version.NAME,
					"0",
					"drive-harddisk",
					title,
					body,
					"[]",
					"{}",
					"-1",
				},
			),
		)
	case .Windows:
		append(
			&out,
			clone(
				{
					"powershell",
					"-NoProfile",
					"-NonInteractive",
					"-WindowStyle",
					"Hidden",
					"-Command",
					toast_script(title, body),
				},
			),
		)
	case .Macos:
		script := strings.concatenate(
			{"display notification ", apple_quote(body), " with title ", apple_quote(title)},
			context.temp_allocator,
		)
		append(&out, clone({"osascript", "-e", script}))
	}
	return out[:]
}

// clone is argv in the temp allocator, since a literal's lives on the stack.
@(private)
clone :: proc(argv: []string) -> []string {
	out := make([]string, len(argv), context.temp_allocator)
	copy(out, argv)
	return out
}

/*
toast_script is the PowerShell that shows title and body as a toast: the
ToastText02 template's two lines, set as XML text, under appid.ID when the shell
lists a Start menu entry of that id (Get-StartApps; the installer makes one) and
under POWERSHELL_APP when it does not or cannot say. Each is passed as a
single-quoted PowerShell string, its quotes doubled, so nothing in them is run.
*/
toast_script :: proc(title, body: string) -> string {
	return strings.concatenate(
		{
			"$app = ",
			powershell_quote(POWERSHELL_APP),
			"; try { if (Get-StartApps | Where-Object { $_.AppID -eq ",
			powershell_quote(appid.ID),
			" }) { $app = ",
			powershell_quote(appid.ID),
			" } } catch {}; ",
			"[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null; ",
			"$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02); ",
			"$t = $x.GetElementsByTagName('text'); ",
			"$t.Item(0).AppendChild($x.CreateTextNode(",
			powershell_quote(title),
			")) > $null; ",
			"$t.Item(1).AppendChild($x.CreateTextNode(",
			powershell_quote(body),
			")) > $null; ",
			"[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($x))",
		},
		context.temp_allocator,
	)
}

// powershell_quote is s as a single-quoted PowerShell string, which expands
// nothing: each quote, straight or curly, doubled (about_Quoting_Rules).
powershell_quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '\'')
	for r in s {
		switch r {
		case '\'', '‘', '’', '‚', '‛':
			strings.write_rune(&b, r)
		}
		strings.write_rune(&b, r)
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

// apple_quote is s as an AppleScript string: in double quotes, with each
// backslash and double quote escaped.
apple_quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for c in transmute([]byte)s {
		if c == '"' || c == '\\' {
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, c)
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}
