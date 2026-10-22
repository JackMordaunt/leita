package leita_schedule

import "core:os"
import "core:path/filepath"
import "core:strings"

import "../kstat"

/*
The program an entry runs is the path leita was started by, kept as it was
typed, rather than the executable's resolved path: a Homebrew leita is
/opt/homebrew/bin/leita, a link into a versioned folder,
/opt/homebrew/Cellar/leita/<version>/bin/leita, which the next upgrade replaces
and brew cleanup deletes, after which an entry naming it would silently never
start again.
*/

/*
stable_program is the program path an entry records for the leita started as
arg0 (os.args[0]), whose executable the system resolved to exe
(os.get_executable_path), with the PATH that found it. The rule: an executable
inside an application bundle, under .app/Contents/, keeps that path, since the
bundle is how it is installed and moved: Leita.app's window in Contents/MacOS,
and its command line in Contents/Helpers even when started through a link on
PATH, since Odin's os.get_executable_path on macOS (core/os/path_darwin.odin)
is proc_pidpath, the path of the file the process runs, links resolved; an arg0 with a directory in it is made
absolute against cwd and cleaned, its links kept; a bare name is looked for on
each folder of PATH, and the first that is this same executable is kept, links
too, since a second install of the same name is a different file and must not
be the one an entry runs; and a bare name found nowhere falls back to exe.
*/
stable_program :: proc(
	arg0, exe, path_list, cwd: string,
	allocator := context.allocator,
) -> string {
	if strings.contains(exe, ".app/Contents/") {
		return strings.clone(exe, allocator)
	}
	if arg0 == "" {
		return strings.clone(exe, allocator)
	}
	if strings.contains_any(arg0, `/\`) {
		path := arg0
		if !filepath.is_abs(path) {
			path, _ = filepath.join({cwd, arg0}, context.temp_allocator)
		}
		path, _ = filepath.clean(path, allocator)
		return path
	}
	folders, _ := filepath.split_list(path_list, context.temp_allocator)
	for folder in folders {
		if folder == "" {
			continue
		}
		for name in program_names(arg0) {
			path, _ := filepath.join({folder, name}, context.temp_allocator)
			if same_executable(path, exe) {
				return strings.clone(path, allocator)
			}
		}
	}
	return strings.clone(exe, allocator)
}

// same_executable reports whether the file at path is the one at exe.
// os.stat follows links, so a PATH entry is kept when it is the running
// program and skipped when it is another install of the same name. Windows
// folds case: the two strings are one path.
@(private)
same_executable :: proc(path, exe: string) -> bool {
	found, found_err := kstat.stat(path, context.temp_allocator)
	if found_err != nil {
		return false
	}
	running, running_err := kstat.stat(exe, context.temp_allocator)
	if running_err != nil {
		return false
	}
	when ODIN_OS == .Windows {
		return strings.equal_fold(found.fullpath, running.fullpath)
	} else {
		return found.fullpath == running.fullpath
	}
}

// program_names are the file names a bare program name may stand for on PATH:
// itself, and on Windows itself with .exe, as cmd finds it.
@(private)
program_names :: proc(arg0: string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	append(&names, arg0)
	when ODIN_OS == .Windows {
		if strings.index_byte(arg0, '.') < 0 {
			append(&names, strings.concatenate({arg0, ".exe"}, context.temp_allocator))
		}
	}
	return names[:]
}

// this_program is stable_program for this process, in allocator.
this_program :: proc(allocator := context.allocator) -> string {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		exe = os.args[0]
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return stable_program(
		os.args[0],
		exe,
		os.get_env("PATH", context.temp_allocator),
		cwd,
		allocator,
	)
}

// program is the program the installed entry runs, as the entry says it, or
// "" when there is no entry or it cannot be read.
program :: proc(h: Host, allocator := context.temp_allocator) -> string {
	switch h.system {
	case .Systemd:
		service, _ := unit_paths(h)
		text, err := os.read_entire_file(service, context.temp_allocator)
		if err != nil {
			return ""
		}
		return service_program(string(text), allocator)
	case .Task_Scheduler:
		r := h.run({"schtasks", "/Query", "/TN", TASK_NAME, "/XML"}, h.user)
		if !r.ok {
			return ""
		}
		return task_program(r.out, allocator)
	case .Launchd:
		text, err := os.read_entire_file(agent_path(h), context.temp_allocator)
		if err != nil {
			return ""
		}
		return agent_program(string(text), allocator)
	}
	return ""
}

/*
loaded is whether the scheduler itself has the entry, asked of it rather than of
the file: launchd through launchctl print, which fails for a label it does not
hold; systemd through is-enabled; Task Scheduler through a query.
*/
loaded :: proc(h: Host) -> bool {
	switch h.system {
	case .Systemd:
		return h.run(systemctl("is-enabled", NAME + ".timer"), h.user).ok
	case .Task_Scheduler:
		return h.run({"schtasks", "/Query", "/TN", TASK_NAME}, h.user).ok
	case .Launchd:
		return h.run({"launchctl", "print", agent_target(h)}, h.user).ok
	}
	return false
}

// log_path is the file the scheduler writes the monitor's output to, "" where
// the scheduler keeps it itself, as systemd's journal does.
log_path :: proc(h: Host) -> string {
	if h.system == .Launchd {
		return h.log
	}
	return ""
}

// agent_program is the first of the agent's ProgramArguments, or "".
agent_program :: proc(plist: string, allocator := context.temp_allocator) -> string {
	_, key, after := strings.partition(plist, "<key>ProgramArguments</key>")
	if key == "" {
		return ""
	}
	_, open, rest := strings.partition(after, "<string>")
	if open == "" {
		return ""
	}
	arg, end, _ := strings.partition(rest, "</string>")
	if end == "" {
		return ""
	}
	return unescape_xml(arg, allocator)
}

// service_program is the first word of the service's ExecStart, or "".
service_program :: proc(unit: string, allocator := context.temp_allocator) -> string {
	rest := unit
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "ExecStart=") {
			return systemd_unquote(strings.trim_prefix(line, "ExecStart="), allocator)
		}
	}
	return ""
}

// task_program is the program the task runs, as schtasks /Query /XML gives it, or
// "": the Command, or when that is the console host task_xml runs it through, the
// first argument after its switch.
task_program :: proc(xml: string, allocator := context.temp_allocator) -> string {
	command := xml_text(xml, "Command")
	if command == "" {
		return ""
	}
	program := windows_unquote(unescape_xml(command, context.temp_allocator), allocator)
	if !strings.equal_fold(program, HEADLESS_HOST) {
		return program
	}
	arguments := unescape_xml(xml_text(xml, "Arguments"), context.temp_allocator)
	arguments = strings.trim_left_space(
		strings.trim_prefix(strings.trim_left_space(arguments), HEADLESS),
	)
	return first_argument(arguments, allocator)
}

// xml_text is the text of the first element of the given name, or "".
@(private)
xml_text :: proc(xml, name: string) -> string {
	_, open, after := strings.partition(
		xml,
		strings.concatenate({"<", name, ">"}, context.temp_allocator),
	)
	if open == "" {
		return ""
	}
	text, end, _ := strings.partition(
		after,
		strings.concatenate({"</", name, ">"}, context.temp_allocator),
	)
	if end == "" {
		return ""
	}
	return text
}

// first_argument is the first argument of a Windows command line, as
// windows_quote wrote it, or "".
@(private)
first_argument :: proc(line: string, allocator := context.temp_allocator) -> string {
	if strings.has_prefix(line, `"`) {
		return windows_unquote(line, allocator)
	}
	end := strings.index_any(line, " \t")
	if end < 0 {
		end = len(line)
	}
	return strings.clone(line[:end], allocator)
}

