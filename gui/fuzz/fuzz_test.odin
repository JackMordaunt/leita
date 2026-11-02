package gui_fuzz

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import harness "jm:fuzz"
import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../../scan"
import "../../survey"
import "../app"
import "../query"
import "../view"

@(test)
suite_is_complete :: proc(t: ^testing.T) {
	s := suite()
	testing.expect_value(t, s.name, "gui")
	testing.expect_value(t, len(s.properties), 1)
	testing.expect_value(t, s.properties[0].name, "sequence")
	testing.expect(t, s.properties[0].check == check_sequence, "sequence runs check_sequence")
}

// No bytes are the simplest case: day 0, the window as it opens, light, the
// scan held at its top, and no actions. Shrinking converges on it.
@(test)
zero_bytes_open_the_window_as_it_opens_and_do_nothing :: proc(t: ^testing.T) {
	src := harness.source(nil)
	c := draw_case(&src)
	testing.expect_value(t, c.day, 0)
	testing.expect_value(t, c.size, SIZES[0])
	testing.expect_value(t, c.dark, false)
	testing.expect_value(t, c.first, 0)
	testing.expect_value(t, c.steps, 0)
	testing.expect_value(t, Action(harness.integer_in(&src, 0, len(Action))), Action.Wait)
}

// A short run on a fixed seed, in this process, so just gui-test catches a
// regression without a fuzz run: the window opens, takes a few actions and
// closes, and every invariant holds after each. The corpus is replayed first.
@(test)
a_fixed_seed_holds :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Minute)
	context.allocator = context.temp_allocator
	corpus := corpus_from_here()
	report := run({seed = 1, iterations = 2, corpus_dir = corpus, shrink = -1})
	testing.expect_value(t, report.iterations, 2 + report.replayed)
	if corpus != "" {
		testing.expect(t, report.replayed > 0, "the corpus was replayed first")
	}
	for f in report.failures {
		testing.expectf(
			t,
			false,
			"%s failed at case %d (replay: just fuzz gui %d 0 -iters=%d): %s",
			f.property,
			f.iteration,
			f.seed,
			f.iteration + 1,
			f.detail,
		)
	}
}

// corpus_from_here is the corpus when the test runs from the repository root,
// as just gui-test runs it, and none otherwise.
@(private = "file")
corpus_from_here :: proc() -> string {
	if os.exists(CORPUS) {
		return CORPUS
	}
	return ""
}

// The real view with explicitly delivered answers, without a desk thread.
// Private scan completion and published completion can be advanced separately.
@(private = "file")
publication_window :: proc() -> ^Window {
	w := new(Window)
	w.h.desk.scan = new(app.Scan)
	w.h.desk.scan.state = .Done
	w.h.desk.generation = 1
	view.model_init(&w.m, "/top")
	w.m.settings_read = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&w.hl, view.view, &w.m, {1280, 820}, fonts)
	return w
}

@(private = "file")
publication_close :: proc(w: ^Window) {
	render.headless_destroy(&w.hl)
	view.model_destroy(&w.m)
	sc := w.h.desk.scan
	survey.rollup_destroy(&sc.roll)
	if sc.grown {scan.tree_destroy(&sc.tree)}
	free(sc)
	free(w)
}

// Done on the desk precedes keep(d), which can still be writing history.
// Checking the frame before its matching Done arrives compares two times.
@(test)
private_completion_does_not_settle_an_unpublished_frame :: proc(t: ^testing.T) {
	w := publication_window()
	defer publication_close(w)
	ui.probe_deliver(
		&w.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Scanning, target = "/top"},
	)
	ui.probe_frame(&w.p)
	testing.expect_value(t, w.m.generation, 1)
	testing.expect(
		t,
		settled_scan(w) == nil,
		"private Done with published Scanning is not a settled frame",
	)

	ui.probe_deliver(
		&w.p,
		query.Progress{},
		query.Progress_Result{generation = 2, state = .Done, target = "/top"},
	)
	ui.probe_frame(&w.p)
	testing.expect(
		t,
		settled_scan(w) == nil,
		"published Done from another generation is not this scan",
	)

	ui.probe_deliver(
		&w.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = "/top"},
	)
	ui.probe_frame(&w.p)
	testing.expect(
		t,
		settled_scan(w) == w.h.desk.scan,
		"matching published Done permits the invariants",
	)
}

// Waiting for publication must not suppress a real stale-listing defect.
// A published Done followed by an old total is still an invariant failure;
// only the actual final listing makes that failure go away.
@(test)
published_completion_still_rejects_a_stale_listing :: proc(t: ^testing.T) {
	w := publication_window()
	defer publication_close(w)
	sc := w.h.desk.scan
	if !testing.expect(t, scan.tree_init(&sc.tree) == nil) {return}
	sc.grown = true
	if !testing.expect(t, scan.reserve(&sc.tree, 2) == nil) {return}
	root := scan.node(&sc.tree, 0)
	root.parent = 0
	root.name = scan.name_copy(&sc.tree, "/top")
	scan.node_publish(root, {.Used, .Settled, .Directory})
	file := scan.node(&sc.tree, 1)
	file.parent, file.disk = 0, 325
	file.name = scan.name_copy(&sc.tree, "file.bin")
	scan.node_publish(file, {.Used, .Settled})
	sc.roll.linked = true
	survey.rollup_advance(&sc.roll, &sc.tree)

	ui.probe_deliver(
		&w.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = "/top", bytes = 325},
	)
	ui.probe_frame(&w.p)
	listing := query.Listing_Result {
		generation = 1,
		dir        = 0,
		crumbs     = {{0, "/top"}},
		bytes      = 306,
		entries    = {{node = 1, name = "file.bin", bytes = 306, was = -1}},
	}
	ui.probe_deliver(&w.p, query.Listing{generation = 1, dir = query.ROOT}, listing)
	ui.probe_frame(&w.p)
	why := totals_agree(w)
	testing.expectf(
		t,
		strings.contains(why, "says \"306 B in 1 item\"") &&
		strings.contains(why, "the tree \"325 B in 1 item\""),
		"a stale published listing is rejected: %s",
		why,
	)

	listing.bytes = 325
	listing.entries[0].bytes = 325
	ui.probe_deliver(&w.p, query.Listing{generation = 1, dir = query.ROOT}, listing)
	ui.probe_frame(&w.p)
	testing.expect_value(t, totals_agree(w), "")
}
