package walk_fuzz

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

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

// cannot_mount says a test that builds a tree has nothing to run on: a host with
// no namespace is not a failure, unless the run says mounts must work, as walk's
// own mount tests do.
@(private = "file")
cannot_mount :: proc(t: ^testing.T) -> bool {
	why := skip_reason()
	if why == "" {
		return false
	}
	if os.get_env("LEITA_MOUNT_TEST", context.temp_allocator) != "" {
		testing.fail_now(t, "LEITA_MOUNT_TEST is set, but no tree could be built")
	}
	log.warnf("skipped: %s; just test runs this in a namespace", why)
	return true
}

@(test)
suite_is_complete :: proc(t: ^testing.T) {
	s := suite()
	testing.expect_value(t, s.name, "tree")
	testing.expect_value(t, len(s.properties), 3)
	testing.expect(t, s.properties[0].check == check_model, "model runs check_model")
	testing.expect(t, s.properties[1].check == check_scan, "scan runs check_scan")
	testing.expect(t, s.properties[2].check == check_churn, "churn runs check_churn")
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

// The strange inputs of card 670 step 3 must be drawn, or the property never sees
// them, and every spec they make must be one the materialiser can build.
@(test)
draws_strange_inputs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	seen: map[string]int
	for seed in 1 ..= 600 {
		raw := make([]byte, 256)
		state := u64(seed) * 2654435761
		for &b in raw {
			state = state * 6364136223846793005 + 1442695040888963407
			b = byte(state >> 33)
		}
		src := harness.source(raw)
		spec := draw(&src)
		if why, ok := valid(spec); !ok {
			testing.expectf(t, false, "seed %d draws an invalid spec: %s", seed, why)
		}
		storm := make(map[int]int)
		for n in spec.nodes[1:] {
			switch {
			case len(n.name) >= 100:
				seen["long name"] += 1
			case strings.contains(n.name, "\n"):
				seen["newline"] += 1
			case strings.has_prefix(n.name, "."):
				seen["leading dot"] += 1
			case strings.has_suffix(n.name, " "):
				seen["trailing space"] += 1
			case !utf8.valid_string(n.name):
				seen["invalid utf-8"] += 1
			case strings.contains(n.name, "e\u0301"):
				seen["decomposed twin"] += 1
			case strings.contains(n.name, "é"):
				seen["composed"] += 1
			}
			if n.kind == .Scatter {
				seen["written in pieces"] += 1
			}
			if n.kind == .Link {
				storm[n.target] += 1
			}
			if n.kind == .Symlink && n.target != NONE {
				if target, _ := find(spec, n.target); can_hold(target) && target.id == n.parent {
					seen["symlink to its own directory"] += 1
				}
			}
			if n.kind == .Sparse && n.size >= 1 << 32 {
				seen["sparse beyond 4 GiB"] += 1
			}
		}
		for _, count in storm {
			if count >= 4 {
				seen["hard link storm"] += 1
			}
		}
		// A twin differs from its sibling by case only.
		for n, i in spec.nodes[1:] {
			if before := sibling_before(spec.nodes, i + 1); before > 0 {
				if swap_case(spec.nodes[before].name, context.temp_allocator) == n.name {
					seen["case twin"] += 1
				}
			}
		}
	}
	for what in ([]string {
			"long name",
			"newline",
			"leading dot",
			"trailing space",
			"invalid utf-8",
			"decomposed twin",
			"composed",
			"written in pieces",
			"symlink to its own directory",
			"sparse beyond 4 GiB",
			"hard link storm",
			"case twin",
		}) {
		testing.expectf(t, seen[what] > 0, "no %s was drawn in 600 specs", what)
	}
}

