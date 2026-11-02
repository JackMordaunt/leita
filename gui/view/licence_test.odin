package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../command"
import "../query"

@(private = "file")
Licence_Case :: struct {
	m:      Model,
	frames: [dynamic]bool, // what unlocked said before each frame was drawn
}

@(private = "file")
licence_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	c := (^Licence_Case)(user)
	append(&c.frames, unlocked(gtx, &c.m))
	view(gtx, &c.m)
}

// Pro is open on the first frame, before the host can have answered; after it,
// a host that has not answered leaves Pro locked. Export still opens: a CSV of
// this scan is free, and a locked window starts on that format. Once the host
// says Pro is on, Export opens on whatever format was left.
@(test)
no_licence_answer_is_locked_after_the_first_frame :: proc(t: ^testing.T) {
	c: Licence_Case
	c.frames = make([dynamic]bool, context.temp_allocator)
	model_init(&c.m, "/top")
	c.m.settings_read = true
	defer model_destroy(&c.m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, licence_frame, &c, {1000, 700}, fonts)
	defer render.headless_destroy(&h)
	ui.probe_deliver(
		&h.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = "/top"},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	if testing.expect(t, len(c.frames) >= 2) {
		testing.expect(t, c.frames[0], "the first frame is unlocked")
		testing.expect(t, !c.frames[len(c.frames) - 1], "after it, no answer is locked")
	}

	testing.expect(t, choose(&h.p, &c.m, "Export"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, c.m.export_open, "no licence still opens export")
	testing.expect(t, !c.m.licence_open, "and not the licence dialog")
	testing.expect_value(t, c.m.export_format, command.Export_Format.Csv)

	c.m.export_open = false
	c.m.licence_open = false
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	ui.probe_deliver(&h.p, query.Licence{}, query.Licence_Result{unlocked = true, trial_left = 30})
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(t, choose(&h.p, &c.m, "Export"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, c.m.export_open, "unlocked, Export opens")
}

@(private = "file")
rights_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	view(gtx, (^Model)(user))
}

// The licence dialog names the paid-through date and this build's rights.
// The date is not the evaluation ending.
@(test)
the_licence_dialog_names_paid_through_and_this_build :: proc(t: ^testing.T) {
	m: Model
	model_init(&m, "/top")
	m.settings_read = true
	m.licence_open = true
	defer model_destroy(&m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, rights_frame, &m, {1000, 700}, fonts)
	defer render.headless_destroy(&h)
	ui.probe_deliver(
		&h.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Done, target = "/top"},
	)
	ui.probe_deliver(
		&h.p,
		query.Licence{},
		query.Licence_Result {
			licensed = true,
			unlocked = true,
			licensee = "Ada",
			tier = "Professional",
			order = "ord_7",
			issued = "2026-10-19T12:00:00Z",
			paid_through = "2027-10-19T00:00:00Z",
			release_at = "2026-10-01T00:00:00Z",
			build_covered = true,
		},
	)
	ui.probe_advance(&h.p, 4, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(
			&h.p,
			"Pro covers releases through 2027-10-19T00:00:00Z. This installed build is covered.",
		),
	)
	testing.expect(t, !ui.probe_tagged(&h.p, "Your 30-day Pro evaluation has ended"))

	ui.probe_deliver(
		&h.p,
		query.Licence{},
		query.Licence_Result {
			licensed = true,
			unlocked = false,
			licensee = "Ada",
			tier = "Professional",
			order = "ord_7",
			issued = "2026-10-19T12:00:00Z",
			paid_through = "2027-10-19T00:00:00Z",
			release_at = "2028-01-01T00:00:00Z",
			build_covered = false,
		},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(
			&h.p,
			"Pro covers releases through 2027-10-19T00:00:00Z. This installed build (2028-01-01T00:00:00Z) is after that date. Pro stays on the builds the date covers.",
		),
	)
	testing.expect(
		t,
		!ui.probe_tagged(&h.p, "expired"),
		"the paid-through date is not called an expiry",
	)

	ui.probe_deliver(
		&h.p,
		query.Licence{},
		query.Licence_Result {
			licensed = true,
			unlocked = false,
			licensee = "Ada",
			paid_through = "2027-10-19T00:00:00Z",
		},
	)
	ui.probe_advance(&h.p, 2, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(
			&h.p,
			"Pro covers releases through 2027-10-19T00:00:00Z. This build has no release date, so that date does not cover it.",
		),
	)
}

