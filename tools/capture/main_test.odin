package main

import "../../scan"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

// Scale translated draws and clips into device pixels, then restore the
// probe's logical input frame.
@(test)
test_capture_scales_translations_and_restores_frame :: proc(t: ^testing.T) {
	frame: ui.Frame
	ui.frame_init(&frame)
	defer ui.frame_destroy(&frame)
	original := ops.translate(17, 23)
	append(&frame.draws, ui.Draw{transform = original})
	append(&frame.clips, ui.Clip{transform = original})
	scale_frame(&frame, 2)
	testing.expect_value(t, ops.apply(frame.draws[0].transform, {3, 5}), ops.Point{40, 56})
	testing.expect_value(t, frame.clips[0].transform, frame.draws[0].transform)
	scale_frame(&frame, 0.5)
	testing.expect_value(t, frame.draws[0].transform, original)
	testing.expect_value(t, frame.clips[0].transform, original)
}

@(test)
test_pointer_journey_eases_and_reaches_target :: proc(t: ^testing.T) {
	start := ops.Point{40, 200}
	end := ops.Point{300, 60}
	testing.expect_value(t, ease_pointer(start, end, -1), start)
	testing.expect_value(t, ease_pointer(start, end, 2), end)
	testing.expect_value(t, ease_pointer(start, end, 0.25), ops.Point{80.625, 178.125})
	previous := start
	for i in 1 ..= 21 {
		p := ease_pointer(start, end, f32(i) / 21)
		testing.expect(t, p.x > previous.x && p.y < previous.y)
		previous = p
	}
	testing.expect_value(t, previous, end)
}


@(test)
test_curved_pointer_stays_bounded_and_lands_exactly :: proc(t: ^testing.T) {
	start := ops.Point{20, 40}
	end := ops.Point{620, 40}
	testing.expect_value(t, ease_pointer(start, end, 0, 18), start)
	testing.expect_value(t, ease_pointer(start, end, 1, 18), end)
	testing.expect_value(t, ease_pointer(start, start, 0.5, 18), start)
	peak := ease_pointer(start, end, 0.5, 18)
	testing.expect(t, peak.y > start.y)
	testing.expect(t, ease_pointer(start, end, 0.5, -18).y < start.y)
	for i in 0 ..= 30 {
		p := ease_pointer(start, end, f32(i) / 30, 18)
		testing.expect(t, p.x >= start.x && p.x <= end.x)
		testing.expect(t, p.y >= start.y && p.y <= start.y + 18)
	}
}

@(test)
test_movie_dispatches_pointer_press_then_release :: proc(t: ^testing.T) {
	model: struct {
		presses, releases: int,
		pressed:           bool,
	}
	draw :: proc(gtx: ^ui.Ctx, user: rawptr) {
		m := (^struct {
				presses, releases: int,
				pressed:           bool,
			})(user)
		ops.transform_push(gtx.scene, ops.translate(40, 30))
		ops.input_area(gtx.scene, 1, ops.Rect{0, 0, 80, 20}, {.Press, .Release})
		ops.tag(gtx.scene, 1, "Control")
		ops.transform_pop(gtx.scene)
		for e in ui.events(gtx, 1) {
			if e.kind == .Press {m.presses += 1; m.pressed = true}
			if e.kind == .Release && m.pressed {m.releases += 1; m.pressed = false}
		}
	}
	h: render.Headless
	ui.probe_init(&h.p, draw, &model, {400, 300})
	defer ui.probe_destroy(&h.p)
	movie := Movie {
		at = {200, 250},
	}
	movie_tap(&movie, &h, "Control")
	testing.expect_value(t, movie.at, ops.Point{80, 40})
	testing.expect_value(t, model.presses, 1)
	testing.expect_value(t, model.releases, 1)
	testing.expect(t, !model.pressed)
}

//review:ignore name-overclaims the gate argument is a virtual threshold, not a timeout; allowed remains zero, so only cancellation releases this worker.
@(test)
test_stream_gate_returns_when_cancelled :: proc(t: ^testing.T) {
	tree: scan.Tree
	if !testing.expect(t, scan.tree_init(&tree) == nil) {return}
	defer scan.tree_destroy(&tree)
	worker := thread.create_and_start_with_poly_data(
		&tree,
		proc(t: ^scan.Tree) {stream_gate(t, time.Second)},
	)
	deadline := time.tick_now()._nsec + i64(2 * time.Second)
	for sync.atomic_load(&stream_clock.parked) == 0 &&
	    time.tick_now()._nsec < deadline {time.sleep(time.Millisecond)}
	testing.expect(t, sync.atomic_load(&stream_clock.parked) > 0)
	scan.cancel(&tree)
	thread.join(worker)
	thread.destroy(worker)
	stream_clock = {}
}
