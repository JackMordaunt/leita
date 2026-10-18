package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "jm:ui"
import bl "jm:ui/blend2d"
import "jm:ui/ops"
import "jm:ui/render"

Movie :: struct {
	active: bool,
	//review:ignore odin-destroy-incomplete prefix borrows an os.args string for the lifetime of main.
	prefix: string,
	frame:  int,
	at:     ops.Point,
	//review:ignore odin-destroy-incomplete cue borrows an os.args string for the lifetime of main.
	cue:    string,
	arrow:  bl.PathCore,
	face:   bl.FontFaceCore,
	font:   bl.FontCore,
}

movie_init :: proc(m: ^Movie) {
	m.at = {1100, 100}
	bl.path_init(&m.arrow)
	points := [?]ops.Point {
		{0, 0},
		{0, 21},
		{5.5, 16.2},
		{9.6, 25.2},
		{13.1, 23.6},
		{9, 14.6},
		{16.5, 14.6},
	}
	for p, i in points {
		if i ==
		   0 {bl.path_move_to(&m.arrow, f64(p.x * 2), f64(p.y * 2))} else {bl.path_line_to(&m.arrow, f64(p.x * 2), f64(p.y * 2))}
	}
	bl.path_close(&m.arrow)
	bl.font_face_init(&m.face)
	bl.font_init(&m.font)
	path := strings.clone_to_cstring(ui.default_font(), context.temp_allocator)
	if bl.font_face_create_from_file(&m.face, path, {}) != 0 ||
	   bl.font_create_from_face(&m.font, &m.face, 32) != 0 {fail("capture cue font failed")}
}

movie_destroy :: proc(m: ^Movie) {
	bl.font_destroy(&m.font)
	bl.font_face_destroy(&m.face)
	bl.path_destroy(&m.arrow)
}

movie_overlay :: proc(m: ^Movie, image: ^bl.ImageCore) {
	ctx: bl.ContextCore
	bl.context_init(&ctx)
	defer bl.context_destroy(&ctx)
	if bl.context_begin(&ctx, image, nil) != 0 {fail("pointer overlay failed")}
	defer bl.context_end(&ctx)
	if m.cue != "" {
		box := bl.Rect{620, 1490, 1320, 100}
		bl.context_fill_rect_d_rgba32(&ctx, &box, 0xff111827)
		text_at := bl.Point{660, 1553}
		label := strings.clone_to_cstring(m.cue, context.temp_allocator)
		bl.context_fill_utf8_text_d_rgba32(
			&ctx,
			&text_at,
			&m.font,
			label,
			uint(len(m.cue)),
			0xffffffff,
		)
	}
	origin := bl.Point{f64(m.at.x * 2), f64(m.at.y * 2)}
	shadow := bl.Point{origin.x + 1, origin.y + 2}
	bl.context_set_stroke_width(&ctx, 4)
	bl.context_stroke_path_d_rgba32(&ctx, &shadow, &m.arrow, 0x30000000)
	bl.context_fill_path_d_rgba32(&ctx, &shadow, &m.arrow, 0x30000000)
	bl.context_set_stroke_width(&ctx, 2)
	bl.context_stroke_path_d_rgba32(&ctx, &origin, &m.arrow, 0xffffffff)
	bl.context_fill_path_d_rgba32(&ctx, &origin, &m.arrow, 0xff000000)
}

movie_frame :: proc(m: ^Movie, h: ^render.Headless) {
	if m.active && stream_clock.enabled {stream_frame(m, h)}
	ui.probe_set_dt(&h.p, 1.0 / 30)
	ui.probe_frame(&h.p)
	if m.active {
		if !png(
			h,
			fmt.tprintf("%s%05d.png", m.prefix, m.frame),
			m,
		) {fail("movie frame write failed")}
		m.frame += 1
	}
	free_all(context.temp_allocator)
}

movie_hold :: proc(m: ^Movie, h: ^render.Headless, count: int) {
	for _ in 0 ..< count {movie_frame(m, h)}
}

// Smoothstep has zero velocity at both ends of a pointer journey.
ease_pointer :: proc(start, end: ops.Point, fraction: f32) -> ops.Point {
	t := clamp(fraction, 0, 1)
	ease := t * t * (3 - 2 * t)
	return start + (end - start) * ease
}

movie_move :: proc(m: ^Movie, h: ^render.Headless, target: ops.Point, count: int) {
	start := m.at
	for i in 1 ..= count {
		m.at = ease_pointer(start, target, f32(i) / f32(count))
		ui.router_push(&h.p.router, {kind = .Move, pos = m.at})
		movie_frame(m, h)
	}
}

movie_tap :: proc(m: ^Movie, h: ^render.Headless, name: string) {
	hit, ok := ui.probe_find_top(&h.p, name)
	if !ok {fail(fmt.tprintf("no %q to demonstrate", name))}
	box := ops.transform_rect(hit.transform, ops.shape_bounds(&h.p.scene, hit.shape))
	target := ops.Point{box.x + box.w / 2, box.y + box.h / 2}
	movie_press(m, h, name, target)
}

movie_press :: proc(m: ^Movie, h: ^render.Headless, name: string, target: ops.Point) {
	fmt.printfln("ACTION\t%d\t%s\t%.3f\t%.3f", m.frame, name, target.x, target.y)
	movie_move(m, h, target, 21)
	movie_hold(m, h, 6)
	ui.router_push(&h.p.router, {kind = .Press, pos = m.at, button = .Left, clicks = 1})
	movie_hold(m, h, 5)
	ui.router_push(&h.p.router, {kind = .Release, pos = m.at, button = .Left})
	movie_hold(m, h, 18)
}

movie_step :: proc(m: ^Movie, h: ^render.Headless, args: []string, i: ^int) -> bool {
	flag := args[i^]
	if flag == "-stream" {return true}
	if flag == "-end-movie" {
		fmt.printfln("FRAMES\t%d", m.frame)
		m.active = false
		return true
	}
	if flag == "-movie" ||
	   flag == "-tap" ||
	   flag == "-hold" ||
	   flag == "-cue" ||
	   flag == "-chart" ||
	   flag == "-at" {
		if i^ + 1 >= len(args) {fail("movie step needs an argument")}
		i^ += 1
		value := args[i^]
		switch flag {
		case "-movie":
			m.prefix, m.frame, m.active = value, 0, true
			ui.router_push(&h.p.router, {kind = .Move, pos = m.at})
		case "-chart":
			movie_press(m, h, fmt.tprintf("chart %s", value), chart_target(h, value))
		case "-at":
			assert_location(m, value)
		case "-tap":
			movie_tap(m, h, value)
		case "-hold":
			count, ok := strconv.parse_int(value)
			if !ok || count < 1 {fail("invalid movie hold")}
			movie_hold(m, h, count)
		case "-cue":
			m.cue = value
			fmt.printfln("CUE\t%d\t%s", m.frame, value)
		}
		return true
	}
	if flag == "-glide" {
		if i^ + 3 >= len(args) {fail("-glide needs X Y FRAMES")}
		x, x_ok := strconv.parse_f32(args[i^ + 1])
		y, y_ok := strconv.parse_f32(args[i^ + 2])
		n, n_ok := strconv.parse_int(args[i^ + 3])
		if !x_ok || !y_ok || !n_ok || n < 1 {fail("invalid pointer journey")}
		i^ += 3
		movie_move(m, h, {x, y}, n)
		return true
	}
	return false
}
