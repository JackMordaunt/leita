/*
leita-fuzz runs a leita fuzz suite for a fixed budget and reports what did
not hold.

	just fuzz search 1 2m

just fuzz builds this program and runs it, locally and in CI. The seed is
printed before the first case, and a failure prints the command that runs
it again. The exit status is 0 when every property held and 1 when one did not. With a
corpus directory set, the case about to run is written first, so a crash
leaves the input that caused it. -isolate runs each case in a child process.
*/
package main

import "core:debug/trace"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

@(require) import "jm:debug"
import harness "jm:fuzz"

import btrfs_fuzz "../../btrfs/fuzz"
import gui_fuzz "../../gui/fuzz"
import history_fuzz "../../history/fuzz"
import ntfs_fuzz "../../ntfs/fuzz"
import scan_fuzz "../../scan/fuzz"
import search_fuzz "../../search/fuzz"
import walk_fuzz "../../walk/fuzz"

Runner :: struct {
	name:   string,
	corpus: string,
	run:    proc(opts: harness.Opts, allocator := context.allocator) -> harness.Report,
	// A suite whose cases touch the machine runs each in a child process, so
	// that a crash or a hang is a result and the case after it starts clean.
	isolate: bool,
	// Why part of the suite will not run on this host, "" if all of it will.
	skip_reason: proc() -> string,
	// How long a child may take, 0 for the harness's own limit.
	limit:   time.Duration,
	// How many smaller cases shrinking tries, 0 for the harness's own count;
	// -shrink= and -no-shrink win. A suite whose case takes seconds tries fewer.
	shrink:  int,
}

runners := []Runner {
	{name = "btrfs", corpus = btrfs_fuzz.CORPUS, run = btrfs_fuzz.run},
	{
		name = "gui",
		corpus = gui_fuzz.CORPUS,
		run = gui_fuzz.run,
		isolate = true,
		limit = gui_fuzz.CASE_TIMEOUT,
		shrink = gui_fuzz.SHRINK_TRIES,
	},
	{name = "history", corpus = history_fuzz.CORPUS, run = history_fuzz.run},
	{name = "ntfs", corpus = ntfs_fuzz.CORPUS, run = ntfs_fuzz.run},
	{name = "scan", corpus = scan_fuzz.CORPUS, run = scan_fuzz.run},
	{name = "search", corpus = search_fuzz.CORPUS, run = search_fuzz.run},
	{
		name = "tree",
		corpus = walk_fuzz.CORPUS,
		run = walk_fuzz.run,
		isolate = true,
		skip_reason = walk_fuzz.skip_reason,
		limit = walk_fuzz.CASE_TIMEOUT_SECONDS * time.Second,
	},
}

main :: proc() {
	os.exit(run())
}

// run puts every suite on the debug allocator in a debug build, so a block
// written past its end, freed twice or written after it was freed fails the
// run, as a property that did not hold does. The allocator reports before
// the process exits.
run :: proc(allocator := context.allocator) -> int {
	context.assertion_failure_proc = trace.assertion_failure_proc
	when ODIN_DEBUG {
		da: debug.Allocator
		debug.init(&da, allocator)
		defer debug.destroy(&da)

		code := run_suites(debug.allocator(&da))
		debug.report(&da)
		if n := debug.issue_count(&da); n > 0 {
			fmt.eprintfln("leita-fuzz: the debug allocator found %d issues", n)
			return 1
		}
		return code
	} else {
		return run_suites(allocator)
	}
}

