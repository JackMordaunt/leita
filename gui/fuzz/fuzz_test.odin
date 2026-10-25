package gui_fuzz

import "core:os"
import "core:testing"
import "core:time"

import harness "jm:fuzz"

@(test)
suite_is_complete :: proc(t: ^testing.T) {
	s := suite()
	testing.expect_value(t, s.name, "gui")
	testing.expect_value(t, len(s.properties), 1)
	testing.expect_value(t, s.properties[0].name, "sequence")
	testing.expect(t, s.properties[0].check == check_sequence, "sequence runs check_sequence")
}

// No bytes are the simplest case: day 0, the window as it opens, light, the
// scan held at its top, and no actions. Shrinking converges on it.
@(test)
zero_bytes_open_the_window_as_it_opens_and_do_nothing :: proc(t: ^testing.T) {
	src := harness.source(nil)
	c := draw_case(&src)
	testing.expect_value(t, c.day, 0)
	testing.expect_value(t, c.size, SIZES[0])
	testing.expect_value(t, c.dark, false)
	testing.expect_value(t, c.first, 0)
	testing.expect_value(t, c.steps, 0)
	testing.expect_value(t, Action(harness.integer_in(&src, 0, len(Action))), Action.Wait)
}

// A short run on a fixed seed, in this process, so just gui-test catches a
// regression without a fuzz run: the window opens, takes a few actions and
// closes, and every invariant holds after each. The corpus is replayed first.
@(test)
a_fixed_seed_holds :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Minute)
	context.allocator = context.temp_allocator
	corpus := corpus_from_here()
	report := run({seed = 1, iterations = 2, corpus_dir = corpus, shrink = -1})
	testing.expect_value(t, report.iterations, 2 + report.replayed)
	if corpus != "" {
		testing.expect(t, report.replayed > 0, "the corpus was replayed first")
	}
	for f in report.failures {
		testing.expectf(
			t,
			false,
			"%s failed at case %d (replay: just fuzz gui %d 0 -iters=%d): %s",
			f.property,
			f.iteration,
			f.seed,
			f.iteration + 1,
			f.detail,
		)
	}
}

// corpus_from_here is the corpus when the test runs from the repository root,
// as just gui-test runs it, and none otherwise.
@(private = "file")
corpus_from_here :: proc() -> string {
	if os.exists(CORPUS) {
		return CORPUS
	}
	return ""
}