// systemd_unquote is the first word of a systemd command line, as systemd_quote
// wrote it: unquoted, with each escape and doubled '%' or '$' undone.
systemd_unquote :: proc(line: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	s := strings.trim_left_space(line)
	quoted := strings.has_prefix(s, `"`)
	if quoted {
		s = s[1:]
	}
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case quoted && c == '"':
			return strings.to_string(b)
		case !quoted && (c == ' ' || c == '\t'):
			return strings.to_string(b)
		case c == '\\' && i + 1 < len(s):
			i += 1
			switch s[i] {
			case 'n':
				strings.write_byte(&b, '\n')
			case 't':
				strings.write_byte(&b, '\t')
			case:
				strings.write_byte(&b, s[i])
			}
		case (c == '%' || c == '$') && i + 1 < len(s) && s[i + 1] == c:
			i += 1
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// windows_unquote is one argument of a Windows command line as windows_quote
// wrote it, with the quotes and their escapes undone.
windows_unquote :: proc(arg: string, allocator := context.temp_allocator) -> string {
	if !strings.has_prefix(arg, `"`) {
		return strings.clone(arg, allocator)
	}
	b := strings.builder_make(allocator)
	slashes := 0
	for c in transmute([]byte)arg[1:] {
		switch c {
		case '\\':
			slashes += 1
			continue
		case '"':
			for _ in 0 ..< slashes / 2 {
				strings.write_byte(&b, '\\')
			}
			if slashes % 2 == 0 {
				return strings.to_string(b)
			}
			strings.write_byte(&b, '"')
		case:
			for _ in 0 ..< slashes {
				strings.write_byte(&b, '\\')
			}
			strings.write_byte(&b, c)
		}
		slashes = 0
	}
	for _ in 0 ..< slashes / 2 {
		strings.write_byte(&b, '\\')
	}
	return strings.to_string(b)
}

// unescape_xml undoes escape_xml.
unescape_xml :: proc(s: string, allocator := context.temp_allocator) -> string {
	out := s
	pairs := [][2]string {
		{"&lt;", "<"},
		{"&gt;", ">"},
		{"&quot;", `"`},
		{"&apos;", "'"},
		{"&amp;", "&"},
	}
	for p in pairs {
		out, _ = strings.replace_all(out, p[0], p[1], context.temp_allocator)
	}
	return strings.clone(out, allocator)
}
