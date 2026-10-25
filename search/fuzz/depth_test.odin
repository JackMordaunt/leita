package search_fuzz

import "core:log"
import "core:math/rand"
import "core:testing"

import harness "jm:fuzz"

import search ".."

CASES :: 2000

// Seeding from the names the search tests are written against reaches more
// distinct runes whose fold is not the rune itself: 156 from the first five
// seeds, 165 from all of them, for the same entropy. The counts are logged.
@(test)
seeds_reach_more_folds :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	before := folded_runes(seeds[:5])
	after := folded_runes(seeds)
	log.infof(
		"fold, %d damaged strings, first five seeds: %d distinct runes the fold changes",
		CASES,
		before,
	)
	log.infof(
		"fold, %d damaged strings, all seeds:        %d distinct runes the fold changes",
		CASES,
		after,
	)
	testing.expectf(
		t,
		after > before,
		"seeds reached %d changed runes, the first five %d",
		after,
		before,
	)
}

@(private = "file")
folded_runes :: proc(corpus: []string) -> int {
	seen := make(map[rune]struct{})
	rand.reset(11)
	for _ in 0 ..< CASES {
		entropy: [32]byte
		for i in 0 ..< len(entropy) {
			entropy[i] = byte(rand.uint32())
		}
		src := harness.source(entropy[:])
		text, _ := harness.damage_text(&src, corpus, context.temp_allocator)
		for r in text {
			if search.fold(r, false) != r {
				seen[r] = {}
			}
		}
	}
	return len(seen)
}
