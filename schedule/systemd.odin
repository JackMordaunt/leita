package leita_schedule

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

/*
On Linux the entry is a pair of systemd user units: leita-monitor.service runs
the monitor once, and leita-monitor.timer starts it every hour. Persistent=true
has systemd remember when the timer last fired, so a run missed while the
machine was off or asleep runs once when it is next up; a oneshot service that
is still running when the timer fires again is not started twice. The run
starts somewhere in the first minutes of the hour, at low CPU and idle I/O
priority, so the machine stays usable while it scans. systemd.timer(5),
systemd.service(5) and systemd.exec(5) give each key, and ExecStart='s quoting
and its % and $ escapes.
*/

// SPREAD is how far past the hour a run may start.
SPREAD :: "5min"

// service_text is the service unit that runs argv once.
service_text :: proc(argv: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "[Unit]\nDescription=leita: scan the watched places\n\n")
	strings.write_string(&b, "[Service]\nType=oneshot\nExecStart=")
	for arg, i in argv {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, systemd_quote(arg))
	}
	strings.write_string(&b, "\nNice=10\nIOSchedulingClass=idle\n")
	return strings.to_string(b)
}

// timer_text is the timer unit that starts the service every hour.
timer_text :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "[Unit]\nDescription=leita: scan the watched places when due\n\n")
	fmt.sbprintf(
		&b,
		"[Timer]\nOnCalendar=hourly\nPersistent=true\nRandomizedDelaySec=%s\n",
		SPREAD,
	)
	strings.write_string(&b, "\n[Install]\nWantedBy=timers.target\n")
	return strings.to_string(b)
}

/*
systemd_quote is arg as one word of a systemd command line: quoted when it holds
what would split or escape it, with '%' and '$' doubled so systemd expands
neither a specifier nor a variable in it.
*/
systemd_quote :: proc(arg: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	quote := arg == "" || strings.index_any(arg, " \t\n\"'\\;") >= 0
	if quote {
		strings.write_byte(&b, '"')
	}
	for c in transmute([]byte)arg {
		switch c {
		case '"', '\\':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case '\n':
			strings.write_string(&b, `\n`)
		case '\t':
			strings.write_string(&b, `\t`)
		case '%', '$':
			strings.write_byte(&b, c)
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, c)
		}
	}
	if quote {
		strings.write_byte(&b, '"')
	}
	return strings.to_string(b)
}

// systemctl is systemctl's command line for the user's manager.
@(private)
systemctl :: proc(args: ..string) -> []string {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "systemctl", "--user")
	append(&argv, ..args)
	return argv[:]
}

// unit_paths are the entry's service and timer files.
@(private)
unit_paths :: proc(h: Host) -> (service, timer: string) {
	service, _ = filepath.join({h.units, NAME + ".service"}, context.temp_allocator)
	timer, _ = filepath.join({h.units, NAME + ".timer"}, context.temp_allocator)
	return
}

// install_units writes the service and the timer, then has systemd load them
// and start the timer.
@(private)
install_units :: proc(h: Host, argv: []string) -> (problem: string, logged_in_only: bool) {
	if err := os.make_directory_all(h.units); err != nil && err != .Exist {
		return fmt.tprintf("cannot make %s: %v", h.units, err), false
	}
	service, timer := unit_paths(h)
	if err := os.write_entire_file(service, service_text(argv)); err != nil {
		return fmt.tprintf("cannot write %s: %v", service, err), false
	}
	if err := os.write_entire_file(timer, timer_text()); err != nil {
		os.remove(service)
		return fmt.tprintf("cannot write %s: %v", timer, err), false
	}
	steps := [][]string{systemctl("daemon-reload"), systemctl("enable", "--now", NAME + ".timer")}
	for step in steps {
		if r := h.run(step, h.user); !r.ok {
			os.remove(service)
			os.remove(timer)
			h.run(systemctl("daemon-reload"), h.user)
			return r.err, false
		}
	}
	return "", logged_in_only_systemd(h)
}

// logged_in_only_systemd is whether the person's user timers run only while
// they are logged in: they do unless loginctl says they linger.
@(private)
logged_in_only_systemd :: proc(h: Host) -> bool {
	if h.login == "" {
		return false
	}
	r := h.run({"loginctl", "show-user", h.login, "-p", "Linger"}, h.user)
	return r.ok && strings.trim_space(r.out) == "Linger=no"
}

// remove_units stops and disables the timer, deletes both units, and has
// systemd forget them. Disable runs even when the files are already gone,
// so a deleted unit file does not skip it and leave monitor off saying the
// timer had stopped.
@(private)
remove_units :: proc(h: Host) -> string {
	r := h.run(systemctl("disable", "--now", NAME + ".timer"), h.user)
	if !r.ok && !not_loaded(r) {
		return r.err
	}
	service, timer := unit_paths(h)
	for path in ([]string{timer, service}) {
		if err := os.remove(path); err != nil && err != .Not_Exist {
			return fmt.tprintf("cannot delete %s: %v", path, err)
		}
	}
	h.run(systemctl("daemon-reload"), h.user)
	h.run(systemctl("reset-failed", NAME + ".timer", NAME + ".service"), h.user)
	return ""
}
