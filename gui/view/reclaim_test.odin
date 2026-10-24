package leita_view

import "core:fmt"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../command"
import "../query"

@(private = "file")
Reclaim_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
reclaim_open :: proc(r: ^Reclaim_Rig) {
	model_init(&r.m, "/top")
	r.m.settings_read = true
	r.m.mode = .Reclaim
	r.m.generation = 1
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&r.h, view, &r.m, {1000, 700}, fonts)
	scanned(r, 1, 2)
}

@(private = "file")
reclaim_close :: proc(r: ^Reclaim_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

// scanned is the host saying scan generation is done and Reclaim has found n
// folders under /top, named for the generation.
@(private = "file")
scanned :: proc(r: ^Reclaim_Rig, generation: u32, n: int) {
	items := make([]query.Candidate, n, context.temp_allocator)
	for &it, i in items {
		it = {
			node  = u32(i + 1),
			path  = fmt.tprintf("/top/g%d/project%d/node_modules", generation, i),
			bytes = 4096,
		}
	}
	groups := []query.Reclaim_Group {
		{name = "Dependencies", reason = "Installed again.", items = items, bytes = u64(4096 * n)},
		{
			name = "Trash",
			reason = "Already deleted.",
			trash = true,
			items = items[:1],
			bytes = 4096,
		},
	}
	ui.probe_deliver(
		&r.h.p,
		query.Progress{},
		query.Progress_Result{generation = generation, state = .Done, target = "/top"},
	)
	ui.probe_deliver(
		&r.h.p,
		query.Reclaim{generation = generation, dir = query.ROOT},
		query.Reclaim_Result{generation = generation, ready = true, groups = groups, bytes = 8192},
	)
	ui.probe_advance(&r.h.p, 10, 1.0 / 60)
}

// Clean up names the folders it will delete, by path, and Delete sends them.
@(test)
clean_up_confirmation_lists_the_paths_and_deletes_them :: proc(t: ^testing.T) {
	r: Reclaim_Rig
	reclaim_open(&r)
	defer reclaim_close(&r)
	p := &r.h.p

	testing.expect(t, ui.probe_click(p, "Clean up"), "the panel's Clean up")
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, r.m.clean_open, "the confirmation opens")
	testing.expect(t, ui.probe_tagged(p, "/top/g1/project0/node_modules"), "the first path")
	testing.expect(t, ui.probe_tagged(p, "/top/g1/project1/node_modules"), "the second path")
	// Each stands on a line of its own under the warning, not drawn over it.
	body, has_body := last_tag(p, "How much disk space")
	first, has_first := last_tag(p, "/top/g1/project0/node_modules")
	second, has_second := last_tag(p, "/top/g1/project1/node_modules")
	testing.expect(t, has_body && has_first && has_second, "the warning and both paths")
	testing.expect(t, below(body, first), "the first path is under the warning")
	testing.expect(t, below(first, second), "the second path is under the first")

	testing.expect(t, ui.probe_click_top(p, "Delete"), "the dialog's Delete")
	clean, sent_clean := sent(p, command.Clean).?
	testing.expect(t, sent_clean, "Delete sends the batch")
	testing.expect_value(t, clean.count, 2)
	testing.expect_value(t, clean.generation, 1)
	testing.expect(t, !r.m.clean_open, "and the dialog closes")
}

// A long list is cut to what the dialog names and the rest counted.
@(test)
clean_up_confirmation_counts_what_it_does_not_list :: proc(t: ^testing.T) {
	r: Reclaim_Rig
	reclaim_open(&r)
	defer reclaim_close(&r)
	p := &r.h.p

	scanned(&r, 1, CLEAN_LISTED + 5)
	testing.expect(t, ui.probe_click(p, "Clean up"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(p, "and 5 more folders"), "the rest are counted")
	// The list scrolls; the buttons stay in the window.
	for name in ([2]string{"Delete", "Cancel"}) {
		b := ui.probe_bounds(p, name)
		testing.expectf(t, b.h > 0 && b.y + b.h <= p.size.y, "%s is in the window: %v", name, b)
	}
	testing.expect(t, ui.probe_click_top(p, "Delete"))
	clean, _ := sent(p, command.Clean).?
	testing.expect_value(t, clean.count, CLEAN_LISTED + 5) // all are deleted, not only the listed
}

// A new scan closes the Clean up and Empty Trash confirmations: their Delete
// would act on the new scan's default selection, which was never shown.
@(test)
a_new_scan_closes_the_delete_confirmations :: proc(t: ^testing.T) {
	r: Reclaim_Rig
	reclaim_open(&r)
	defer reclaim_close(&r)
	p := &r.h.p

	testing.expect(t, ui.probe_click(p, "Clean up"))
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, r.m.clean_open)
	r.m.empty_open, r.m.trash_node, r.m.trash_bytes = true, 1, 4096

	scanned(&r, 2, 3)
	ui.probe_advance(p, 10, 1.0 / 60)
	testing.expect(t, !r.m.clean_open, "Clean up is closed")
	testing.expect(t, !r.m.empty_open, "Empty Trash is closed")
	testing.expect_value(t, r.m.trash_node, 0)
	testing.expect_value(t, r.m.trash_bytes, 0)
	testing.expect(t, !ui.probe_click_top(p, "Delete"), "no Delete to press")
	testing.expect(t, !ui.probe_click_top(p, "Empty"), "no Empty to press")
	testing.expect(t, sent(p, command.Clean) == nil, "nothing is deleted")
	testing.expect(t, sent(p, command.Empty_Trash) == nil, "nothing is emptied")
}

// A candidate is named from under the folder shown, on the separator the scan
// joined it with.
@(test)
a_candidate_is_named_from_the_folder_shown :: proc(t: ^testing.T) {
	testing.expect_value(t, relative_path("/r/web/node_modules", "/r"), "web/node_modules")
	testing.expect_value(t, relative_path("/rx/web", "/r"), "/rx/web")
	when ODIN_OS == .Windows {
		testing.expect_value(
			t,
			relative_path(`C:\r\web\node_modules`, `C:\r`),
			`web\node_modules`,
		)
	}
}
