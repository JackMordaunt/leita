/*
Package schedule hands the monitor to the operating system's scheduler rather
than keeping a process of its own running: a systemd user timer on Linux, a Task
Scheduler task on Windows, a launchd agent on macOS. There is one entry, which
runs `leita monitor run` every hour; the monitor itself decides which watched
places are due, so a place's schedule changes without the entry changing.

A run missed while the machine was asleep or off runs once when it is next up,
never once a slot, and a run never starts while the last is still going.

What each entry says is made by pure procedures, so the tests read it on any
system: service_text and timer_text (systemd.odin), task_xml (task.odin) and
agent_plist (launchd.odin). What touches the system goes through a Host, whose
runner a test replaces to record the commands rather than run them, and whose
folders a test points at a temporary one, so no test touches the real scheduler.
*/
package leita_schedule

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "jm:sh"

// NAME is what the entry is called: the systemd units leita-monitor.service and
// .timer, and the launchd agent's file. Task Scheduler's is TASK_NAME, and
// launchd's label AGENT_LABEL.
NAME :: "leita-monitor"

// System is a scheduler leita can hand the monitor to.
System :: enum u8 {
	Systemd,
	Task_Scheduler,
	Launchd,
}

// Linger is whether a systemd user timer keeps running after the person logs
// out. Unknown means that could not be read, which is not a claim that it
// keeps running.
Linger :: enum u8 {
	Unknown,
	While_Logged_In,
	Always,
}

// SYSTEM is this machine's scheduler.
when ODIN_OS == .Windows {
	SYSTEM :: System.Task_Scheduler
} else when ODIN_OS == .Darwin {
	SYSTEM :: System.Launchd
} else {
	SYSTEM :: System.Systemd
}

// Outcome is what running a command came to.
Outcome :: struct {
	ok:  bool,
	out: string,
	err: string, // what went wrong, for a person
}

// Runner runs argv and waits for it.
Runner :: #type proc(argv: []string, user: rawptr) -> Outcome

/*
A Host is the system the entry is written to: where each scheduler reads its
entries from, and how a command is run. The tests give it temporary folders and
a runner that records the commands; leita gives it the real ones (host_default).
*/
Host :: struct {
	run:    Runner,
	user:   rawptr, // the runner's own
	system: System,
	// Where systemd reads user units: $XDG_CONFIG_HOME/systemd/user.
	units:  string,
	// Where launchd reads the user's agents: ~/Library/LaunchAgents.
	agents: string,
	// The user's id, for launchctl's gui/<uid> domain.
	uid:    string,
	// The file launchd writes the monitor's output to: ~/Library/Logs/leita/monitor.log.
	log:    string,
	// Who is logged in, whose lingering decides whether user timers run while
	// they are logged out.
	login:  string,
	// A folder to write a task's XML to while schtasks reads it.
	temp:   string,
}

// host_default is this machine, its commands run for real, in allocator.
host_default :: proc(allocator := context.allocator) -> Host {
	h := Host {
		run    = run_command,
		system = SYSTEM,
		uid    = user_id(allocator),
	}
	home := os.get_env("HOME", context.temp_allocator)
	config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if config == "" || !filepath.is_abs(config) {
		config, _ = filepath.join({home, ".config"}, context.temp_allocator)
	}
	h.units, _ = filepath.join({config, "systemd", "user"}, allocator)
	h.agents, _ = filepath.join({home, "Library", "LaunchAgents"}, allocator)
	h.log, _ = filepath.join({home, "Library", "Logs", "leita", "monitor.log"}, allocator)
	h.login = os.get_env("USER", allocator)
	h.temp, _ = os.temp_directory(allocator)
	return h
}

// host_destroy frees what host_default made.
host_destroy :: proc(h: ^Host, allocator := context.allocator) {
	delete(h.units, allocator)
	delete(h.agents, allocator)
	delete(h.uid, allocator)
	delete(h.log, allocator)
	delete(h.login, allocator)
	delete(h.temp, allocator)
	h^ = {}
}