// The key exchange stays usable in a small window, including a refusal that
// makes the body longer. The action buttons stay on screen while the body scrolls.
@(test)
the_licence_dialog_keeps_its_actions_in_a_small_window :: proc(t: ^testing.T) {
	for scenario in ([]struct {
			dark:   bool,
			height: f32,
		}{{false, 360}, {true, 360}, {false, 720}, {true, 720}}) {
		dark, height := scenario.dark, scenario.height
		m: Model
		model_init(&m, "/top")
		m.settings_read = true
		m.licence_open = true
		ui.text_set(&m.licence_text, "FIXTURE-KEY")
		pin_theme(&m, dark)
		defer model_destroy(&m)
		fonts := []ops.Font_Ref {
			{0, ui.default_font(), 400},
			{1, ui.default_font(), 500},
			{2, ui.default_font(), 600},
			{3, ui.default_font(), 400},
		}
		h: render.Headless
		render.headless_init(&h, rights_frame, &m, {480, height}, fonts)
		defer render.headless_destroy(&h)
		ui.probe_deliver(
			&h.p,
			query.Progress{},
			query.Progress_Result{generation = 1, state = .Done, target = "/top"},
		)
		result := query.Licence_Result {
			trial_left = 30,
			unlocked   = true,
		}
		ui.probe_deliver(&h.p, query.Licence{}, result)
		ui.probe_advance(&h.p, 30, 1.0 / 60)
		for failed in ([]bool{false, true}) {
			if failed {
				m.licence_answered = true
				result.problem = "Leita could not reach the licence server. Check the connection, or open the licence file from your receipt instead."
				result.offered += 1
				ui.probe_deliver(&h.p, query.Licence{}, result)
				ui.probe_advance(&h.p, 5, 1.0 / 60)
			}
			for name in ([]string{"Add licence", "Close"}) {
				hit, found := ui.probe_find_top(&h.p, name)
				if !testing.expectf(t, found, "%s is drawn", name) {continue}
				box := ops.transform_rect(hit.transform, ops.shape_bounds(&h.p.scene, hit.shape))
				testing.expectf(
					t,
					box.x >= 0 && box.x + box.w <= 480 && box.y >= 0 && box.y + box.h <= height,
					"%s is inside the window: %v (dark=%v, refusal=%v)",
					name,
					box,
					dark,
					failed,
				)
			}
			// A wheel over the dialog reaches the key field. A tag alone would
			// pass even if the field were clipped outside its scroll viewport.
			ui.text_set(&m.licence_text, "")
			for i := 0; i < 20; i += 1 {
				field, found := ui.probe_find_top(&h.p, "Licence to add")
				box := ops.transform_rect(
					field.transform,
					ops.shape_bounds(&h.p.scene, field.shape),
				)
				under, visible := ui.hit_test(
					ui.probe_current(&h.p),
					{box.x + box.w / 2, box.y + box.h / 2},
					.Press,
				)
				if found && visible && under.area == field.area {
					ui.probe_click(&h.p, "Licence to add")
					break
				}
				ui.probe_scroll_at(&h.p, {240, height / 2}, 1)
				ui.probe_advance(&h.p, 10, 1.0 / 60)
			}
			testing.expect_value(t, ui.probe_focus_name(&h.p), "Licence to add")
			ui.probe_type(&h.p, "FIXTURE-KEY")
			ui.probe_frame(&h.p)
			testing.expect_value(t, ui.text_string(&m.licence_text), "FIXTURE-KEY")
		}
		testing.expect(t, ui.probe_click_top(&h.p, "Close"))
		ui.probe_frame(&h.p)
		testing.expect(t, !m.licence_open, "the visible Close button closes the dialog")
	}
}
