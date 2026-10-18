/*
Package fuzz rolls up a tree built from the case bytes.

	rollup  survey totals equal a serial charge of the same nodes

The tree is created and destroyed inside the property. A copied subject
would leak the address reservation. Names stay short. A symlink's disk is
0: rollup.charge counts a reparse, and the fold's charged_bytes does not.
*/
package scan_fuzz

import "core:fmt"

import harness "jm:fuzz"

import scan ".."
import survey "../../survey"

Case :: struct {}

properties := []harness.Property(Case){{"rollup", check_rollup}}

CORPUS :: "scan/fuzz/corpus"

suite :: proc() -> harness.Suite(Case) {
	return {name = "scan", setup = setup, teardown = teardown, properties = properties}
}

run :: proc(opts := harness.Opts{}, allocator := context.allocator) -> harness.Report {
	return harness.run(suite(), opts, allocator)
}

setup :: proc() -> (Case, bool) {
	return {}, true
}

teardown :: proc(_: ^Case) {}

Shape :: struct {
	extra: u64,
	other: u64,
	deep:  bool,
}

check_rollup :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	tree: scan.Tree
	if scan.tree_init(&tree) != .None {
		return "tree was not created", false
	}
	defer scan.tree_destroy(&tree)
	shape := fill(&tree, src)
	roll: survey.Rollup
	roll.linked = true
	defer survey.rollup_destroy(&roll)
	survey.rollup_advance(&roll, &tree)

	count := int(scan.slots(&tree))
	serial := serial_charge(&tree, count)
	for i in 0 ..< count {
		got := survey.total(&roll, u32(i))
		if got != serial[i] {
			//review:ignore odin-temp-in-loop the formatted string is the failure return; the loop stops
			return fmt.tprintf("node %d total %d, serial %d", i, got, serial[i]), false
		}
	}
	if shape.other > 0 && serial[0] + shape.other == serial[0] {
		return "other-device bytes disappeared into a wrap", false
	}
	// The other-device counter is not a node, so it is not in the root.
	if shape.deep {
		sum: u64
		for i in 0 ..< count {
			sum += scan.node(&tree, u32(i)).disk
		}
		if serial[0] >= sum {
			return "a chain past 64 still charged the leaf to the root", false
		}
	}
	return "", true
}

// fill writes one tree. Zero entropy is a root and one file.
@(private)
fill :: proc(t: ^scan.Tree, src: ^harness.Source) -> Shape {
	deep := harness.byte_of(src) == 1
	n := 8
	if deep {
		n = 70
	} else {
		n = harness.integer_in(src, 2, 40)
	}
	w := scan.writer(t, 0)
	first, err := scan.claim(&w, u32(n))
	if err != nil || first != 0 {
		return {}
	}
	t.root = 0
	shape: Shape
	shape.deep = deep
	for i in 0 ..< n {
		node := scan.node(t, u32(i))
		node.name = scan.intern(&w, letter(i))
		flags: scan.Node_Flags = {.Used, .Settled}
		if i == 0 {
			node.parent = 0
			flags += {.Directory}
			node.disk = 0
		} else if deep {
			node.parent = u32(i - 1)
			flags += {.Directory}
			node.disk = 100
		} else if i == n - 1 {
			// Another name for the file at 1. Its disk must not be charged.
			node.parent = 0
			flags += {.Extra_Name}
			node.disk = 50
			shape.extra = 50
		} else if i == n - 2 {
			// A mount. What is on the other device is not in this tree.
			node.parent = 0
			flags += {.Directory, .Mount}
			node.disk = 10
			shape.other = 1000
		} else if harness.boolean(src) {
			node.parent = 0
			flags += {.Directory}
			node.disk = u64(harness.integer_in(src, 0, 9)) * 100
		} else {
			node.parent = 0
			node.disk = u64(harness.integer_in(src, 0, 9)) * 100
		}
		scan.node_publish(node, flags)
	}
	return shape
}

@(private)
letter :: proc(i: int) -> string {
	letters := "abcdefghijklmnopqrstuvwxyz"
	return letters[i % len(letters):][:1]
}

// serial_charge is rollup.charge for a finished tree: extra names are
// skipped, a directory keeps its own disk, ancestors stop at 64, and an
// unsettled ancestor charges nothing.
@(private)
serial_charge :: proc(t: ^scan.Tree, count: int) -> []u64 {
	serial := make([]u64, count)
	for i in 0 ..< count {
		n := scan.node(t, u32(i))
		flags := scan.node_flags(n)
		if .Used not_in flags || .Settled not_in flags || .Extra_Name in flags {
			continue
		}
		chain: [64]u32
		depth := 0
		cur := u32(i)
		pending := false
		for depth < len(chain) {
			c := scan.node(t, cur)
			if .Settled not_in scan.node_flags(c) {
				pending = true
				break
			}
			if c.parent == cur || int(c.parent) >= count {
				break
			}
			chain[depth] = c.parent
			depth += 1
			cur = c.parent
		}
		if pending {
			continue
		}
		if .Directory in flags {
			serial[i] += n.disk
		}
		for j in 0 ..< depth {
			serial[chain[j]] += n.disk
		}
	}
	return serial
}
