/*
Package durability kills leita part way through its writes and checks what the next
start finds: every store reads, or is reported damaged; the copy kept before a write
is never lost; nothing a write did not own is deleted.

A write is run in a child, this same test binary run again with the case named in
its environment (ENV_CASE). serve notices that before the test runner starts and
runs the one case, so the child needs no other wiring. The child is killed either at
a named point, the nth call it makes through the faults seam (ENV_AT), which kills
the process there, or after a delay the parent picks, for the SQLite stores, whose
writes do not cross the seam.

Each case works in a directory the parent made (ENV_DIR) and nothing outside it.
*/
package durability

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "jm:sqlite3"

import "../faults"
import "../gui/files"
import "../history"
import "../licence"
import "../report"
import "../scan"
import "../settings"
import "../survey"
import "../walk"

ENV_CASE :: "LEITA_DURABILITY_CASE"
ENV_DIR :: "LEITA_DURABILITY_DIR"
ENV_AT :: "LEITA_DURABILITY_AT"

// DONE is the file a child that finished its case writes in its directory, holding
// how many calls it made through the seam.
DONE :: "done"
// ACKS is the file a looping child adds a line to after each write it was told held.
ACKS :: "acks"

// The paths a case writes, under its directory.
LICENCE :: "licence"
NEXT_LICENCE :: "next-licence" // the line a licence case saves
TREE :: "tree" // the place a baseline case reads
BASELINE :: "baseline"
REPORT :: "report.json"
SELECTION :: "selection" // the tree a delete case deletes, or a trash case trashes
OUTSIDE :: "outside" // a file beside it, which neither may touch
DATA :: "data" // XDG_DATA_HOME, so the Trash a trash case moves to is in its directory
SETTINGS :: settings.FILE
HISTORY :: "history.db"

// LOOPS bounds a looping child that is never killed.
LOOPS :: 100_000

Case :: enum {
	Licence_Save,
	Licence_Forget,
	Baseline_Save,
	Report_Save,
	Settings_Set,
	History_Keep,
	Delete_Tree,
	Trash,
}

// EXIT_FAILED and EXIT_BROKEN are a child's exits when its case did not hold, and
// when it could not run it, as jm:fuzz's isolated children say them.
EXIT_FAILED :: 70
EXIT_BROKEN :: 71

@(init)
serve :: proc "contextless" () {
	context = runtime.default_context()
	name_buf, dir_buf, at_buf: [4096]u8
	name := os.get_env(name_buf[:], ENV_CASE)
	if name == "" {
		return
	}

	c, known := fmt.string_to_enum_value(Case, name)
	if !known {
		fmt.eprintfln("durability: no case %q", name)
		os.exit(EXIT_BROKEN)
	}

	dir := os.get_env(dir_buf[:], ENV_DIR)
	at, _ := strconv.parse_int(os.get_env(at_buf[:], ENV_AT))
	if at > 0 {
		faults.arm({any = true, nth = at, fault = .Kill})
	}

	if why := run(c, dir); why != "" {
		fmt.eprintfln("durability: %v: %s", c, why)
		os.exit(EXIT_FAILED)
	}

	crossings := faults.crossings()
	faults.disarm()
	done_buf: [32]u8
	done := fmt.bprintf(done_buf[:], "%d", crossings)
	if os.write_entire_file(in_dir(dir, DONE), done) != nil {
		os.exit(EXIT_BROKEN)
	}
	os.exit(0)
}

// in_dir is the path of name in dir, made in allocator.
in_dir :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	path, _ := filepath.join({dir, name}, allocator)
	return path
}

