package history_fuzz

// The files earlier builds wrote, from the fixtures the compat test reads
// (cli/testdata/compat). Damage starts from valid structure: a header that
// parses, pages that chain, a node table that adds up, so a flipped byte
// lands in a reader that is already past its first check.
//
// Only the intact ones are seeds. Damage makes its own truncations and
// flips, and the fixtures that are damaged already are those, one case each.
// The one baseline seed is bl4, the version this build reads: bl1 to bl3 and
// bl5 are refused at the magic by design (the compat test says so), and a
// seed that is refused at the first eight bytes starts every mutation of it
// there. The stores are 24576 bytes apiece; h-future is 32768 and adds
// nothing that a splice of the two does not reach.
@(private)
STORE_SEEDS := [?][]byte {
	#load("../../cli/testdata/compat/history/h1.db"),
	#load("../../cli/testdata/compat/history/h2.db"),
}

@(private)
BASELINE_SEEDS := [?][]byte{#load("../../cli/testdata/compat/baseline/bl4.tree")}

// PLACES are the places a baseline is read for: this suite's own, and the one
// the compat fixtures were written for (cli/compat_test.odin PLACE).
@(private)
PLACES := [?]string{"/place", "/compat/place"}

// seeded puts the file this build wrote first, so the zero case is what it
// was, and the fixtures after it.
@(private)
seeded :: proc(store, baseline: []byte, allocator := context.allocator) -> Case {
	stores := make([][]byte, 1 + len(STORE_SEEDS), allocator)
	stores[0] = store
	copy(stores[1:], STORE_SEEDS[:])

	baselines := make([][]byte, 1 + len(BASELINE_SEEDS), allocator)
	baselines[0] = baseline
	copy(baselines[1:], BASELINE_SEEDS[:])
	return {stores, baselines}
}
