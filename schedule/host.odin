package sonar_schedule

import "core:encoding/csv"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "jm:sh"

/*
A Host is the system an entry is written to: where systemd's units live, and how a
command is run. The tests give it a temporary folder and a runner that records the
commands; sonar gives it the real ones (host_default). Both schedulers' code is
built on every system, so the tests read what Windows would be asked to do on
Linux too; add, list and remove pick the one this system runs.
*/

// Outcome is what running a command came to.
Outcome :: struct {
	ok:  bool,
	out: string,
	err: string, // what went wrong, for a person
}

// Runner runs argv and waits for it.
Runner :: #type proc(argv: []string, user: rawptr) -> Outcome

Host :: struct {
	run:   Runner,
	user:  rawptr, // the runner's own
	// Where user units go: $XDG_CONFIG_HOME/systemd/user. System units go to
	// SYSTEM_UNITS.
	units: string,
	// The user whose lingering decides whether user timers run logged out.
	login: string,
	// A folder to write a task's XML to while schtasks reads it.
	temp:  string,
}

// SYSTEM_UNITS is where systemd reads the units an administrator adds.
SYSTEM_UNITS :: "/etc/systemd/system"

// Listing is one entry as list finds it. Its fields are "" where the system does
// not say.
Listing :: struct {
	name, target, timing, next, last: string,
}

// host_default is this machine, its commands run for real.
host_default :: proc(allocator := context.temp_allocator) -> Host {
	h := Host {
		run   = run_command,
		login = os.get_env("USER", allocator),
	}
	config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if config == "" || !filepath.is_abs(config) {
		home := os.get_env("HOME", context.temp_allocator)
		config, _ = filepath.join({home, ".config"}, context.temp_allocator)
	}
	h.units, _ = filepath.join({config, "systemd", "user"}, allocator)
	h.temp, _ = os.temp_directory(allocator)
	return h
}

// run_command runs argv for real, through jm:sh.
run_command :: proc(argv: []string, _: rawptr) -> Outcome {
	r := sh.exec(argv, {}, context.temp_allocator)
	if r.ok {
		return {ok = true, out = r.stdout}
	}
	return {out = r.stdout, err = sh.error(r, context.temp_allocator)}
}

// add writes e to the system's scheduler and starts its clock, and says why it
// could not, or "".
add :: proc(h: Host, e: Entry, argv: []string) -> string {
	when ODIN_OS == .Windows {
		return add_task(h, e, argv)
	} else {
		return add_units(h, e, argv)
	}
}

// list is the entries sonar has made, by name.
list :: proc(h: Host, system: bool) -> (entries: []Listing, err: string) {
	when ODIN_OS == .Windows {
		return list_tasks(h)
	} else {
		return list_units(h, system)
	}
}

// remove stops the entry named name and deletes it, and says why it could not,
// or "".
remove :: proc(h: Host, name: string, system: bool) -> string {
	when ODIN_OS == .Windows {
		return remove_task(h, name)
	} else {
		return remove_units(h, name, system)
	}
}

// systemctl is systemctl's command line for the user's manager, or the system's.
@(private)
systemctl :: proc(system: bool, args: ..string) -> []string {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "systemctl")
	if !system {
		append(&argv, "--user")
	}
	append(&argv, ..args)
	return argv[:]
}

// unit_dir is where the units of a user's or the system's entry go.
@(private)
unit_dir :: proc(h: Host, system: bool) -> string {
	return SYSTEM_UNITS if system else h.units
}

// unit_paths are an entry's service and timer files.
@(private)
unit_paths :: proc(h: Host, name: string, system: bool) -> (service, timer: string) {
	dir := unit_dir(h, system)
	service, _ = filepath.join(
		{dir, fmt.tprintf("%s.service", unit(name))},
		context.temp_allocator,
	)
	timer, _ = filepath.join({dir, fmt.tprintf("%s.timer", unit(name))}, context.temp_allocator)
	return
}