// run does case c's write in dir, saying why it failed, "" when it held, in allocator.
@(private)
run :: proc(c: Case, dir: string, allocator := context.temp_allocator) -> string {
	context.temp_allocator = allocator
	switch c {
	case .Licence_Save:
		text, err := os.read_entire_file(in_dir(dir, NEXT_LICENCE), context.temp_allocator)
		if err != nil {
			return "no line to save"
		}
		if e := licence.save(in_dir(dir, LICENCE), string(text)); e != .None {
			return licence.describe(e)
		}
	case .Licence_Forget:
		if _, e := licence.forget(in_dir(dir, LICENCE)); e != .None {
			return licence.describe(e)
		}
	case .Baseline_Save:
		place := in_dir(dir, TREE)
		tree: scan.Tree
		if scan.tree_init(&tree, 2) != .None {
			return "no tree"
		}
		if e := walk.read(place, &tree, walk.Config{workers = 2}); e != .None {
			return fmt.tprintf("could not read %s: %v", place, e)
		}
		if !survey.baseline_save(in_dir(dir, BASELINE), place, &tree, {}) {
			return "the baseline was not kept"
		}
	case .Report_Save:
		r := sample_report()
		if e, _ := report.save(in_dir(dir, REPORT), &r, .Json); e != .None {
			return report.ERROR_TEXT[e]
		}
	case .Delete_Tree:
		if _, _, e := files.delete_tree(in_dir(dir, SELECTION)); e != .None {
			return files.describe(e)
		}
	case .Trash:
		// Never a person's own Trash.
		if !strings.has_prefix(os.get_env("XDG_DATA_HOME", allocator), dir) {
			return "the Trash is not in the case's directory"
		}
		if e := files.trash(in_dir(dir, SELECTION)); e != .None {
			return files.describe(e)
		}
	case .Settings_Set:
		st: settings.Store
		if err := settings.open(&st, in_dir(dir, SETTINGS)); err != nil {
			return history.describe(err)
		}
		return loop(dir, &st, proc(user: rawptr, i: int) -> sqlite3.Error {
			key: [32]u8
			value: [512]u8
			slice.fill(value[:], 'v')
			return settings.set((^settings.Store)(user), fmt.bprintf(key[:], "key-%d", i), string(value[:i % 512]))
		})
	case .History_Keep:
		st: history.Store
		if err := history.open(&st, in_dir(dir, HISTORY)); err != nil {
			return history.describe(err)
		}
		return loop(dir, &st, proc(user: rawptr, i: int) -> sqlite3.Error {
			_, err := history.save((^history.Store)(user), place_of(i), i64(i), u64(i), 1, entries_of(i))
			return err
		})
	}
	return ""
}

// sample_report is the report a report case saves.
sample_report :: proc() -> report.Report {
	return {version = "durability", target = "/home/someone"}
}

// place_of is the place a history case's ith save is of, one of its own each, so
// none is forgotten as older than history.KEPT. In allocator.
place_of :: proc(i: int, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("/place/%d", i, allocator = allocator)
}

// entries_of is what a history case's ith save keeps, in allocator.
entries_of :: proc(i: int, allocator := context.temp_allocator) -> []history.Entry {
	out := make([]history.Entry, 1 + i % 64, allocator)
	out[0] = {"", u64(i)}
	for j in 1 ..< len(out) {
		out[j] = {fmt.aprintf("dir-%d/file-%d", j % 7, j, allocator = allocator), u64(j)}
	}
	return out
}

/*
loop makes write's writes one after another, numbered from 1, and after each that
held adds its number to ACKS, until it is killed or has made LOOPS of them. The line
goes after the commit, so every number in ACKS was committed; one a kill cut short
may be missing its newline. Why a write failed is said in allocator.
*/
@(private)
loop :: proc(
	dir: string,
	user: rawptr,
	write: proc(user: rawptr, i: int) -> sqlite3.Error,
	allocator := context.allocator,
) -> string {
	acks, err := os.open(in_dir(dir, ACKS, allocator), {.Write, .Create, .Append})
	if err != nil {
		return "no acks file"
	}
	defer os.close(acks)

	for i in 1 ..= LOOPS {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if werr := write(user, i); werr != nil {
			return fmt.aprintf("write %d: %s", i, history.describe(werr), allocator = allocator)
		}
		line: [32]u8
		if _, werr := os.write_string(acks, fmt.bprintf(line[:], "%d\n", i)); werr != nil {
			return "could not ack"
		}
	}
	return ""
}
