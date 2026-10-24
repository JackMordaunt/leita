/*
Package fuzz reads a history store and a baseline from bytes that are not a
file this package wrote.

	store     a damaged store is reported, and it is not deleted or rewritten
	          unless it was empty or already a sqlite database
	baseline  a damaged baseline is refused, and the file is left as it was
	keep      a kept scan comes back with the entries of at least KEPT_MIN

The store file and a sibling canary are created in a temp directory and
removed after the asserts. Nothing here deletes a path it did not create.
*/
package history_fuzz

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"

import harness "jm:fuzz"

import history ".."
import "../../changes"
import "../../scan"
import "../../survey"

Case :: struct {
	store:    []byte,
	baseline: []byte,
}

properties := []harness.Property(Case) {
	{"store", check_store},
	{"baseline", check_baseline},
	{"keep", check_keep},
}

CORPUS :: "history/fuzz/corpus"

// INPUT_CAP is as long a file as a case may hand the readers. One snapshot
// store is 24576 bytes of sqlite pages. A splice of the store with itself is
// up to twice that, so the cap is twice the store and a little over.
INPUT_CAP :: 64 * 1024

suite :: proc() -> harness.Suite(Case) {
	return {name = "history", setup = setup, teardown = teardown, properties = properties}
}

run :: proc(opts := harness.Opts{}, allocator := context.allocator) -> harness.Report {
	return harness.run(suite(), opts, allocator)
}

setup :: proc() -> (Case, bool) {
	store := fresh_store()
	base := fresh_baseline()
	if store == nil || base == nil {
		return {}, false
	}
	return Case{store, base}, true
}

teardown :: proc(_: ^Case) {}

// check_store opens one damaged file. The file and a sibling canary are both
// still there afterwards. A refused open leaves the bytes alone. A successful
// open may rewrite them only when they were already a database, or empty.
check_store :: proc(c: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	raw, _ := harness.damage(src, {c.store})
	if len(raw) > INPUT_CAP {
		return fmt.tprintf("drew %d bytes, cap is %d", len(raw), INPUT_CAP), false
	}
	dir, err := os.make_directory_temp("", "leita-fuzz-*", context.temp_allocator)
	if err != nil {
		return "no temp directory", false
	}
	defer os.remove_all(dir)
	path := filepath.join({dir, "history.db"}, context.temp_allocator) or_else ""
	canary := filepath.join({dir, "canary"}, context.temp_allocator) or_else ""
	if os.write_entire_file(path, raw) != nil ||
	   os.write_entire_file(canary, []byte{1, 2, 3, 4}) != nil {
		return "could not write the store", false
	}
	before := read_file(path)
	st: history.Store
	open_err := history.open(&st, path)
	if open_err == nil {
		history.close(&st)
	}
	if !os.exists(path) {
		return "the store was deleted", false
	}
	if !slice.equal(read_file(canary), []byte{1, 2, 3, 4}) {
		return "a sibling of the store was changed", false
	}
	after := read_file(path)
	if open_err != nil {
		if !slice.equal(before, after) {
			return "a refused store was rewritten", false
		}
		return "", true
	}
	if len(before) == 0 || header_is_sqlite(before) {
		return "", true
	}
	if !slice.equal(before, after) {
		return "a file that is not a sqlite database was rewritten", false
	}
	return "", true
}

// check_baseline loads one damaged file. The reader only reads, so the file
// and a sibling canary stay byte for byte what was written.
check_baseline :: proc(c: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	raw, _ := harness.damage(src, {c.baseline})
	if len(raw) > INPUT_CAP {
		return fmt.tprintf("drew %d bytes, cap is %d", len(raw), INPUT_CAP), false
	}
	dir, err := os.make_directory_temp("", "leita-fuzz-*", context.temp_allocator)
	if err != nil {
		return "no temp directory", false
	}
	defer os.remove_all(dir)
	path := filepath.join({dir, "place.tree"}, context.temp_allocator) or_else ""
	canary := filepath.join({dir, "canary"}, context.temp_allocator) or_else ""
	if os.write_entire_file(path, raw) != nil ||
	   os.write_entire_file(canary, []byte{1, 2, 3, 4}) != nil {
		return "could not write the baseline", false
	}
	before := read_file(path)
	tree: scan.Tree
	_, _, loaded := survey.baseline_load(path, "/place", &tree)
	defer scan.tree_destroy(&tree)
	if !os.exists(path) {
		return "the baseline was deleted", false
	}
	if !slice.equal(read_file(path), before) {
		return "the baseline was rewritten", false
	}
	if !slice.equal(read_file(canary), []byte{1, 2, 3, 4}) {
		return "a sibling of the baseline was changed", false
	}
	if loaded && scan.slots(&tree) == 0 {
		return "a baseline that loaded has no nodes", false
	}
	return "", true
}

