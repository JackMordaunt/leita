package sonar_schedule

import "core:fmt"
import "core:strings"
import "core:unicode/utf16"

/*
On Windows an entry is a task in Task Scheduler's sonar folder, made from the XML
task_xml writes, since only the XML can say what the command line cannot.
StartWhenAvailable runs a start missed while the machine was off or asleep once
when it is next up; MultipleInstancesPolicy IgnoreNew skips a start while the last
run is still going. The start boundary has no zone, so it is the local clock. The
Task Scheduler Schema reference on learn.microsoft.com gives each element, and
schtasks /Create /XML wants the file in UTF-16 (utf16_file).
*/

// TASK_FOLDER is the Task Scheduler folder sonar's tasks live in.
TASK_FOLDER :: `sonar\`

// task_name is the name an entry's task is made under.
task_name :: proc(name: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({TASK_FOLDER, name}, allocator)
}

// TASK_DAYS names each weekday as the task schema does.
@(private)
TASK_DAYS := [Weekday]string {
	.Monday    = "Monday",
	.Tuesday   = "Tuesday",
	.Wednesday = "Wednesday",
	.Thursday  = "Thursday",
	.Friday    = "Friday",
	.Saturday  = "Saturday",
	.Sunday    = "Sunday",
}

// task_xml is the task that runs argv on the entry's schedule, as schtasks /XML
// reads it once it is written as UTF-16 (utf16_file).
task_xml :: proc(e: Entry, argv: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	w :: proc(b: ^strings.Builder, s: string) {strings.write_string(b, s)}
	w(&b, "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n")
	w(
		&b,
		"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\n",
	)
	w(&b, "  <RegistrationInfo>\n")
	fmt.sbprintf(&b, "    <Description>%s</Description>\n", escape_xml(describe(e.timing)))
	fmt.sbprintf(&b, "    <URI>\\%s</URI>\n", escape_xml(task_name(e.name)))
	w(&b, "  </RegistrationInfo>\n")

	w(&b, "  <Triggers>\n")
	at := fmt.tprintf("2026-01-01T%02d:%02d:00", e.timing.hour, e.timing.minute)
	switch e.timing.every {
	case .Hourly:
		w(&b, "    <TimeTrigger>\n")
		w(&b, "      <Repetition>\n")
		w(&b, "        <Interval>PT1H</Interval>\n")
		w(&b, "        <StopAtDurationEnd>false</StopAtDurationEnd>\n")
		w(&b, "      </Repetition>\n")
		w(&b, "      <StartBoundary>2026-01-01T00:00:00</StartBoundary>\n")
		w(&b, "      <Enabled>true</Enabled>\n")
		w(&b, "      <RandomDelay>PT5M</RandomDelay>\n")
		w(&b, "    </TimeTrigger>\n")
	case .Daily:
		w(&b, "    <CalendarTrigger>\n")
		fmt.sbprintf(&b, "      <StartBoundary>%s</StartBoundary>\n", at)
		w(&b, "      <Enabled>true</Enabled>\n")
		w(&b, "      <ScheduleByDay>\n")
		w(&b, "        <DaysInterval>1</DaysInterval>\n")
		w(&b, "      </ScheduleByDay>\n")
		w(&b, "    </CalendarTrigger>\n")
	case .Weekly:
		w(&b, "    <CalendarTrigger>\n")
		fmt.sbprintf(&b, "      <StartBoundary>%s</StartBoundary>\n", at)
		w(&b, "      <Enabled>true</Enabled>\n")
		w(&b, "      <ScheduleByWeek>\n")
		fmt.sbprintf(
			&b,
			"        <DaysOfWeek>\n          <%s />\n        </DaysOfWeek>\n",
			TASK_DAYS[e.timing.weekday],
		)
		w(&b, "        <WeeksInterval>1</WeeksInterval>\n")
		w(&b, "      </ScheduleByWeek>\n")
		w(&b, "    </CalendarTrigger>\n")
	}
	w(&b, "  </Triggers>\n")

	w(&b, "  <Principals>\n")
	w(&b, "    <Principal id=\"Author\">\n")
	if e.system {
		w(&b, "      <UserId>S-1-5-18</UserId>\n")
		w(&b, "      <RunLevel>HighestAvailable</RunLevel>\n")
	} else {
		w(&b, "      <LogonType>InteractiveToken</LogonType>\n")
		w(&b, "      <RunLevel>LeastPrivilege</RunLevel>\n")
	}
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
	fmt.sbprintf(&b, "      <Command>%s</Command>\n", escape_xml(windows_quote(argv[0])))
	args := make([dynamic]string, context.temp_allocator)
	for arg in argv[1:] {
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

// windows_split splits a command line as windows_quote quotes one, back into its
// arguments.
windows_split :: proc(line: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(line) {
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
			i += 1
		}
		if i == len(line) {
			break
		}
		strings.builder_reset(&b)
		quoted := false
		for i < len(line) && (quoted || (line[i] != ' ' && line[i] != '\t')) {
			slashes := 0
			for i < len(line) && line[i] == '\\' {
				slashes += 1
				i += 1
			}
			if i < len(line) && line[i] == '"' {
				for _ in 0 ..< slashes / 2 {
					strings.write_byte(&b, '\\')
				}
				if slashes % 2 == 1 {
					strings.write_byte(&b, '"')
				} else {
					quoted = !quoted
				}
				i += 1
				continue
			}
			for _ in 0 ..< slashes {
				strings.write_byte(&b, '\\')
			}
			if slashes == 0 && i < len(line) && (quoted || (line[i] != ' ' && line[i] != '\t')) {
				strings.write_byte(&b, line[i])
				i += 1
			}
		}
		append(&out, strings.clone(strings.to_string(b), allocator))
	}
	return out[:]
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
