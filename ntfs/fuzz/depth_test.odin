package ntfs_fuzz

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:testing"

import harness "jm:fuzz"

import ntfs ".."

CASES :: 2000

// Outcomes are where each damaged input stopped, by the error the parser
// gave, or by what it yielded when it took the input. A seed with more
// structure reaches outcomes a one-attribute record cannot: a run list that
// decodes to several runs, an extension record, a stream with a name.
@(private = "file")
Outcomes :: map[string]int

// Seeding from the shapes the unit tests build puts damaged input in front of
// more of the parsers' results, for the same entropy. The tallies are logged,
// so a run shows the gain.
@(test)
seeds_reach_more_outcomes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for name in ([]string{"boot", "runlist", "record"}) {
		own, full: [][]byte
		switch name {
		case "boot":
			own, full = boots()[:1], boots()
		case "runlist":
			own, full = runlists()[:1], runlists()
		case "record":
			own, full = records()[:1], records()
		}
		before := measure(name, own)
		after := measure(name, full)
		log.infof(
			"%s, %d damaged inputs, one seed:  %d outcomes %v",
			name,
			CASES,
			len(before),
			sorted(before),
		)
		log.infof(
			"%s, %d damaged inputs, all seeds: %d outcomes %v",
			name,
			CASES,
			len(after),
			sorted(after),
		)
		testing.expectf(
			t,
			len(after) > len(before) || (name != "record" && len(after) == len(before)),
			"%s: seeds reached %d outcomes, the first alone %d (a record must gain, the others must not lose)",
			name,
			len(after),
			len(before),
		)
	}
}

@(private = "file")
sorted :: proc(o: Outcomes) -> []string {
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
measure :: proc(name: string, corpus: [][]byte) -> Outcomes {
	out := make(Outcomes)
	rand.reset(11)
	for _ in 0 ..< CASES {
		entropy: [32]byte
		for i in 0 ..< len(entropy) {
			entropy[i] = byte(rand.uint32())
		}

		src := harness.source(entropy[:])
		raw, _ := harness.damage(&src, corpus, context.temp_allocator)
		switch name {
		case "boot":
			_, err := ntfs.parse_boot_sector(raw)
			out[fmt.tprintf("%v", err)] += 1
		case "runlist":
			runs, err := ntfs.decode_runlist(raw, 0, context.temp_allocator)
			key := fmt.tprintf("%v", err)
			if err == .None {
				key = fmt.tprintf("ok, %d runs", min(len(runs), 4))
			}
			out[key] += 1
		case "record":
			fix := ntfs.apply_fixups(raw)
			if fix != .None {
				out[fmt.tprintf("fixups %v", fix)] += 1
				continue
			}
			m: ntfs.Mft
			if ntfs.mft_init(&m, 4, 4096, 1) != .None {
				continue
			}
			err := ntfs.mft_add_record(&m, 1, raw, &m.sinks[0])
			key := fmt.tprintf("%v", err)
			if err == .None {
				key = fmt.tprintf("ok, %d attributes", attribute_count(raw))
			}
			out[key] += 1

			ntfs.mft_destroy(&m)
		}
	}
	return out
}

@(private = "file")
attribute_count :: proc(rec: []byte) -> int {
	it := ntfs.attributes(rec)
	n := 0
	for {
		_, got := ntfs.next_attribute(&it)
		if !got || n >= 8 {
			break
		}
		n += 1
	}
	return n
}
