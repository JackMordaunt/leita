package btrfs_fuzz

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:testing"

import harness "jm:fuzz"

import btrfs ".."

CASES :: 2000

// Seeding from buffers shaped like a real reply puts damaged buffers in front
// of more of the reader's results, for the same entropy: items walked, and
// what charging an extent body said. The tallies are logged.
@(test)
seeds_reach_more_outcomes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	all := search_seeds()
	before := measure(all[:1])
	after := measure(all)
	log.infof(
		"search, %d damaged buffers, one seed:  %d outcomes %v",
		CASES,
		len(before),
		sorted(before),
	)
	log.infof(
		"search, %d damaged buffers, all seeds: %d outcomes %v",
		CASES,
		len(after),
		sorted(after),
	)
	testing.expectf(
		t,
		len(after) > len(before),
		"seeds reached %d outcomes, the first alone %d",
		len(after),
		len(before),
	)
}

@(private = "file")
sorted :: proc(o: map[string]int) -> []string {
	out := make([]string, len(o))
	i := 0
	for k, v in o {
		out[i] = fmt.tprintf("%s=%d", k, v)
		i += 1
	}
	slice.sort(out)
	return out
}

@(private = "file")
measure :: proc(corpus: [][]byte) -> map[string]int {
	out := make(map[string]int)
	rand.reset(11)
	for _ in 0 ..< CASES {
		entropy: [32]byte
		for i in 0 ..< len(entropy) {
			entropy[i] = byte(rand.uint32())
		}
		src := harness.source(entropy[:])
		raw, _ := harness.damage(&src, corpus, context.temp_allocator)
		u: btrfs.Usage
		f: btrfs.File
		items := 0
		charged := 0
		rest := raw
		for len(rest) > 0 {
			next, _, kind, body, ok := btrfs.read_search_item(rest)
			if !ok {
				break
			}
			items += 1
			if kind == 108 && btrfs.charge(body, &u, &f) == .None {
				charged += 1
			}
			rest = next
		}
		btrfs.usage_destroy(&u)
		btrfs.file_destroy(&f)
		out[fmt.tprintf("%d items, %d charged", min(items, 3), min(charged, 3))] += 1
	}
	return out
}
