package leita_schedule

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf16"

/*
On Windows the entry is a task in Task Scheduler's leita folder, made from the
XML task_xml writes, since schtasks /Create has no flag for StartWhenAvailable,
MultipleInstancesPolicy or the battery settings (schtasks create, on
learn.microsoft.com). It repeats every hour from a start boundary with no
zone, so on the local clock.
StartWhenAvailable runs a start missed while the machine was off or asleep once
when it is next up; MultipleInstancesPolicy IgnoreNew skips a start while the
last run is still going. It runs as the person who made it, only while they are
logged on, with the least privilege and below normal priority. The Task
Scheduler Schema reference on learn.microsoft.com gives each element, and
schtasks /Create /XML wants the file in UTF-16 (utf16_file).

The program runs through conhost.exe --headless, since leita.exe is a console
program and card 82 found that a task running one as the logged-on user may open
a console window every hour. The switch makes the console host run its command
line in a console with no window (--headless is among the arguments the console
host in github.com/microsoft/terminal, src/host/ConsoleArguments.cpp, parses),
which the notification's powershell, started from leita, then shares.
ASSUMPTION: no one has watched a Windows desktop through an hour to see that
nothing appears; the Windows runner's test reads the task back
(task_scheduler_takes_and_gives_back_the_task_on_ci), and card 82 asks for the
watching.
*/

// HEADLESS_HOST is the console host a task's program runs through, and
// HEADLESS the switch that gives it a console with no window.
HEADLESS_HOST :: "conhost.exe"
HEADLESS      :: "--headless"

// TASK_NAME is the task's path in Task Scheduler.
TASK_NAME :: `leita\monitor`

// task_xml is the task that runs argv every hour, through conhost --headless, as
// schtasks /XML reads it once it is written as UTF-16 (utf16_file).
task_xml :: proc(argv: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	w :: proc(b: ^strings.Builder, s: string) {strings.write_string(b, s)}
	w(&b, "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n")
	w(
		&b,
		"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\n",
	)
	w(&b, "  <RegistrationInfo>\n")
	w(&b, "    <Description>leita: scan the watched places when due</Description>\n")
	fmt.sbprintf(&b, "    <URI>\\%s</URI>\n", escape_xml(TASK_NAME))
	w(&b, "  </RegistrationInfo>\n")
	w(&b, "  <Triggers>\n")
	w(&b, "    <TimeTrigger>\n")
	w(&b, "      <Repetition>\n")
	w(&b, "        <Interval>PT1H</Interval>\n")
	w(&b, "        <StopAtDurationEnd>false</StopAtDurationEnd>\n")
	w(&b, "      </Repetition>\n")
	w(&b, "      <StartBoundary>2026-01-01T00:00:00</StartBoundary>\n")
	w(&b, "      <Enabled>true</Enabled>\n")
	w(&b, "      <RandomDelay>PT5M</RandomDelay>\n")
	w(&b, "    </TimeTrigger>\n")
	w(&b, "  </Triggers>\n")
	w(&b, "  <Principals>\n")
	w(&b, "    <Principal id=\"Author\">\n")
	w(&b, "      <LogonType>InteractiveToken</LogonType>\n")
	w(&b, "      <RunLevel>LeastPrivilege</RunLevel>\n")
	w(&b, "    </Principal>\n")
	w(&b, "  </Principals>\n")
	w(&b, "  <Settings>\n")
	w(&b, "    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\n")
	w(&b, "    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\n")
	w(&b, "    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\n")
	w(&b, "    <StartWhenAvailable>true</StartWhenAvailable>\n")
	w(&b, "    <ExecutionTimeLimit>PT4H</ExecutionTimeLimit>\n")
	w(&b, "    <Enabled>true</Enabled>\n")
	w(&b, "    <Priority>7</Priority>\n")
	w(&b, "  </Settings>\n")
	w(&b, "  <Actions Context=\"Author\">\n")
	w(&b, "    <Exec>\n")
	fmt.sbprintf(&b, "      <Command>%s</Command>\n", HEADLESS_HOST)
	args := make([dynamic]string, context.temp_allocator)
	append(&args, HEADLESS)
	for arg in argv {
		append(&args, windows_quote(arg))
	}
	fmt.sbprintf(
		&b,
		"      <Arguments>%s</Arguments>\n",
		escape_xml(strings.join(args[:], " ", context.temp_allocator)),
	)
	w(&b, "    </Exec>\n")
	w(&b, "  </Actions>\n")
	w(&b, "</Task>\n")
	return strings.to_string(b)
}

/*
windows_quote is arg as one argument of a Windows command line, as
CommandLineToArgvW and the C runtime split one: quoted when it is empty or holds a
space, a tab or a quote, each quote escaped, and the backslashes before a quote or
the closing quote doubled. Others stand as they are, so C:\Program Files\ quotes
to "C:\Program Files\\". The rules are those of "Parsing C command-line arguments"
in Microsoft's C runtime reference.
*/
windows_quote :: proc(arg: string, allocator := context.temp_allocator) -> string {
	if arg != "" && strings.index_any(arg, " \t\n\v\"") < 0 {
		return strings.clone(arg, allocator)
	}
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	slashes := 0
	for c in transmute([]byte)arg {
		switch c {
		case '\\':
			slashes += 1
			continue
		case '"':
			for _ in 0 ..< slashes * 2 + 1 {
				strings.write_byte(&b, '\\')
			}
		case:
			for _ in 0 ..< slashes {
				strings.write_byte(&b, '\\')
			}
		}
		slashes = 0
		strings.write_byte(&b, c)
	}
	for _ in 0 ..< slashes * 2 {
		strings.write_byte(&b, '\\')
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// escape_xml makes s fit to stand as XML text or an attribute's value.
escape_xml :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for c in transmute([]byte)s {
		switch c {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case '\'':
			strings.write_string(&b, "&apos;")
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// utf16_file is text as schtasks reads an XML file: UTF-16, little endian, after
// a byte order mark.
utf16_file :: proc(text: string, allocator := context.temp_allocator) -> []byte {
	units := make([]u16, len(text) + 1, context.temp_allocator)
	units[0] = 0xfeff
	n := utf16.encode_string(units[1:], text)
	out := make([]byte, 2 * (n + 1), allocator)
	for u, i in units[:n + 1] {
		out[2 * i] = byte(u)
		out[2 * i + 1] = byte(u >> 8)
	}
	return out
}

// task_path is where the task's XML is written while schtasks reads it.
@(private)
task_path :: proc(h: Host) -> string {
	path, _ := filepath.join({h.temp, NAME + ".xml"}, context.temp_allocator)
	return path
}

// install_task writes the task's XML to a file and has schtasks make the task
// from it, replacing one of the same name.
@(private)
install_task :: proc(h: Host, argv: []string) -> string {
	path := task_path(h)
	if err := os.write_entire_file(path, utf16_file(task_xml(argv))); err != nil {
		return fmt.tprintf("cannot write %s: %v", path, err)
	}
	defer os.remove(path)
	if r := h.run({"schtasks", "/Create", "/XML", path, "/TN", TASK_NAME, "/F"}, h.user); !r.ok {
		return r.err
	}
	return ""
}

// remove_task deletes the task, if it is there.
@(private)
remove_task :: proc(h: Host) -> string {
	if !h.run({"schtasks", "/Query", "/TN", TASK_NAME}, h.user).ok {
		return ""
	}
	if r := h.run({"schtasks", "/Delete", "/TN", TASK_NAME, "/F"}, h.user); !r.ok {
		return r.err
	}
	return ""
}
