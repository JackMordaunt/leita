package history_fuzz

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:testing"

import harness "jm:fuzz"

import sqlite3 "jm:sqlite3"

import history ".."
import "../../scan"
import "../../survey"
import "../../testtmp"

CASES :: 400

// Outcomes are where each damaged file stopped: the check that refused it,
// or "read" when a reader took it. A reader that checks in stages shows the
// stage. A seed with more structure reaches stages a one-node file cannot:
// a count that does not fit the bytes, a link that names no node, a schema an
// older build wrote.
@(private = "file")
Outcomes :: map[string]int

// Seeding from the compat fixtures puts more damaged baselines into the node
// table than the one-node file this build writes does, for the same entropy:
// the files cut short inside it are the ones whose counts and names the
// reader had to trust. The tallies are logged, for the store as well. The
// store seeds change which schema a damaged file is, which a refusal count
// does not show, so only the baseline is asserted.
@(test)
fixtures_reach_the_node_table :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	full, _ := setup()
	if len(full.stores) < 2 || len(full.baselines) < 2 {
		testing.fail_now(t, "no fixture seeds")
	}
	own := Case{full.stores[:1], full.baselines[:1]}

	for name, which in ([]string{"store", "baseline"}) {
		before := measure(own, which)
		after := measure(full, which)
		log.infof("%s, %d damaged files, own file only: %v", name, CASES, before)
		log.infof("%s, %d damaged files, with fixtures:  %v", name, CASES, after)
		if which == 1 {
			stage := "the scan kept of this place is cut short"
			testing.expectf(
				t,
				after[stage] > before[stage],
				"cut short in the node table: %d with the fixture, %d without",
				after[stage],
				before[stage],
			)
		}
	}
}

@(private = "file")
measure :: proc(c: Case, which: int) -> Outcomes {
	out := make(Outcomes)
	rand.reset(11)
	dir, err := testtmp.make_dir("", "leita-fuzz-depth-*", context.temp_allocator)
	if err != nil {
		return out
	}
	defer os.remove_all(dir)

	path := filepath.join({dir, "file"}, context.temp_allocator) or_else ""
	for _ in 0 ..< CASES {
		entropy: [32]byte
		for i in 0 ..< len(entropy) {
			entropy[i] = byte(rand.uint32())
		}
		src := harness.source(entropy[:])
		corpus := c.stores if which == 0 else c.baselines
		raw, _ := harness.damage(&src, corpus, context.temp_allocator)
		if os.write_entire_file(path, raw) != nil {
			continue
		}
		if which == 0 {
			st: history.Store
			e := history.open(&st, path)
			if e == nil {
				history.close(&st)
				out["read"] += 1
			} else if f, is_fault := e.(sqlite3.Fault); is_fault {
				out[fmt.tprintf("%v", f.code)] += 1
			} else {
				out["error"] += 1
			}
		} else {
			// The deepest refusal across the places: a file for another
			// place stops at the place check, which says nothing of the body.
			best := ""
			for place in PLACES {
				tree: scan.Tree
				_, why, ok := survey.baseline_load(path, place, &tree)
				scan.tree_destroy(&tree)
				if ok {
					best = "read"
				} else if best != "read" && why != "the scan kept is of another place" {
					best = why
				}
			}
			out[best if best != "" else "another place"] += 1
		}
	}
	return out
}
