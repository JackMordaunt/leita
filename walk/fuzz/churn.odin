package walk_fuzz

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:time"

import harness "jm:fuzz"

import scan "../../scan"

/*
The churn property scans a tree while a mutator changes it (mutate.odin), over
and over until the last op is done. Each scan must report something the bounds
allow: counts between what stayed and what ever was, and nothing impossible. When
the mutator has stopped, the tree is a spec again, the one `replay` worked out:
a whole scan must match the model's exact numbers for it, and the earliest scan
brought up to date must agree with a whole scan of the finished tree.

A race decides what a scan sees, so the same bytes do not always fail. The bounds
hold whatever the race decides, so a failure is a scan that reported what could
not have been, and the shrinker runs a smaller case a few times before it decides
the failure is gone.
*/

// How long before the first op the update's `since` is put: an update reads again
// a directory stamped at or after `since`, so a stamp a little behind the clock that
// reads `now` is not missed. 200 ms is a margin chosen, not a measured lag.
SINCE_SLACK :: 200 * time.Millisecond

// A shrunk case is run this often before it is thought to have stopped failing.
SHRINK_TRIES :: 3

// SCANS_MOST is how many scans a script may be scanned through.
SCANS_MOST :: 400

check_churn :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	if skip_reason() != "" {
		return "", true
	}
	spec := draw(src)
	ops, _ := draw_ops(spec, src)
	flaw := churn_flaw(spec, ops)
	return flaw, flaw == ""
}

// churn_flaw is what the walk gets wrong about a tree changing under it, shrunk
// to the smallest script and spec that go wrong the same way, "" if nothing.
churn_flaw :: proc(spec: Spec, ops: []Op, allocator := context.temp_allocator) -> string {
	class, what := run_churn(spec, ops, allocator)
	if class == "" {
		return ""
	}

	small_spec, small_ops := spec, ops
	budget := 60
	fails :: proc(spec: Spec, ops: []Op, class: string, allocator: runtime.Allocator) -> bool {
		if _, ok := valid(spec, allocator); !ok {
			return false
		}
		if _, ok := replay(spec, ops, allocator); !ok {
			return false
		}
		for _ in 0 ..< SHRINK_TRIES {
			if got, _ := run_churn(spec, ops, allocator); got == class {
				return true
			}
		}
		return false
	}

	// Ops first: fewer of them is the easier case to read.
	for progress := true; progress && budget > 0; {
		progress = false
		for i in 0 ..< len(small_ops) {
			cand := slice.concatenate([][]Op{small_ops[:i], small_ops[i + 1:]}, allocator)
			budget -= 1
			if fails(small_spec, cand, class, allocator) {
				small_ops, progress = cand, true
				break
			}
			if budget == 0 {
				break
			}
		}
	}
	for progress := true; progress && budget > 0; {
		progress = false
		for cand in shrink_steps(small_spec, allocator) {
			if budget == 0 {
				break
			}
			if _, ok := valid(cand, allocator); !ok {
				continue
			}
			budget -= 1
			if fails(cand, small_ops, class, allocator) {
				small_spec, progress = cand, true
				break
			}
		}
	}
	_, small_what := run_churn(small_spec, small_ops, allocator)
	if small_what == "" {
		small_what = what
	}
	return format_reason(
		allocator,
		"%s: %s\nspec, from %d nodes down to %d, and %d ops down to %d:\n%sops:\n%s",
		class,
		small_what,
		len(spec.nodes) - 1,
		len(small_spec.nodes) - 1,
		len(ops),
		len(small_ops),
		render(small_spec, allocator),
		show_ops(small_ops, allocator),
	)
}