// run_command runs argv for real, through jm:sh.
run_command :: proc(argv: []string, _: rawptr) -> Outcome {
	r := sh.exec(argv, {}, context.temp_allocator)
	if r.ok {
		return {ok = true, out = r.stdout}
	}
	return {out = r.stdout, err = sh.error(r, context.temp_allocator)}
}

/*
install writes the entry that runs argv every hour to the host's scheduler and
starts it, replacing one there before. It says why it could not, or "", and
whether a systemd user timer keeps running after logout. uid 0 is refused:
the entry would be installed for root. list and off are not, so one made by
mistake can still be taken back.
*/
install :: proc(h: Host, argv: []string) -> (problem: string, linger: Linger) {
	assert(len(argv) > 0, "an entry runs a program")
	if h.uid == "0" {
		return "cannot schedule monitoring as root: it would be installed for root, not for you",
			.Unknown
	}
	switch h.system {
	case .Systemd:
		return install_units(h, argv)
	case .Task_Scheduler:
		return install_task(h, argv), .Always
	case .Launchd:
		return install_agent(h, argv), .Always
	}
	return
}

// linger is whether the entry keeps running after the person logs out. It
// can be asked before install. Anything but a systemd user timer is Always,
// so no logged-out warning is given for it.
linger :: proc(h: Host) -> Linger {
	if h.system != .Systemd {
		return .Always
	}
	return linger_systemd(h)
}

// remove stops the entry and deletes it, and says why it could not, or "". An
// entry that is not there is already removed.
remove :: proc(h: Host) -> string {
	switch h.system {
	case .Systemd:
		return remove_units(h)
	case .Task_Scheduler:
		return remove_task(h)
	case .Launchd:
		return remove_agent(h)
	}
	return ""
}

/*
installed is whether the entry is in the host's scheduler. A file that is
there counts. When the file is gone, systemd is asked with is-active and
launchd with print, so a missing file is not read as a missing job.
*/
installed :: proc(h: Host) -> bool {
	switch h.system {
	case .Systemd:
		_, timer := unit_paths(h)
		if os.exists(timer) {
			return true
		}
		return h.run(systemctl("is-active", NAME + ".timer"), h.user).ok
	case .Task_Scheduler:
		return h.run({"schtasks", "/Query", "/TN", TASK_NAME}, h.user).ok
	case .Launchd:
		if os.exists(agent_path(h)) {
			return true
		}
		return h.run({"launchctl", "print", agent_target(h)}, h.user).ok
	}
	return false
}

// not_loaded is whether stopping the entry failed because the scheduler does
// not have it, which is already what remove wants. "inactive" is deliberately
// not that: it is a timer that is loaded and not running.
@(private)
not_loaded :: proc(r: Outcome) -> bool {
	if r.ok {
		return false
	}
	text := strings.to_lower(r.err, context.temp_allocator)
	out := strings.to_lower(r.out, context.temp_allocator)
	phrases := [?]string {
		"does not exist",
		"not-found",
		"not found",
		"could not be found",
		"no such process",
		"not loaded",
		"could not find",
	}
	for phrase in phrases {
		if strings.contains(text, phrase) || strings.contains(out, phrase) {
			return true
		}
	}
	return false
}

// describe says where the entry lives, as a person would look for it.
describe :: proc(h: Host, allocator := context.temp_allocator) -> string {
	switch h.system {
	case .Systemd:
		return fmt.aprintf("systemd user timer %s.timer", NAME, allocator = allocator)
	case .Task_Scheduler:
		return fmt.aprintf("Task Scheduler task %s", TASK_NAME, allocator = allocator)
	case .Launchd:
		return fmt.aprintf("launchd agent %s", AGENT_LABEL, allocator = allocator)
	}
	return ""
}