// add_units writes the entry's service and timer, then has systemd load them
// and start the timer.
add_units :: proc(h: Host, e: Entry, argv: []string) -> string {
	dir := unit_dir(h, e.system)
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		return fmt.tprintf("cannot make %s: %v%s", dir, err, need_root(e.system))
	}
	service, timer := unit_paths(h, e.name, e.system)
	// The service names the webhook, which may carry a secret: only its owner reads it.
	if err := os.write_entire_file(service, service_text(e, argv), {.Read_User, .Write_User});
	   err != nil {
		return fmt.tprintf("cannot write %s: %v%s", service, err, need_root(e.system))
	}
	if err := os.write_entire_file(timer, timer_text(e)); err != nil {
		os.remove(service)
		return fmt.tprintf("cannot write %s: %v%s", timer, err, need_root(e.system))
	}
	steps := [][]string {
		systemctl(e.system, "daemon-reload"),
		systemctl(e.system, "enable", "--now", fmt.tprintf("%s.timer", unit(e.name))),
	}
	for step in steps {
		if r := h.run(step, h.user); !r.ok {
			os.remove(service)
			os.remove(timer)
			h.run(systemctl(e.system, "daemon-reload"), h.user)
			return fmt.tprintf("%s%s", r.err, need_root(e.system))
		}
	}
	if !e.system && h.login != "" {
		r := h.run({"loginctl", "show-user", h.login, "-p", "Linger"}, h.user)
		if r.ok && strings.trim_space(r.out) == "Linger=no" {
			fmt.printfln(
				"note: %s's timers run only while %s is logged in; to run them always: loginctl enable-linger %s",
				h.login,
				h.login,
				h.login,
			)
		}
	}
	if strings.has_prefix(e.target, "/dev/") && !e.system {
		fmt.printfln(
			"note: reading %s needs the disk group (sudo usermod -aG disk %s), or --system to scan as root",
			e.target,
			h.login if h.login != "" else "$USER",
		)
	}
	return ""
}

// need_root says that a system entry needs root, for a failure that may be why.
@(private)
need_root :: proc(system: bool) -> string {
	return " (a --system entry needs root: run it with sudo)" if system else ""
}

// list_units reads the timers sonar wrote, and asks systemd when each runs next
// and how its last run went.
list_units :: proc(h: Host, system: bool) -> (entries: []Listing, err: string) {
	dir := unit_dir(h, system)
	found := make([dynamic]Listing, context.temp_allocator)
	infos, rerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if rerr != nil {
		if rerr == .Not_Exist {
			return nil, ""
		}
		return nil, fmt.tprintf("cannot read %s: %v", dir, rerr)
	}
	for fi in infos {
		if !strings.has_prefix(fi.name, PREFIX) || !strings.has_suffix(fi.name, ".timer") {
			continue
		}
		base := strings.trim_suffix(fi.name, ".timer")
		data, ferr := os.read_entire_file(fi.fullpath, context.temp_allocator)
		if ferr != nil {
			continue
		}
		text := string(data)
		l := Listing {
			name   = base[len(PREFIX):],
			target = unit_value(text, "X-Sonar-Target"),
			timing = unit_value(text, "X-Sonar-Schedule"),
		}
		if r := h.run(systemctl(system, "show", fi.name, "-p", "NextElapseUSecRealtime"), h.user);
		   r.ok {
			l.next = unit_value(r.out, "NextElapseUSecRealtime")
		}
		service := fmt.tprintf("%s.service", base)
		if r := h.run(
			systemctl(
				system,
				"show",
				service,
				"-p",
				"ExecMainExitTimestamp",
				"-p",
				"ExecMainStatus",
			),
			h.user,
		); r.ok {
			if at := unit_value(r.out, "ExecMainExitTimestamp"); at != "" {
				code, _ := strconv.parse_int(unit_value(r.out, "ExecMainStatus"))
				l.last = fmt.tprintf("%s at %s", last_result(code), at)
			}
		}
		append(&found, l)
	}
	slice.sort_by(found[:], proc(a, b: Listing) -> bool {return a.name < b.name})
	return found[:], ""
}

