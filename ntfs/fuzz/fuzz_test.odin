package ntfs_fuzz

import "core:os"
import "core:strings"
import "core:testing"

@(test)
properties_hold :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for seed in ([]u64{1, 7}) {
		report := run({seed = seed, iterations = 32})
		testing.expect_value(t, report.iterations, 32)
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
	testing.expect_value(t, s.name, "ntfs")
	testing.expect_value(t, len(s.properties), 4)
	testing.expect_value(t, s.properties[0].name, "boot")
	testing.expect(t, s.properties[0].check == check_boot, "boot runs check_boot")
	testing.expect_value(t, s.properties[1].name, "attributes")
	testing.expect(
		t,
		s.properties[1].check == check_attributes,
		"attributes runs check_attributes",
	)
	testing.expect_value(t, s.properties[2].name, "runlist")
	testing.expect(t, s.properties[2].check == check_runlist, "runlist runs check_runlist")
	testing.expect_value(t, s.properties[3].name, "record")
	testing.expect(t, s.properties[3].check == check_record, "record runs check_record")
}

@(test)
same_seed_same_run :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := run({seed = 5, iterations = 16})
	second := run({seed = 5, iterations = 16})
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
