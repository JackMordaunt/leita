/*
Package journeys runs the built command line the way a person does, as a process,
on the made-up disk, and tests what comes back: standard output, standard error,
the exit code, the files it leaves. Nothing here calls into leita, so a journey
sees what a release would: its flags, its exit codes, the data it keeps.

just journeys builds the command line and runs these tests. LEITA_BIN names
another binary.

A journey owns a Home: a folder with the data, config and state folders the run
keeps its history, settings and trial in, so no journey sees another's, nor the
person's own. Day is the made-up disk's day (scan.SYNTHETIC_ENV): a later day has
grown, so two scans of different days are a change to compare.
*/
package journeys

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Home is one person's machine for a journey: a folder the process runs as the
// owner of.
Home :: struct {
	dir: string,
}

// Result is what a run left: its streams as text and its exit code.
Result :: struct {
	out:  string,
	err:  string,
	code: int,
}

// binary is the command line under test.
binary :: proc() -> string {
	if path := os.get_env("LEITA_BIN", context.temp_allocator); path != "" {
		return path
	}
	return "build/debug/leita" + (".exe" when ODIN_OS == .Windows else "")
}

// BUDGET is the time a journey may take before the runner fails it by name,
// so one that hangs does not hold the run until the job's timeout. The whole
// package, its journeys side by side, took 4m24s under AddressSanitizer on the
// hosted Linux runner (test run 40104162883); one journey gets less than that.
BUDGET :: 5 * time.Minute

// home makes a fresh Home named for the journey, and removes any left by an
// earlier run of it. The journey's BUDGET starts here.
home :: proc(t: ^testing.T, name: string) -> Home {
	testing.set_fail_timeout(t, BUDGET)
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.tprintf("%s/leita_journey_%s_%d", tmp, name, os.get_pid())
	os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil, "could not make the journey's home")
	return {dir = dir}
}

// leave removes the Home when the journey ends.
leave :: proc(h: Home) {
	os.remove_all(h.dir)
}

// data is the folder the run keeps its history, settings and trial in: leita's
// folder under the data folder of the platform, which run points at the Home.
data :: proc(h: Home) -> string {
	when ODIN_OS == .Darwin {
		return fmt.tprintf("%s/Library/Application Support/leita", h.dir)
	} else {
		return fmt.tprintf("%s/data/leita", h.dir)
	}
}

// slashes is path with its separators as slashes. A scan of the made-up disk on
// Windows joins what it finds under /Users/alex with backslashes.
slashes :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
		return slashed
	} else {
		return path
	}
}

// run is leita args in h. A day of 0 or more scans the made-up disk of that
// day; a negative day scans what is on disk. extra is KEY=VALUE, each set for
// this run.
run :: proc(t: ^testing.T, h: Home, day: int, args: ..string, extra: []string = nil) -> Result {
	env := make([dynamic]string, context.temp_allocator)
	parent, _ := os.environ(context.temp_allocator)
	for kv in parent {
		key, _, _ := strings.partition(kv, "=")
		switch key {
		case "HOME",
		     "USERPROFILE",
		     "APPDATA",
		     "LOCALAPPDATA",
		     "LEITA_SYNTHETIC",
		     "LEITA_LICENCE",
		     "LEITA_RELEASE_BASE",
		     "LEITA_COLOR",
		     "XDG_DATA_HOME",
		     "XDG_CONFIG_HOME",
		     "XDG_STATE_HOME",
		     "XDG_CACHE_HOME":
			continue
		}
		append(&env, kv)
	}

	append(&env, fmt.tprintf("HOME=%s", h.dir), fmt.tprintf("USERPROFILE=%s", h.dir))
	append(&env, fmt.tprintf("XDG_DATA_HOME=%s/data", h.dir))
	append(&env, fmt.tprintf("XDG_CONFIG_HOME=%s/config", h.dir))
	append(&env, fmt.tprintf("XDG_STATE_HOME=%s/state", h.dir))
	append(&env, fmt.tprintf("XDG_CACHE_HOME=%s/cache", h.dir))
	append(&env, fmt.tprintf("APPDATA=%s/data", h.dir), fmt.tprintf("LOCALAPPDATA=%s/data", h.dir))
	// Plain, unless the journey asks for colour itself; never two settings of
	// one name, since which of them a process reads is not defined.
	coloured := false
	for kv in extra {
		coloured ||= strings.has_prefix(kv, "LEITA_COLOR=")
	}
	if !coloured {
		append(&env, "LEITA_COLOR=never")
	}
	if day >= 0 {
		append(&env, fmt.tprintf("LEITA_SYNTHETIC=%d", day))
	}
	for kv in extra {
		append(&env, kv)
	}

	command := make([dynamic]string, context.temp_allocator)
	append(&command, binary())
	append(&command, ..args)

	state, out, err_out, err := os.process_exec(
		{command = command[:], env = env[:]},
		context.temp_allocator,
	)
	if !testing.expectf(t, err == nil, "could not run %v: %v", command[:], err) {
		return {code = -1}
	}
	return {out = string(out), err = string(err_out), code = state.exit_code}
}