// remove_units stops and disables the entry's timer, deletes both its units, and
// has systemd forget them.
remove_units :: proc(h: Host, name: string, system: bool) -> string {
	service, timer := unit_paths(h, name, system)
	if !os.exists(service) && !os.exists(timer) {
		return fmt.tprintf("no entry named %s in %s", name, unit_dir(h, system))
	}
	h.run(systemctl(system, "disable", "--now", fmt.tprintf("%s.timer", unit(name))), h.user)
	for path in ([]string{timer, service}) {
		if err := os.remove(path); err != nil && err != .Not_Exist {
			return fmt.tprintf("cannot delete %s: %v%s", path, err, need_root(system))
		}
	}
	h.run(systemctl(system, "daemon-reload"), h.user)
	h.run(
		systemctl(
			system,
			"reset-failed",
			fmt.tprintf("%s.timer", unit(name)),
			fmt.tprintf("%s.service", unit(name)),
		),
		h.user,
	)
	return ""
}

// add_task writes the entry's task XML to a file and has schtasks make the task
// from it, replacing one of the same name.
add_task :: proc(h: Host, e: Entry, argv: []string) -> string {
	path, _ := filepath.join({h.temp, fmt.tprintf("%s.xml", unit(e.name))}, context.temp_allocator)
	if err := os.write_entire_file(path, utf16_file(task_xml(e, argv))); err != nil {
		return fmt.tprintf("cannot write %s: %v", path, err)
	}
	defer os.remove(path)
	create := make([dynamic]string, context.temp_allocator)
	append(&create, "schtasks", "/Create", "/XML", path, "/TN", task_name(e.name), "/F")
	if e.system {
		append(&create, "/RU", "SYSTEM")
	}
	if r := h.run(create[:], h.user); !r.ok {
		return fmt.tprintf(
			"%s%s",
			r.err,
			" (a --system entry needs an administrator prompt)" if e.system else "",
		)
	}
	if !e.system {
		fmt.println(
			"note: the task runs as you while you are logged on, and reads the MFT only from an elevated prompt; " +
			"add it with --system from an administrator prompt to scan elevated whoever is logged on",
		)
	}
	return ""
}

// NEVER_RAN is the last result Task Scheduler gives a task that has not run:
// SCHED_S_TASK_HAS_NOT_RUN, in the Task Scheduler error and success constants.
NEVER_RAN :: 0x41303

// list_tasks asks schtasks for every task and keeps those in sonar's folder.
list_tasks :: proc(h: Host) -> (entries: []Listing, err: string) {
	r := h.run({"schtasks", "/Query", "/FO", "CSV", "/V"}, h.user)
	if !r.ok {
		return nil, r.err
	}
	return tasks_from_csv(r.out), ""
}

/*
tasks_from_csv reads sonar's tasks out of `schtasks /Query /FO CSV /V`, whose
columns begin, in English: host, task name, next run, status, logon mode, last run,
last result, author, task to run, start in, comment. They are read by position,
since their headers follow the display language. A task with several triggers is
listed once a trigger, and the header may repeat.
*/
tasks_from_csv :: proc(text: string) -> []Listing {
	r: csv.Reader
	csv.reader_init_with_string(&r, text, context.temp_allocator)
	r.fields_per_record = -1
	rows, _ := csv.read_all(&r, context.temp_allocator)
	found := make([dynamic]Listing, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	prefix := `\` + TASK_FOLDER
	for row in rows {
		if len(row) < 11 || !strings.has_prefix(row[1], prefix) {
			continue
		}
		name := row[1][len(prefix):]
		if seen[name] {
			continue
		}
		seen[name] = true
		l := Listing {
			name   = name,
			timing = row[10],
			next   = row[2],
		}
		if run := windows_split(row[8]); len(run) > 1 {
			l.target = run[1]
		}
		if code, ok := strconv.parse_int(row[6]); ok && code != NEVER_RAN {
			l.last = fmt.tprintf("%s at %s", last_result(code), row[5])
		}
		append(&found, l)
	}
	slice.sort_by(found[:], proc(a, b: Listing) -> bool {return a.name < b.name})
	return found[:]
}

// remove_task deletes the entry's task.
remove_task :: proc(h: Host, name: string) -> string {
	if r := h.run({"schtasks", "/Delete", "/TN", task_name(name), "/F"}, h.user); !r.ok {
		return r.err
	}
	return ""
}
