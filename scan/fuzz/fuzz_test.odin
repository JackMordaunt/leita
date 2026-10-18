package scan_fuzz

import "core:os"
import "core:strings"
import "core:testing"

import harness "jm:fuzz"

import scan ".."

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
	testing.expect_value(t, s.name, "scan")
	testing.expect_value(t, len(s.properties), 1)
	testing.expect_value(t, s.properties[0].name, "rollup")
	testing.expect(t, s.properties[0].check == check_rollup, "rollup runs check_rollup")
}

// Extra names and mounts have to show up, or the rollup property never sees them.
@(test)
shapes_include_extra_names_and_mounts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	raw := make([]byte, 64)
	// The first byte is not 1, so these draws are ordinary trees. A deep chain
	// skips the extra-name and mount nodes, and this test is about those.
	for i in 0 ..< len(raw) {
		raw[i] = byte(i * 3 + 2)
	}
	extra, mounts := 0, 0
	for _ in 0 ..< 50 {
		src := harness.source(raw)
		tree: scan.Tree
		testing.expect_value(t, scan.tree_init(&tree), scan.Error.None)
		shape := fill(&tree, &src)
		scan.tree_destroy(&tree)
		if shape.extra > 0 {
			extra += 1
		}
		if mounts_seen(&shape) {
			mounts += 1
		}
	}
	testing.expect(t, extra > 0, "a drawn tree must include an extra name")
	testing.expect(t, mounts > 0, "a drawn tree must include a mount")
}

@(private = "file")
mounts_seen :: proc(s: ^Shape) -> bool {
	return s.other > 0
}

@(test)
same_seed_same_run :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := run({seed = 5, iterations = 8})
	second := run({seed = 5, iterations = 8})
	other := run({seed = 9, iterations = 8})
	testing.expect(t, first.digest != 0, "a run that generated cases has a digest")
	testing.expect_value(t, first.digest, second.digest)
	testing.expect(t, first.digest != other.digest, "a different seed draws a different run")
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
