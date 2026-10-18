package main

import "core:testing"
import "jm:ui"
import "jm:ui/ops"

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
