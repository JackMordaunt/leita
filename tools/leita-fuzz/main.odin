/*
leita-fuzz runs a leita fuzz suite for a fixed budget and reports what did
not hold.

	leita-fuzz search -seed=1 -iters=64 -for=2m

The exit status is 0 when every property held and 1 when one did not. With a
corpus directory set, the case about to run is written first, so a crash
leaves the input that caused it. -isolate runs each case in a child process.
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import harness "jm:fuzz"

import btrfs_fuzz "../../btrfs/fuzz"
import ntfs_fuzz "../../ntfs/fuzz"
import search_fuzz "../../search/fuzz"

Runner :: struct {
	name:   string,
	corpus: string,
	run:    proc(opts: harness.Opts, allocator := context.allocator) -> harness.Report,
}

runners := []Runner {
	{"btrfs", btrfs_fuzz.CORPUS, btrfs_fuzz.run},
	{"ntfs", ntfs_fuzz.CORPUS, ntfs_fuzz.run},
	{"search", search_fuzz.CORPUS, search_fuzz.run},
}

main :: proc() {
	opts := harness.Opts {
		log = note,
	}
	corpus_root := ""
	no_corpus := false
	wanted: [dynamic]string
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
			fmt.eprintfln("    replay with: leita-fuzz %s -seed=%d", r.name, report.seed)
		}
		if len(report.failures) > 0 {
			failed = true
		}
	}
	if failed {
		os.exit(1)
	}
}

@(private)
pick :: proc(wanted: []string) -> []Runner {
	if len(wanted) == 0 {
		return runners
	}
	chosen := make([dynamic]Runner)
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

USAGE :: `usage: leita-fuzz [suite...] [-seed=N] [-iters=N] [-for=2m] [-entropy=N]
               [-shrink=N] [-no-shrink] [-corpus=DIR] [-no-corpus]
               [-isolate] [-stop] [-quiet]

suites: btrfs, ntfs, search. With none named, every suite runs.
Each suite keeps its regressions beside its source and replays them first.
-corpus=DIR uses DIR/<suite> instead. -isolate runs each case in a child.`
