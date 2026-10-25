/*
Package gui_fuzz drives the window with random sequences of what a person does,
and checks after every action what must always hold (invariants.odin).

	sequence   from a made-up disk, a window size and a theme, a run of actions
	           (actions.odin), with every invariant holding after each

A case is a pure function of its bytes: the first say which day's made-up disk
(synth), how big the window is, its theme and how far the scan has got before
the first action; then how many actions, then each action and what it draws.
A zero byte is the simplest value everywhere: day 0, the window as it opens, no
actions, and an action that waits. Shrinking a failure therefore converges on
the fewest actions that still break it, and the corpus keeps it.

The window is the real one: the host, the desk and the reader on their
threads, the view laid out in real text in a probe (journeys/gui's harness).
Two things keep a case the same each run. The made-up disk is read through a
gate, so a scan is held between actions and moves only when an action lets it.
And each action ends once the host has gone quiet. What the host's threads do
between frames is still theirs, so a replay is the same sequence, not the same
schedule of threads: a failure that needs a race may take a few runs to show.

Each case runs in a child process (leita-fuzz's runner isolates the suite), so
a crash, a failed bounds check or an ASan report is a result like any other.
Nothing reaches past the case's folder: the made-up disk is every path, which
app/act.odin refuses every delete and rename on, and commands that would reach
the system's scheduler, the network or the file manager are dropped
(window.odin pass_allowed).
*/
package gui_fuzz

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import harness "jm:fuzz"
import "jm:ui"
import "jm:ui/ops"

// Case is the harness subject: none, each case opens a window of its own.
Case :: struct {}

properties := []harness.Property(Case){{"sequence", check_sequence}}

// CORPUS is this suite's regressions, relative to the repository root.
CORPUS :: "gui/fuzz/corpus"

// TRACE_ENV, set, has a case print each step, where the keyboard is, and the
// tree a screen reader is told, to stderr: run a saved case in a child with it.
TRACE_ENV :: "LEITA_GUI_FUZZ_TRACE"

// MAX_STEPS is the most actions one case takes.
MAX_STEPS :: 40

// DAYS is how many of the made-up disk's days a case draws from.
DAYS :: 8

// CASE_TIMEOUT_SECONDS is how long a child may take before it is counted hung,
// a generous bound: seed 5's 80 cases took 12m26s under ASan on 2026-10-25,
// 9.3 s each on average, and one that runs several scans to their end is longer.
CASE_TIMEOUT_SECONDS :: 300

suite :: proc() -> harness.Suite(Case) {
	return {name = "gui", properties = properties}
}

/*
run runs the suite. A child the harness started for one case serves it and
exits inside harness.run. The run itself names the folder its children keep
their data in (ROOT_ENV), and removes it once they are done.
*/
run :: proc(opts := harness.Opts{}, allocator := context.allocator) -> harness.Report {
	if _, child := os.lookup_env(harness.ENV_CASE, context.temp_allocator); !child {
		if os.get_env(ROOT_ENV, context.temp_allocator) == "" {
			tmp, _ := os.temp_directory(context.temp_allocator)
			root := fmt.tprintf("%s/leita_gui_fuzz_%d", tmp, os.get_pid())
			_ = os.set_env(ROOT_ENV, root)
			defer {
				os.remove_all(root)
				_ = os.unset_env(ROOT_ENV)
			}

			return harness.run(suite(), opts, allocator)
		}
	}
	return harness.run(suite(), opts, allocator)
}

/*
check_sequence opens the window on what the first bytes say, takes the
actions the rest say, and fails at the first action after which an
invariant does not hold, with the case and every step taken in the detail.
*/
check_sequence :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	return run_sequence(src)
}

// run_sequence is check_sequence's case, its detail in detail_allocator.
run_sequence :: proc(
	src: ^harness.Source,
	detail_allocator := context.temp_allocator,
) -> (
	detail: string,
	ok: bool,
) {
	// The harness hands a case an arena, which is no allocator for the host's
	// threads to share: they start with this context. The window gets the heap
	// and the default temporary allocator, which each thread keeps its own of,
	// and the detail is copied out to detail_allocator. That temporary allocator
	// is not freed here: in a test it is the caller's too, holding what the
	// harness reads after the case; a child's goes when the child exits.
	context.allocator = runtime.heap_allocator()
	context.temp_allocator = runtime.default_temp_allocator(
		&runtime.global_default_temp_allocator_data,
	)

	c := draw_case(src)

	w := new(Window)
	defer free(w)

	open(w, c.day, c.size, c.dark, c.first)
	defer close(w)

	settle(w)

	steps := make([dynamic]Step, context.allocator)
	defer {
		for s in steps {
			delete(s.detail)
		}
		delete(steps)
	}

	trace := os.get_env(TRACE_ENV, context.temp_allocator) != ""
	why := hold(w, 0)
	for i := 0; why == "" && i < c.steps; i += 1 {
		was := w.m.generation
		s := act(w, src)
		append(&steps, Step{s.action, strings.clone(s.detail)})
		why = hold(w, was)
		if why != "" {
			// The host may be slow to answer under ASan: what is still wrong
			// after it has had a while longer is what is reported.
			linger(w)
			why = hold(w, was)
		}

		if trace {
			fmt.eprintfln(
				"gui fuzz: %d. %v %q: focus %d %q, scan %d\n%s",
				i + 1,
				s.action,
				s.detail,
				w.p.router.focus,
				ui.probe_focus_name(&w.p),
				w.m.generation,
				ui.probe_semantics(&w.p, context.temp_allocator),
			)
		}
	}
	if why == "" {
		return "", true
	}
	return strings.clone(describe(c, steps[:], why), detail_allocator), false
}

// Opening is what a case opens the window on.
Opening :: struct {
	day:   int,
	size:  ops.Size,
	dark:  bool,
	first: int, // directories the scan reads before the first action
	steps: int,
}

draw_case :: proc(src: ^harness.Source) -> Opening {
	c: Opening
	c.day = harness.integer_in(src, 0, DAYS)
	c.size = SIZES[harness.integer_in(src, 0, len(SIZES))]
	c.dark = harness.boolean(src)
	c.first = (1 << uint(harness.integer_in(src, 0, 14))) - 1
	c.steps = harness.integer_in(src, 0, MAX_STEPS + 1)
	return c
}

// describe is a failure as a person replays it by hand: the opening, each step,
// and what broke after the last.
describe :: proc(
	c: Opening,
	steps: []Step,
	why: string,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"%s\n    day %d, %vx%v, %s, %d directories read first",
		why,
		c.day,
		c.size.x,
		c.size.y,
		"dark" if c.dark else "light",
		c.first,
	)
	for s, i in steps {
		fmt.sbprintf(&b, "\n    %d. %v", i + 1, s.action)
		if s.detail != "" {
			fmt.sbprintf(&b, " %q", s.detail)
		}
	}
	return strings.to_string(b)
}

// SHRINK_TRIES is how many smaller cases a failure is tried as: a case takes seconds.
SHRINK_TRIES :: 32

// CASE_TIMEOUT is CASE_TIMEOUT_SECONDS as a duration, for the runner.
CASE_TIMEOUT :: CASE_TIMEOUT_SECONDS * time.Second