// Clones and forks must be drawn, a clone of each kind of file and one in a
// mount among them, or the clone oracle never sees them.
@(test)
draws_clones_and_forks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	seen: map[string]int
	for seed in 1 ..= 600 {
		raw := make([]byte, 256)
		state := u64(seed) * 2654435761
		for &b in raw {
			state = state * 6364136223846793005 + 1442695040888963407
			b = byte(state >> 33)
		}
		src := harness.source(raw)
		spec := draw(&src)
		if why, ok := valid(spec); !ok {
			testing.expectf(t, false, "seed %d draws an invalid spec: %s", seed, why)
		}
		for n in spec.nodes {
			if is_clone(n) {
				seen[fmt.tprintf("clone of a %v", n.kind)] += 1
				if domain(spec, n.parent) != 0 {
					seen["clone in a mount"] += 1
				}
				if n.fork != .None {
					seen["clone with a fork"] += 1
				}
			}
			if n.fork != .None {
				seen[fmt.tprintf("%v", n.fork)] += 1
			}
		}
	}
	for what in ([]string {
			"clone of a File",
			"clone of a Sparse",
			"clone of a Scatter",
			"clone in a mount",
			"clone with a fork",
			"Xattr",
			"Resource",
		}) {
		testing.expectf(t, seen[what] > 0, "no %s was drawn in 600 specs", what)
	}
}

// A file and two clones of it, with a fork and without, built and walked where this
// host can mount: on APFS the clones share the data and are charged it once.
@(test)
walk_charges_clones_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if cannot_mount(t) {
		return
	}
	spec := Spec {
		nodes = []Node {
			{id = 0, parent = NONE, kind = .Dir, target = NONE},
			{id = 1, parent = 0, name = "f1", kind = .File, size = 1 << 20, target = NONE},
			{id = 2, parent = 0, name = "d2", kind = .Dir, target = NONE},
			{id = 3, parent = 2, name = "c3", kind = .File, size = 1 << 20, target = 1},
			{id = 4, parent = 0, name = "c4", kind = .File, size = 1 << 20, target = 1},
			{id = 5, parent = 0, name = "f5", kind = .File, size = 4096, target = NONE, fork = .Resource},
			{id = 6, parent = 2, name = "c6", kind = .File, size = 4096, target = 5, fork = .Resource},
			{id = 7, parent = 0, name = "f7", kind = .File, size = 4096, target = NONE, fork = .Xattr},
		},
	}
	_, ok := valid(spec)
	testing.expect(t, ok)
	class, what := scan_spec(spec)
	testing.expectf(t, class == "", "%s: %s", class, what)
}

// The strange inputs are drawn from the bytes a plain tree leaves, so the case saved
// for card 668 still draws the tmpfs in a tmpfs it was saved for.
@(test)
the_668_case_still_nests_a_tmpfs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	raw, err := os.read_entire_file_from_path(CORPUS + "/scan-b25c4320bb13c07d.case", context.temp_allocator)
	testing.expect_value(t, err, nil)
	src := harness.source(raw)
	spec := draw(&src)
	nested := false
	for n in spec.nodes {
		nested ||= n.kind == .Mount && n.mount == .Tmpfs && domain(spec, n.parent) != 0
	}
	testing.expectf(t, nested, "the case no longer draws a tmpfs inside a tmpfs:\n%s", render(spec))
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
	when JUNCTION_BINDS {
		// The bind b7 is a junction, a link.
		testing.expect_value(t, whole, Tally{files = 1, extras = 1, dirs = 2, symlinks = 2, mounts = 1, apparent = 4096})
	} else {
		testing.expect_value(t, whole, Tally{files = 1, extras = 1, dirs = 2, symlinks = 1, mounts = 2, apparent = 4096})
	}
	inner, _ := expected(spec, 4, false)
	testing.expect_value(t, inner, Tally{files = 1, dirs = 1, apparent = 1})
	testing.expect_value(t, expected_flat(spec, 0, false), whole)
}

