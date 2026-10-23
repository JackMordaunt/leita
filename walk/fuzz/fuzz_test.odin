package walk_fuzz

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import harness "jm:fuzz"

@(test)
properties_hold :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for seed in ([]u64{1, 7}) {
		report := run({seed = seed, iterations = 16})
		testing.expect_value(t, report.iterations, 16)
		for f in report.failures {
			testing.expectf(t, false, "%s failed at case %d seed %d: %s", f.property, f.iteration, f.seed, f.detail)
		}
	}
	if why := skip_reason(); why != "" {
		// A host with no namespace cannot run the scan property, which is not a
		// failure unless the run says it must (as walk's mount tests do).
		if os.get_env("LEITA_MOUNT_TEST", context.temp_allocator) != "" {
			testing.fail_now(t, "LEITA_MOUNT_TEST is set, but no tree could be built")
		}
		log.warnf("the scan property did not build a tree: %s; just test runs this in a namespace", why)
	}
}

@(test)
suite_is_complete :: proc(t: ^testing.T) {
	s := suite()
	testing.expect_value(t, s.name, "tree")
	testing.expect_value(t, len(s.properties), 2)
	testing.expect(t, s.properties[0].check == check_model, "model runs check_model")
	testing.expect(t, s.properties[1].check == check_scan, "scan runs check_scan")
}

@(test)
same_seed_same_run :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := run({seed = 5, iterations = 8})
	second := run({seed = 5, iterations = 8})
	testing.expect_value(t, first.digest, second.digest)
	testing.expect(t, first.digest != 0, "a run that generated cases has a digest")
}

// A zero byte is the simplest tree: a root and nothing in it.
@(test)
zero_bytes_draw_a_bare_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	src := harness.source(make([]byte, 64))
	spec := draw(&src)
	testing.expect_value(t, len(spec.nodes), 1)
	testing.expect_value(t, render(spec), "/ dir\n")
}

// The shapes the walk's bugs have lived in must be drawn, or the property never
// sees them: a mount inside a mount, and a hard link.
@(test)
draws_nested_mounts_and_links :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	nested, linked, binds := 0, 0, 0
	for seed in 1 ..= 400 {
		raw := make([]byte, 256)
		state := u64(seed) * 2654435761
		for &b in raw {
			state = state * 6364136223846793005 + 1442695040888963407
			b = byte(state >> 33)
		}
		src := harness.source(raw)
		spec := draw(&src)
		for n in spec.nodes {
			if n.kind == .Mount && n.mount == .Tmpfs && domain(spec, n.parent) != 0 {
				nested += 1
			}
			if n.kind == .Link {
				linked += 1
			}
			if n.kind == .Mount && n.mount == .Bind {
				binds += 1
			}
		}
	}
	testing.expect(t, nested > 0, "no tmpfs inside a tmpfs was drawn")
	testing.expect(t, linked > 0, "no hard link was drawn")
	testing.expect(t, binds > 0, "no bind was drawn")
}

// The model's numbers for one tree worked out by hand: the root holds a file, a
// link to it, a directory with a tmpfs holding another file, and a symlink.
@(test)
model_counts_a_known_tree :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	spec := Spec {
		nodes = []Node {
			{id = 0, parent = NONE, kind = .Dir, target = NONE},
			{id = 1, parent = 0, name = "f1", kind = .File, size = 4096, target = NONE},
			{id = 2, parent = 0, name = "l2", kind = .Link, target = 1},
			{id = 3, parent = 0, name = "d3", kind = .Dir, target = NONE},
			{id = 4, parent = 3, name = "t4", kind = .Mount, mount = .Tmpfs, target = NONE},
			{id = 5, parent = 4, name = "f5", kind = .File, size = 1, target = NONE},
			{id = 6, parent = 0, name = "y6", kind = .Symlink, target = 3},
			{id = 7, parent = 3, name = "b7", kind = .Mount, mount = .Bind, target = 3},
		},
	}
	_, ok := valid(spec)
	testing.expect(t, ok)
	whole, _ := expected(spec, 0, false)
	testing.expect_value(t, whole, Tally{files = 1, extras = 1, dirs = 2, symlinks = 1, mounts = 2, apparent = 4096})
	inner, _ := expected(spec, 4, false)
	testing.expect_value(t, inner, Tally{files = 1, dirs = 1, apparent = 1})
	testing.expect_value(t, expected_flat(spec, 0, false), whole)
}

// Shrinking a spec stops at the smallest that still fails, and keeps it valid.
@(test)
minimise_drops_what_is_not_needed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	spec := Spec {
		nodes = []Node {
			{id = 0, parent = NONE, kind = .Dir, target = NONE},
			{id = 1, parent = 0, name = "f1", kind = .File, size = 4096, target = NONE},
			{id = 2, parent = 0, name = "t2", kind = .Mount, mount = .Tmpfs, target = NONE},
			{id = 3, parent = 2, name = "t3", kind = .Mount, mount = .Tmpfs, target = NONE},
			{id = 4, parent = 3, name = "f4", kind = .File, size = 65536, target = NONE},
			{id = 5, parent = 0, name = "l5", kind = .Link, target = 1},
		},
	}
	// "Fails" while a tmpfs lies in a tmpfs.
	nested :: proc(s: Spec, _: rawptr) -> bool {
		for n in s.nodes {
			if n.kind == .Mount && n.mount == .Tmpfs && domain(s, n.parent) != 0 {
				return true
			}
		}
		return false
	}
	small := minimise(spec, nested, nil, 100)
	testing.expectf(t, len(small.nodes) == 3, "left %d nodes:\n%s", len(small.nodes), render(small))
	_, ok := valid(small)
	testing.expect(t, ok)
}

@(test)
regressions_still_pass :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	before := count_cases(CORPUS)
	report := run({seed = 1, iterations = 1, corpus_dir = CORPUS})
	testing.expect(t, before >= 1, "this suite has regressions committed")
	// A scan case is replayed even where no tree can be built; it then passes
	// at once, so every case is counted either way.
	testing.expect_value(t, report.replayed, before)
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