// check_keep saves one drawn scan in memory and reads it back. An entry under
// KEPT_MIN is absent. The top is present, and it holds the child's bytes.
check_keep :: proc(_: Case, src: ^harness.Source) -> (detail: string, ok: bool) {
	disk := u64(harness.integer_in(src, 0, 5)) * (1 << 20)
	tree: scan.Tree
	if scan.tree_init(&tree) != nil {
		return "tree was not created", false
	}
	defer scan.tree_destroy(&tree)
	w := scan.writer(&tree, 0)
	first, claim_err := scan.claim(&w, 2)
	if claim_err != nil || first != 0 {
		return "the tree has no slots", false
	}
	tree.root = 0
	publish(&w, 0, 0, "/top", 0, {.Directory})
	publish(&w, 1, 0, "big", disk, nil)
	roll := survey.Rollup {
		linked = true,
	}
	defer survey.rollup_destroy(&roll)
	survey.rollup_advance(&roll, &tree)

	st: history.Store
	if history.open(&st, ":memory:") != nil {
		return "the store did not open", false
	}
	defer history.close(&st)
	id, save_err := history.keep(&st, "/top", &tree, &roll, 0, 2)
	if save_err != nil {
		return "the scan was not kept", false
	}
	got, load_err := history.load(&st, id)
	if load_err != nil {
		return "the snapshot did not load", false
	}
	defer history.forget(got)
	if got[""] != disk {
		return fmt.tprintf("top held %d, want %d", got[""], disk), false
	}
	_, kept := got["big"]
	if disk >= history.KEPT_MIN {
		if !kept || got["big"] != disk {
			return fmt.tprintf("big held %d, want %d", got["big"], disk), false
		}
	} else if kept {
		return "an entry under KEPT_MIN was kept", false
	}
	return "", true
}

@(private)
publish :: proc(w: ^scan.Writer, i, parent: u32, name: string, disk: u64, extra: scan.Node_Flags) {
	n := scan.node(w.tree, i)
	n.parent = parent
	n.disk = disk
	n.name = scan.intern(w, name)
	scan.node_publish(n, {.Used, .Settled} + extra)
}

@(private)
fresh_store :: proc() -> []byte {
	dir, err := os.make_directory_temp("", "leita-fuzz-*", context.temp_allocator)
	if err != nil {
		return nil
	}
	defer os.remove_all(dir)
	path := filepath.join({dir, "history.db"}, context.temp_allocator) or_else ""
	st: history.Store
	if history.open(&st, path) != nil {
		return nil
	}
	entries := []history.Entry{{"", 2 << 20}, {"big", 2 << 20}}
	_, save_err := history.save(&st, "/top", 1000, 2 << 20, 2, entries)
	history.close(&st)
	if save_err != nil {
		return nil
	}
	return read_file(path)
}

@(private)
fresh_baseline :: proc() -> []byte {
	dir, err := os.make_directory_temp("", "leita-fuzz-*", context.temp_allocator)
	if err != nil {
		return nil
	}
	defer os.remove_all(dir)
	path := filepath.join({dir, "place.tree"}, context.temp_allocator) or_else ""
	tree: scan.Tree
	if scan.tree_init(&tree) != nil {
		return nil
	}
	defer scan.tree_destroy(&tree)
	w := scan.writer(&tree, 0)
	first, claim_err := scan.claim(&w, 1)
	if claim_err != nil {
		return nil
	}
	tree.root = first
	publish(&w, first, first, "/place", 0, {.Directory})
	if !survey.baseline_save(path, "/place", &tree, changes.Cursor{}) {
		return nil
	}
	return read_file(path)
}

// header_is_sqlite is true for the prefix this suite allows open to rewrite.
// An empty file is allowed too; any other bytes must come back unchanged.
@(private)
header_is_sqlite :: proc(b: []byte) -> bool {
	h := history.SQLITE_HEADER
	return len(b) >= len(h) && string(b[:len(h)]) == h
}

@(private)
read_file :: proc(path: string) -> []byte {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil
	}
	return data
}
