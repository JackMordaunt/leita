package history_fuzz

import "core:os"
import "core:strings"
import "core:testing"

@(test)
properties_hold :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for seed in ([]u64{1, 7}) {
		report := run({seed = seed, iterations = 16})
		testing.expect_value(t, report.iterations, 16)
		for f in report.failures {
			testing.expectf(
				t,
				false,
				"%s failed at case %d seed %d: %s",
				f.property,
				f.iteration,
				f.seed,
				f.detail,
			)
		}
	}
}

@(test)
suite_is_complete :: proc(t: ^testing.T) {
	s := suite()
	testing.expect_value(t, s.name, "history")
	testing.expect_value(t, len(s.properties), 3)
	testing.expect_value(t, s.properties[0].name, "store")
	testing.expect(t, s.properties[0].check == check_store, "store runs check_store")
	testing.expect_value(t, s.properties[1].name, "baseline")
	testing.expect(t, s.properties[1].check == check_baseline, "baseline runs check_baseline")
	testing.expect_value(t, s.properties[2].name, "keep")
	testing.expect(t, s.properties[2].check == check_keep, "keep runs check_keep")
}

@(test)
same_seed_same_run :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := run({seed = 5, iterations = 8})
	second := run({seed = 5, iterations = 8})
	testing.expect(t, first.digest != 0, "a run that generated cases has a digest")
	testing.expect_value(t, first.digest, second.digest)
}

@(test)
regressions_still_pass :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	before := count_cases(CORPUS)
	report := run({seed = 1, iterations = 1, corpus_dir = CORPUS})
	testing.expect(t, before >= 1, "this suite has regressions committed")
	testing.expect_value(t, report.replayed, before)
	for f in report.failures {
		testing.expectf(t, false, "%s regressed: %s", f.property, f.detail)
	}
}

//review:ignore already-named search/fuzz's copy is private to that file; this test cannot call it
@(private = "file")
count_cases :: proc(dir: string) -> int {
	handle, err := os.open(dir)
	if err != nil {
		return 0
	}
	defer os.close(handle)
	entries, rerr := os.read_directory(handle, -1, context.temp_allocator)
	if rerr != nil {
		return 0
	}
	n := 0
	for e in entries {
		if strings.has_suffix(e.name, ".case") {
			n += 1
		}
	}
	return n
}
