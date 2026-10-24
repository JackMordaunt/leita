/*
Package walk_fuzz runs the walk over filesystems made from a spec.

	model  the model agrees with itself and the shrinker keeps a spec valid; no disk
	scan   the walk of a built spec finds what the model says, again, and updated
	churn  the walk of a tree a thread is changing finds only what could have been (churn.odin)

A case draws a tree spec (spec.odin) from its bytes: nested directories, a table
of file kinds, a mount tree. The model (model.odin) says what a scan of it must
report. The scan property builds it under a temp directory (materialise_*.odin),
mounts and all, walks it from the root and from each tmpfs in it, and compares
the file, directory, symlink, mount and extra-name counts with the model and the
bytes allocated with statx of the real files.

Mounts need a user and mount namespace of the process's own, so `just fuzz`
enters one before it starts this program. Where a mount cannot be made the scan
property passes and `skip_reason` says why, for the driver to print.

A failing case is shrunk as a spec, in the property: the failure's detail is the
smaller tree, a few lines, and the same bytes draw the same failure again. Byte
shrinking is switched off, since it cannot make a better spec than this does.
*/
package walk_fuzz

import harness "jm:fuzz"

Case :: struct {}

properties := []harness.Property(Case){{"model", check_model}, {"scan", check_scan}, {"churn", check_churn}}

CORPUS :: "walk/fuzz/corpus"

// Seconds a case may take before the driver's child is killed and the case
// reported as a hang. Building a tree and walking it is quick; this is for a hang.
CASE_TIMEOUT_SECONDS :: 30

suite :: proc() -> harness.Suite(Case) {
	return {name = "tree", setup = setup, teardown = teardown, properties = properties}
}

run :: proc(opts := harness.Opts{}, allocator := context.allocator) -> harness.Report {
	opts := opts
	// The property shrinks the spec; a byte that is simpler is not a simpler tree.
	opts.shrink = -1
	return harness.run(suite(), opts, allocator)
}

setup :: proc() -> (Case, bool) {
	return {}, true
}

teardown :: proc(_: ^Case) {}

check_model :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	replay := src^
	spec := draw(src)
	again := draw(&replay)
	if render(spec) != render(again) {
		return "the same bytes drew two different specs", false
	}
	flaw := model_flaw(spec)
	return flaw, flaw == ""
}

// model_flaw is what the model or the shrinker gets wrong about a spec, "" if
// nothing.
model_flaw :: proc(spec: Spec, allocator := context.temp_allocator) -> string {
	if why, good := valid(spec, allocator); !good {
		return format_reason(allocator, "a drawn spec is not valid: %s\n%s", why, render(spec, allocator))
	}
	for denies in ([]bool{false, true}) {
		for start in starts(spec, denies, len(spec.nodes), allocator) {
			want, reps := expected(spec, start, denies, allocator)
			flat := expected_flat(spec, start, denies, allocator)
			if want != flat {
				return format_reason(
					allocator,
					"from /%s (denies %v) the model says %v, counted flat %v\n%s",
					path_of(spec, start, allocator),
					denies,
					want,
					flat,
					render(spec, allocator),
				)
			}
			if len(reps) != want.files {
				return format_reason(allocator, "%d files counted, %d named\n%s", want.files, len(reps), render(spec, allocator))
			}
		}
	}
	text := render(spec, allocator)
	for cand in shrink_steps(spec, allocator) {
		// A step may leave a spec that breaks a rule, a link across filesystems
		// once a mount is lifted out; minimise skips those. One that changes
		// nothing, or grows the tree, would loop it.
		if len(cand.nodes) > len(spec.nodes) || render(cand, allocator) == text {
			return format_reason(allocator, "a shrink step made no progress\n%s", text)
		}
	}
	return ""
}