// A bind of a directory below an unreadable one is the only place the scan can
// count that tree, so the walk reads it as a directory, and of two binds of it the
// first made; with the unreadable directory open, both are mounts (card 670
// step 3: the model did not know, and fuzz found it).
@(test)
model_walks_a_bind_of_an_unreadable_tree :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	spec := Spec {
		nodes = []Node {
			{id = 0, parent = NONE, kind = .Dir, target = NONE},
			{id = 1, parent = 0, name = "u1", kind = .Unreadable, target = NONE},
			{id = 2, parent = 1, name = "d2", kind = .Dir, target = NONE},
			{id = 3, parent = 2, name = "f3", kind = .File, size = 4096, target = NONE},
			{id = 4, parent = 2, name = "t4", kind = .Mount, mount = .Tmpfs, target = NONE},
			{id = 5, parent = 0, name = "b5", kind = .Mount, mount = .Bind, target = 2},
			{id = 6, parent = 0, name = "b6", kind = .Mount, mount = .Bind, target = 2},
		},
	}
	_, ok := valid(spec)
	testing.expect(t, ok)
	closed, _ := expected(spec, 0, true)
	open, _ := expected(spec, 0, false)
	when JUNCTION_BINDS {
		// Both binds are junctions, links that are not followed, so d2 is
		// counted only where it lies, when it can be read.
		testing.expect_value(t, closed, Tally{dirs = 2, symlinks = 2, unread = 1})
		testing.expect_value(t, open, Tally{files = 1, dirs = 3, symlinks = 2, mounts = 1, apparent = 4096})
	} else {
		// Denied: b5 shows d2 and its file, and the tmpfs in d2 is an empty directory in it.
		testing.expect_value(t, closed, Tally{files = 1, dirs = 4, mounts = 1, unread = 1, apparent = 4096})
		// Allowed: d2 is read where it lies, and both binds are mounts of it.
		testing.expect_value(t, open, Tally{files = 1, dirs = 3, mounts = 3, apparent = 4096})
	}
	testing.expect_value(t, expected_flat(spec, 0, true), closed)
	testing.expect_value(t, expected_flat(spec, 0, false), open)
}

// A bind of a directory below the one another bind shows is a mount: the walk finds
// its tree at the other bind's path.
@(test)
model_stops_at_a_bind_inside_another :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	spec := Spec {
		nodes = []Node {
			{id = 0, parent = NONE, kind = .Dir, target = NONE},
			{id = 1, parent = 0, name = "u1", kind = .Unreadable, target = NONE},
			{id = 2, parent = 1, name = "d2", kind = .Dir, target = NONE},
			{id = 3, parent = 2, name = "d3", kind = .Dir, target = NONE},
			{id = 4, parent = 0, name = "b4", kind = .Mount, mount = .Bind, target = 3},
			{id = 5, parent = 0, name = "b5", kind = .Mount, mount = .Bind, target = 2},
		},
	}
	got, _ := expected(spec, 0, true)
	when JUNCTION_BINDS {
		// Two junctions, neither followed.
		testing.expect_value(t, got, Tally{dirs = 2, symlinks = 2, unread = 1})
	} else {
		// b5 is walked, with d3 in it; b4, of d3, is a mount.
		testing.expect_value(t, got, Tally{dirs = 4, mounts = 1, unread = 1})
	}
	testing.expect_value(t, expected_flat(spec, 0, true), got)
}

// The same, built and walked, where this host can mount.
@(test)
walk_reads_a_bind_of_an_unreadable_tree :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if cannot_mount(t) {
		return
	}
	spec := Spec {
		nodes = []Node {
			{id = 0, parent = NONE, kind = .Dir, target = NONE},
			{id = 1, parent = 0, name = "u1", kind = .Unreadable, target = NONE},
			{id = 2, parent = 1, name = "d2", kind = .Dir, target = NONE},
			{id = 3, parent = 2, name = "f3", kind = .File, size = 4096, target = NONE},
			{id = 4, parent = 0, name = "b4", kind = .Mount, mount = .Bind, target = 2},
			{id = 5, parent = 0, name = "b5", kind = .Mount, mount = .Bind, target = 2},
		},
	}
	class, what := scan_spec(spec)
	testing.expectf(t, class == "", "%s: %s", class, what)
}