@(private)
run_suites :: proc(allocator := context.allocator) -> int {
	context.allocator = allocator

	opts := harness.Opts {
		log = note,
	}
	corpus_root := ""
	no_corpus := false
	wanted := make([dynamic]string, context.temp_allocator)
	for arg in os.args[1:] {
		switch {
		case arg == "-h", arg == "--help":
			fmt.eprintln(USAGE)
			os.exit(2)
		case arg == "-quiet":
			opts.log = nil
		case arg == "-stop":
			opts.stop_on_first = true
		case arg == "-no-shrink":
			opts.shrink = -1
		case arg == "-isolate":
			opts.isolate = true
		case strings.has_prefix(arg, "-seed="):
			opts.seed = u64(flag_number(arg, "-seed="))
		case strings.has_prefix(arg, "-iters="):
			opts.iterations = flag_number(arg, "-iters=")
		case strings.has_prefix(arg, "-entropy="):
			opts.entropy = flag_number(arg, "-entropy=")
		case strings.has_prefix(arg, "-shrink="):
			opts.shrink = flag_number(arg, "-shrink=")
		case arg == "-no-corpus":
			no_corpus = true
		case strings.has_prefix(arg, "-corpus="):
			corpus_root = arg[len("-corpus="):]
		case strings.has_prefix(arg, "-for="):
			opts.duration = parse_duration(arg[len("-for="):])
		case strings.has_prefix(arg, "-"):
			fmt.eprintfln("leita-fuzz: unknown flag %s", arg)
			fmt.eprintln(USAGE)
			os.exit(2)
		case:
			append(&wanted, arg)
		}
	}
	if opts.duration > 0 && opts.iterations == 0 {
		opts.iterations = max(int)
	}
	if opts.seed == 0 {
		// The clock, taken here so the seed is known before the run, and a
		// run that is killed still told us which one it was.
		opts.seed = u64(time.now()._nsec) | 1
	}
	fmt.eprintfln("leita-fuzz: seed %d", opts.seed)

	failed := false
	for r in pick(wanted[:]) {
		suite_opts := opts
		switch {
		case no_corpus:
			suite_opts.corpus_dir = ""
		case corpus_root != "":
			dir := make([]byte, len(corpus_root) + 1 + len(r.name))
			copy(dir, corpus_root)
			dir[len(corpus_root)] = '/'
			copy(dir[len(corpus_root) + 1:], r.name)
			suite_opts.corpus_dir = string(dir)
		case:
			suite_opts.corpus_dir = r.corpus
		}
		if r.isolate {
			suite_opts.isolate = true
		}
		if r.limit > 0 {
			suite_opts.case_timeout = r.limit
		}
		if r.shrink > 0 && opts.shrink == 0 {
			suite_opts.shrink = r.shrink
		}
		if r.skip_reason != nil {
			if why := r.skip_reason(); why != "" {
				fmt.eprintfln("%s: skipped what needs a mount: %s", r.name, why)
			}
		}
		report := r.run(suite_opts)
		fmt.printfln(
			"%s: %d cases in %v, seed %d, %d replayed, %d failures",
			r.name,
			report.iterations,
			time.duration_round(report.elapsed, time.Millisecond),
			report.seed,
			report.replayed,
			len(report.failures),
		)
		for f in report.failures {
			fmt.eprintfln("  %s/%s [%v]: %s", r.name, f.property, f.outcome, f.detail)
			fmt.eprintfln("    replay with: %s", replay_command(r.name, report.seed, f.iteration, opts.isolate))
			if f.saved != "" {
				fmt.eprintfln("    shrunk case saved: %s (replayed first on every run)", f.saved)
			}
		}
		if len(report.failures) > 0 {
			failed = true
		}
	}
	return 1 if failed else 0
}

// replay_command is the just command that reaches a failure again: the
// seed fixes every case in order, so the cases up to and including the
// failing one, with no wall clock to cut the run short.
@(private)
replay_command :: proc(suite: string, seed: u64, iteration: int, isolate: bool) -> string {
	return fmt.tprintf(
		"just fuzz %s %d 0 -iters=%d%s",
		suite,
		seed,
		iteration + 1,
		" -isolate" if isolate else "",
	)
}

@(private)
pick :: proc(wanted: []string, allocator := context.temp_allocator) -> []Runner {
	if len(wanted) == 0 {
		return runners
	}
	chosen := make([dynamic]Runner, allocator)
	for name in wanted {
		found := false
		for r in runners {
			if r.name == name {
				append(&chosen, r)
				found = true
				break
			}
		}
		if !found {
			fmt.eprintfln("leita-fuzz: unknown suite %s", name)
			fmt.eprintln(USAGE)
			os.exit(2)
		}
	}
	return chosen[:]
}

@(private)
flag_number :: proc(arg, flag: string) -> int {
	n, ok := strconv.parse_int(arg[len(flag):])
	if !ok {
		fmt.eprintfln("leita-fuzz: %s wants an integer", flag)
		os.exit(2)
	}
	return n
}

@(private)
parse_duration :: proc(s: string) -> time.Duration {
	if n, ok := strconv.parse_int(s); ok {
		return time.Duration(n) * time.Second
	}
	if strings.has_suffix(s, "s") {
		if n, ok := strconv.parse_int(s[:len(s) - 1]); ok {
			return time.Duration(n) * time.Second
		}
	}
	if strings.has_suffix(s, "m") {
		if n, ok := strconv.parse_int(s[:len(s) - 1]); ok {
			return time.Duration(n) * time.Minute
		}
	}
	fmt.eprintfln("leita-fuzz: -for=%s is not a duration (30s, 2m)", s)
	os.exit(2)
}

@(private)
note :: proc(format: string, args: ..any) {
	fmt.eprintf(format, ..args)
	fmt.eprintln()
}

USAGE :: `usage: just fuzz [suite] [seed] [duration] [flags...]
       (seed 0 takes the clock, duration 0 sets no limit)
       leita-fuzz [suite...] [-seed=N] [-iters=N] [-for=2m] [-entropy=N]
               [-shrink=N] [-no-shrink] [-corpus=DIR] [-no-corpus]
               [-isolate] [-stop] [-quiet]

suites: btrfs, gui, history, ntfs, scan, search, tree. With none named, every suite runs.
Each suite keeps its regressions beside its source and replays them first.
-corpus=DIR uses DIR/<suite> instead. -isolate runs each case in a child; gui and
tree always do, and tree needs a mount namespace, which just fuzz enters.`