// expect_code fails the journey unless the run exited with want, and shows what
// it said when it did not.
expect_code :: proc(t: ^testing.T, r: Result, want: int, loc := #caller_location) -> bool {
	return testing.expectf(
		t,
		r.code == want,
		"exit code %d, want %d\nstdout: %s\nstderr: %s",
		r.code,
		want,
		r.out,
		r.err,
		loc = loc,
	)
}

// line_after is the first line of text after the line that begins with heading,
// trimmed: the answer a summary's section opens with.
line_after :: proc(text, heading: string) -> string {
	lines := strings.split_lines(text, context.temp_allocator)
	for line, i in lines {
		if strings.has_prefix(line, heading) && i + 1 < len(lines) {
			return strings.trim_space(lines[i + 1])
		}
	}
	return ""
}

// report parses a JSON report the run wrote, to its top object.
report :: proc(t: ^testing.T, text: string) -> json.Object {
	value, err := json.parse(
		transmute([]byte)text,
		parse_integers = true,
		allocator = context.temp_allocator,
	)
	if !testing.expectf(t, err == .None, "the report is not JSON (%v): %.200s", err, text) {
		return nil
	}
	root, ok := value.(json.Object)
	testing.expect(t, ok, "the report is not an object")
	return root
}

// member is the object under key of o, empty when there is none.
member :: proc(o: json.Object, key: string) -> json.Object {
	value, _ := o[key].(json.Object)
	return value
}

// whole is the integer under key of o, -1 when it is not one.
whole :: proc(o: json.Object, key: string) -> i64 {
	if n, ok := o[key].(json.Integer); ok {
		return n
	}
	return -1
}

// read_file is the text of the file at path, empty when it is not there.
read_file :: proc(path: string) -> string {
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(bytes) : ""
}

// file_in is the path of name in h's folder.
file_in :: proc(h: Home, name: string) -> string {
	return fmt.tprintf("%s/%s", h.dir, name)
}

// text is the string under key of o, empty when it is not one.
text :: proc(o: json.Object, key: string) -> string {
	s, _ := o[key].(json.String)
	return s
}

// licence_line is the licence the journeys' binary is built to take: the test
// licence, which just journeys passes in.
licence_line :: proc() -> string {
	return os.get_env("LEITA_TEST_LICENCE", context.temp_allocator)
}

// end_evaluation dates the first use of h's run far in the past, so the 30-day
// Pro evaluation has ended there.
end_evaluation :: proc(t: ^testing.T, h: Home) {
	os.make_directory_all(data(h))
	testing.expect(t, os.exists(data(h)), "could not make the data folder")
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/first-use", data(h)), "1000000000\n") == nil,
		"could not age the trial",
	)
}
