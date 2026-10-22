#+build linux
package journal

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "jm:sh"

import "../kstat"


// packaged is whether a .deb or .rpm installed the service, and so owns it.
packaged :: proc() -> bool {
	return os.exists(PACKAGE_UNIT_PATH)
}

// service_binary is the copy of leita the service runs: the one leita journal
// on put in place, which overrides a package's, else the package's.
service_binary :: proc() -> string {
	return PACKAGE_BINARY_PATH if packaged() && !os.exists(UNIT_PATH) else BINARY_PATH
}

/*
switch_on starts the recorder. Where a package installed the service, it
enables and starts that one; otherwise it copies this binary to BINARY_PATH,
root's and not writable by anyone else, writes the service that runs it and
starts it. Either way it restarts one already running, so a newer copy takes
over. It says why it could not, or "".
*/
switch_on :: proc() -> string {
	if service_binary() == PACKAGE_BINARY_PATH {
		return enable_packaged()
	}
	exe, exe_err := os.get_executable_path(context.temp_allocator)
	if exe_err != nil {
		return fmt.tprintf("cannot find this program: %v", exe_err)
	}
	dir_perm := os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}
	for d in ([]string{BINARY_DIR, DIR}) {
		if err := os.make_directory_all(d, dir_perm); err != nil && err != .Exist {
			return fmt.tprintf("cannot make %s: %v", d, err)
		}
	}
	if exe != BINARY_PATH {
		fresh := BINARY_PATH + ".new"
		if err := os.copy_file(fresh, exe); err != nil {
			return fmt.tprintf("cannot copy %s to %s: %v", exe, fresh, err)
		}
		if err := os.change_mode(fresh, dir_perm); err != nil {
			os.remove(fresh)
			return fmt.tprintf("cannot make %s executable: %v", fresh, err)
		}
		if err := os.rename(fresh, BINARY_PATH); err != nil {
			os.remove(fresh)
			return fmt.tprintf("cannot put %s in place: %v", BINARY_PATH, err)
		}
	}
	if err := os.write_entire_file(UNIT_PATH, unit_text(), Permissions_Log); err != nil {
		return fmt.tprintf("cannot write %s: %v", UNIT_PATH, err)
	}
	steps := [][]string {
		{"systemctl", "daemon-reload"},
		{"systemctl", "enable", SERVICE},
		{"systemctl", "restart", SERVICE},
	}
	for step in steps {
		if r := sh.exec(kstat.resolve_command(step), {}, context.temp_allocator); !r.ok {
			return sh.error(r, context.temp_allocator)
		}
	}
	return ""
}

// enable_packaged enables and starts the service a package installed, making
// the folder its ReadWritePaths names first: a path there without a "-" prefix
// must exist, or the service fails to set up its namespace (systemd.exec(5),
// ReadWritePaths=).
@(private = "file")
enable_packaged :: proc() -> string {
	dir_perm := os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}
	if err := os.make_directory_all(DIR, dir_perm); err != nil && err != .Exist {
		return fmt.tprintf("cannot make %s: %v", DIR, err)
	}
	steps := [][]string{{"systemctl", "enable", SERVICE}, {"systemctl", "restart", SERVICE}}
	for step in steps {
		if r := sh.exec(kstat.resolve_command(step), {}, context.temp_allocator); !r.ok {
			return sh.error(r, context.temp_allocator)
		}
	}
	return ""
}

/*
switch_off stops the service and removes everything switch_on made: the service,
the copy of leita, and the logs, which a recorder started again would not trust.
A service a package installed is disabled and left for the package to remove.
*/
switch_off :: proc() -> string {
	if os.exists(UNIT_PATH) || packaged() {
		sh.exec(kstat.resolve_command({"systemctl", "disable", "--now", SERVICE}), {}, context.temp_allocator)
	}
	if os.exists(UNIT_PATH) {
		if err := os.remove(UNIT_PATH); err != nil && err != .Not_Exist {
			return fmt.tprintf("cannot delete %s: %v", UNIT_PATH, err)
		}
		sh.exec({"systemctl", "daemon-reload"}, {}, context.temp_allocator)
		sh.exec({"systemctl", "reset-failed", SERVICE}, {}, context.temp_allocator)
	}
	for path in ([]string{BINARY_PATH, BINARY_DIR}) {
		if err := os.remove(path); err != nil && err != .Not_Exist {
			return fmt.tprintf("cannot delete %s: %v", path, err)
		}
	}
	if err := os.remove_all(DIR); err != nil && err != .Not_Exist {
		return fmt.tprintf("cannot delete %s: %v", DIR, err)
	}
	// The folder above the logs is leita's own, and goes too once empty.
	os.remove(STATE_DIR)
	return ""
}

// installed is whether the recorder's service is written by leita journal on, or
// a package's enabled: a package installs it whether or not it is wanted.
installed :: proc() -> bool {
	if os.exists(UNIT_PATH) {
		return true
	}
	if !packaged() {
		return false
	}
	r := sh.exec({"systemctl", "is-enabled", SERVICE}, {}, context.temp_allocator)
	return r.ok && strings.trim_space(r.stdout) == "enabled"
}

// active is whether systemd says the recorder's service is running.
active :: proc() -> bool {
	r := sh.exec({"systemctl", "is-active", SERVICE}, {}, context.temp_allocator)
	return r.ok && strings.trim_space(r.stdout) == "active"
}

// log_tail is the size of the log at path, 0 when it cannot be read, and its last
// whole record.
@(private = "file")
log_tail :: proc(path: string) -> (size: i64, last: Record, ok: bool) {
	f, head, count, opened := open_log(path)
	if !opened {
		return 0, {}, false
	}
	defer os.close(f)
	size, _ = os.file_size(f)
	buf: [RECORD_SIZE]byte
	if count <= 0 || !read_full(f, buf[:], head.at + (count - 1) * RECORD_SIZE) {
		return size, {}, false
	}
	rec, got := record_get(buf[:])
	if !got {
		return size, {}, false
	}
	return size, rec, true
}

Filesystem_Status :: struct {
	mount, filesystem, reason: string,
	recorded:                  bool,
	size, last_written:        i64,
	has_last:                  bool,
}

Service_Status :: struct {
	installed, active: bool,
	now:               i64,
	filesystems:       [dynamic]Filesystem_Status,
}

// service_status reads the recorder's state; returned storage uses the temp allocator.
service_status :: proc() -> Service_Status {
	result := Service_Status {
		installed = installed(),
		now       = time.to_unix_nanoseconds(time.now()),
	}
	if result.installed {result.active = active()}
	result.filesystems = make([dynamic]Filesystem_Status, context.temp_allocator)
	status_path, _ := filepath.join({DIR, STATUS}, context.temp_allocator)
	data, err := os.read_entire_file(status_path, context.temp_allocator)
	if err != nil {return result}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 4 {continue}
		row := Filesystem_Status {
			mount      = f[1],
			filesystem = f[2],
		}
		switch f[0] {
		case "recorded":
			row.recorded = true
			log, _ := filepath.join({DIR, f[3]}, context.temp_allocator)
			last: Record
			row.size, last, row.has_last = log_tail(log)
			row.last_written = last.time
		case "skipped":
			row.reason = f[3]
		case:
			continue
		}
		append(&result.filesystems, row)
	}
	return result
}
