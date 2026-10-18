package search_fuzz

import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

import harness "jm:fuzz"

import search ".."

// A short run on fixed seeds, so `just test` catches a regression without a
// long fuzz run.
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
				"%s failed at case %d (replay: leita-fuzz search -seed=%d): %s",
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
	testing.expect_value(t, s.name, "search")
	testing.expect_value(t, len(s.properties), 2)
	testing.expect_value(t, s.properties[0].name, "fold")
	testing.expect(t, s.properties[0].check == check_fold, "fold runs check_fold")
	testing.expect_value(t, s.properties[1].name, "ascii")
	testing.expect(t, s.properties[1].check == check_ascii, "ascii runs check_ascii")
}

// U+0170 folds to the ASCII base. Exact keeps that base uppercase.
@(test)
double_acute_u_folds_once :: proc(t: ^testing.T) {
	lower := search.fold(0x170, false)
	testing.expect_value(t, lower, rune('u'))
	testing.expect_value(t, search.fold(lower, false), rune('u'))
	upper := search.fold(0x170, true)
	testing.expect_value(t, upper, rune('U'))
	testing.expect_value(t, search.fold(upper, true), rune('U'))
}

// The seeds here are valid UTF-8. damage has to introduce a sequence fold
// would not see in those seeds alone.
@(test)
invalid_bytes_are_drawn :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	valid := []string{"Resume", "src/Main.go", "ABC/def"}
	raw := make([]byte, 256)
	for i in 0 ..< len(raw) {
		raw[i] = byte(i)
	}
	src := harness.source(raw)
	broken := 0
	for _ in 0 ..< 80 {
		text, _ := harness.damage_text(&src, valid)
		for r in text {
			if r == utf8.RUNE_ERROR {
				broken += 1
				break
			}
		}
	}
	testing.expect(t, broken > 0, "damage must produce a text that is not valid UTF-8")
}

// A run is a pure function of its seed.
@(test)
same_seed_same_run :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := run({seed = 5, iterations = 16})
	second := run({seed = 5, iterations = 16})
	testing.expect(t, first.digest != 0, "a run that generated cases has a digest")
	testing.expect_value(t, first.digest, second.digest)
}

// The committed corpus is replayed by `just test`.
@(test)
regressions_still_pass :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	report := run({seed = 1, iterations = 1, corpus_dir = CORPUS})
	committed := count_cases(CORPUS)
	testing.expect(t, committed >= 1, "this suite has regressions committed")
	testing.expect_value(t, report.replayed, committed)
	for f in report.failures {
		testing.expectf(t, false, "%s regressed: %s", f.property, f.detail)
	}
}

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