// A bind of a directory below an unreadable one must be drawn, or the model's rule
// for it is never tried.
@(test)
draws_hidden_binds :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	hidden_binds := 0
	for seed in 1 ..= 600 {
		raw := make([]byte, 256)
		state := u64(seed) * 2654435761
		for &b in raw {
			state = state * 6364136223846793005 + 1442695040888963407
			b = byte(state >> 33)
		}
		src := harness.source(raw)
		spec := draw(&src)
		for n in spec.nodes {
			if n.kind == .Mount && n.mount == .Bind && under_unreadable(spec, n.target) {
				hidden_binds += 1
			}
		}
	}
	testing.expect(t, hidden_binds > 0, "no bind of a directory below an unreadable one was drawn in 600 specs")
}

// The mutator and the scan must overlap, or the churn property only ever checks
// a tree before or after: a script that adds files one at a time to a directory
// is met part way by some scan.
@(test)
scans_meet_the_tree_part_way :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if cannot_mount(t) {
		return
	}
	spec := Spec {
		nodes = []Node{{id = 0, parent = NONE, kind = .Dir, target = NONE}, {id = 1, parent = 0, name = "d1", kind = .Dir, target = NONE}},
	}
	ops := make([]Op, MAX_OPS)
	for &op, i in ops {
		op = Op {
			kind   = .Create,
			id     = i + 2,
			parent = i % 2,
			name   = fmt.tprintf("n%d", i),
			size   = 1,
		}
	}
	met := 0
	for _ in 0 ..< 40 {
		class, what := run_churn(spec, ops, midway = &met)
		testing.expectf(t, class == "", "%s: %s", class, what)
		if met > 0 {
			return
		}
	}
	testing.expect(t, false, "no scan in 40 runs met the tree part way through the ops")
}

// A rename moves a file between two directories: a scan may meet it at both ends,
// and with one name the walk cannot tell it is the same file, so that is two
// files. The bounds allow it; a count past them is a failure.
@(test)
bounds_allow_a_file_met_twice :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	spec := Spec {
		nodes = []Node {
			{id = 0, parent = NONE, kind = .Dir, target = NONE},
			{id = 1, parent = 0, name = "d1", kind = .Dir, target = NONE},
			{id = 2, parent = 0, name = "f2", kind = .File, size = 4096, target = NONE},
		},
	}
	ops := []Op{{kind = .Rename, id = 2, parent = 1, name = "r2"}}
	_, ok := replay(spec, ops)
	testing.expect(t, ok)
	limits := bounds(spec, ops, false)
	testing.expect_value(t, limits.names, [2]int{0, 2})
	testing.expect_value(t, limits.files, [2]int{0, 2})
	// Twice, and charged twice.
	both := Tally{files = 2, dirs = 2}
	testing.expect_value(t, bounds_fault(limits, both, 8192, 0), "")
	// Three is more than there ever were; so is a bind where there was none.
	testing.expect(t, bounds_fault(limits, Tally{files = 3, dirs = 2}, 0, 0) != "")
	testing.expect(t, bounds_fault(limits, Tally{files = 1, dirs = 3}, 0, 0) != "")
	// A file that was there throughout cannot be missing.
	still := []Op{{kind = .Create, id = 3, parent = 0, name = "f3", size = 1}}
	kept := bounds(spec, still, false)
	testing.expect(t, bounds_fault(kept, Tally{dirs = 2}, 0, 4096) != "")
	testing.expect_value(t, bounds_fault(kept, Tally{files = 1, dirs = 2}, 4096, 4096), "")
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