/*
run_churn builds the spec, scans it from the root while the ops are done, and
checks each scan against the bounds, then the finished tree against the model and
an update against a whole scan. The class is the kind of failure, "" for none.
`midway` counts the scans that found a number of names strictly between the
tree's before and after, which only a scan that overlapped the ops can: the
evidence that the mutator and the scan run at the same time.
*/
run_churn :: proc(spec: Spec, ops: []Op, allocator := context.temp_allocator, midway: ^int = nil) -> (class, what: string) {
	fx: Fixture
	defer destroy(&fx)
	if err := build(spec, &fx, allocator); err != "" {
		return "build", err
	}
	if err := sizes_match(spec, &fx, allocator); err != "" {
		return "materialiser", err
	}
	after, replayed := replay(spec, ops, allocator)
	if !replayed {
		return "script", "an op does not apply"
	}
	limits := bounds(spec, ops, fx.denies, allocator)
	before, _ := expected(spec, 0, fx.denies, allocator)
	finished, _ := expected(after, 0, fx.denies, allocator)
	least, err := allocated(&fx, limits.always, allocator)
	if err != "" {
		return "materialiser", err
	}

	since := time.now()._nsec - i64(SINCE_SLACK)
	mutator := start_churn(&fx, ops, runtime.heap_allocator())
	release_churn(mutator)
	earliest: Scan_Result
	defer scan.tree_destroy(&earliest.tree)
	scans := 0
	for {
		// A scan that begins after the last op is the finished tree's, and is held to
		// the bounds as the others are.
		last := churn_finished(mutator)
		other: Scan_Result
		w := &earliest if scans == 0 else &other
		class, what = read_whole(&fx, 0, w, allocator)
		scans += 1
		if got, was, will := w.tally.files + w.tally.extras, before.files + before.extras, finished.files + finished.extras; got != was && got != will {
			if midway != nil {
				midway^ += 1
			}
		}
		defer if scans > 1 {
			scan.tree_destroy(&other.tree)
		}
		if class == "" {
			if why := bounds_fault(limits, w.tally, w.disk, least, allocator); why != "" {
				class, what = "churn", format_reason(allocator, "scan %d of the tree changing: %s", scans, why)
			}
		}
		if class != "" {
			finish_churn(&fx, mutator, allocator)
			return class, what
		}
		if last || scans >= SCANS_MOST {
			break
		}
	}
	if err = finish_churn(&fx, mutator, allocator); err != "" {
		return "materialiser", format_reason(allocator, "the mutator: %s", err)
	}

	// Quiet again: the tree is the spec the ops make.
	if class, what = scan_from(after, &fx, 0, allocator); class != "" {
		return class, format_reason(allocator, "after the ops: %s", what)
	}
	whole, updated: Scan_Result
	defer scan.tree_destroy(&whole.tree)
	defer scan.tree_destroy(&updated.tree)
	if class, what = read_whole(&fx, 0, &whole, allocator); class != "" {
		return class, what
	}
	if class, what = read_update(&fx, 0, &earliest.tree, &updated, allocator, since, true); class != "" {
		return class, format_reason(allocator, "updating the scan made during the ops: %s", what)
	}
	if whole.tally != updated.tally || whole.disk != updated.disk {
		return "update", format_reason(
			allocator,
			"a scan made during the ops brought up to date finds %v and %d bytes, a whole scan %v and %d",
			updated.tally,
			updated.disk,
			whole.tally,
			whole.disk,
		)
	}
	if !slice.equal(layout(&whole.tree, allocator), layout(&updated.tree, allocator)) {
		return "update", "a scan made during the ops brought up to date lists other entries than a whole scan"
	}
	return "", ""
}

// layout is the paths and kinds in a tree, sorted, without which name of a hard
// link group was charged: an update keeps the charge on the name it was on.
@(private)
layout :: proc(t: ^scan.Tree, allocator: runtime.Allocator) -> []string {
	out := make([dynamic]string, allocator)
	for i in 0 ..< scan.slots(t) {
		flags := scan.node_flags(scan.node(t, i))
		if .Used not_in flags {
			continue
		}
		append(&out, fmt.aprintf("%s %v", node_path(t, i, allocator), flags - {.Extra_Name}, allocator = allocator))
	}
	slice.sort(out[:])
	return out[:]
}
