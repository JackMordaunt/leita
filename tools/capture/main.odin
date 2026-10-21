// Capture the real application host and view without a desktop or personal state.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import bl "jm:ui/blend2d"

import "../../gui/app"
import "../../gui/view"
import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

// Rasterise the current draws and clips at 2×, then restore their transforms.
png :: proc(h: ^render.Headless, path: string, movie: ^Movie = nil) -> bool {
	frame := ui.probe_current(&h.p)
	scale_frame(frame, 2)
	defer scale_frame(frame, 0.5)
	image: bl.ImageCore
	bl.image_init(&image)
	defer bl.image_destroy(&image)
	if bl.image_create(&image, 2560, 1640, .PRGB32) != 0 {return false}
	render.render(&h.r, frame, &image, h.clear)
	if movie != nil {movie_overlay(movie, &image)}
	return(
		bl.image_write_to_file(
			&image,
			strings.clone_to_cstring(path, context.temp_allocator),
			nil,
		) ==
		0 \
	)
}

scale_frame :: proc(frame: ^ui.Frame, density: f32) {
	for &d in frame.draws {d.transform = ops.mul(d.transform, ops.scale(density, density))}
	for &c in frame.clips {c.transform = ops.mul(c.transform, ops.scale(density, density))}
}

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

// dump_tags prints every tag in the current frame, so a missed -await can be
// compared with the text the host actually drew.
dump_tags :: proc(h: ^render.Headless) {
	fmt.eprintln("tags:")
	for name in ui.probe_names(&h.p) {
		fmt.eprintln(name)
	}
}

// write_tags writes those tags, one per line.
write_tags :: proc(
	h: ^render.Headless,
	path: string,
	allocator := context.temp_allocator,
) -> bool {
	b := strings.builder_make(allocator)
	for name in ui.probe_names(&h.p) {
		strings.write_string(&b, name)
		strings.write_byte(&b, '\n')
	}
	return os.write_entire_file(path, strings.to_string(b)) == nil
}

main :: proc() {
	args := os.args
	if len(args) < 4 {
		fail(
			"usage: capture TARGET ISOLATED_DATA_DIR light|dark [jm headless steps] [-await TAG] [-absent TAG] [-click-top TAG] [-tags PATH] [-rescan] [-pick PATH] [-signal PATH] [-await-file PATH] [-frames PREFIX COUNT]",
		)
	}
	if args[3] != "light" && args[3] != "dark" {fail("theme must be light or dark")}
	// The caller must create a dedicated directory. Never discover personal paths.
	if !os.exists(args[2]) {fail("create the isolated data directory first")}
	for arg in args {
		if arg == "-stream" {stream_prepare()}
	}
	host: app.Host
	app.init(
		&host,
		args[1],
		kept = fmt.tprintf("%s/history.db", args[2]),
		reports = args[2],
		thumbs = args[2],
	)
	defer app.stop(&host)
	model: view.Model
	view.model_init(&model, args[1])
	defer view.model_destroy(&model)
	faces := view.fonts()
	defer delete(faces)
	fallbacks := view.fallbacks(faces)
	defer delete(fallbacks)
	data := app.data_host(&host)
	h: render.Headless
	render.headless_init(
		&h,
		capture_view,
		&model,
		{1280, 820},
		faces,
		fallbacks = fallbacks,
		data = &data,
	)
	defer render.headless_destroy(&h)
	h.p.density = 2
	movie: Movie
	movie_init(&movie)
	defer movie_destroy(&movie)
	// Reapply the requested theme before each scripted step and waiting frame.
	for i := 4; i < len(args); i += 1 {
		model.dark = args[3] == "dark"
		if !movie.active {ui.probe_frame(&h.p)}
		if movie_step(&movie, &h, args, &i) {continue}
		flag := args[i]
		switch flag {
		case "-png", "-await", "-absent", "-tags", "-pick", "-signal", "-await-file":
			if i + 1 >= len(args) {fail("step needs an argument")}
			i += 1
			value := args[i]
			switch flag {
			case "-png":
				if !png(&h, value) {fail("PNG write failed")}
			case "-pick":
				if !ui.probe_pick(&h.p, value) {fail("no save dialog is open")}
			case "-signal":
				if os.write_entire_file(value, "ready\n") != nil {fail("signal write failed")}
			case "-await", "-await-file", "-absent", "-tags":
				if movie.active && flag == "-await" {
					if !ui.probe_tagged(&h.p, value) {
						dump_tags(&h)
						fail(fmt.tprintf("movie did not reach %s", value))
					}
					continue
				}
				if flag == "-tags" {
					if !write_tags(&h, value) {fail("could not write tags")}
					continue
				}
				if flag == "-absent" {
					if ui.probe_tagged(&h.p, value) {
						dump_tags(&h)
						fail(fmt.tprintf("unexpected tag %s", value))
					}
					continue
				}
				deadline := time.tick_now()._nsec + i64(120 * time.Second)
				for {
					model.dark = args[3] == "dark"
					if !movie.active {ui.probe_frame(&h.p)}
					ready := ui.probe_tagged(&h.p, value) if flag == "-await" else os.exists(value)
					if ready {break}
					if time.tick_now()._nsec >= deadline {
						if flag == "-await" {dump_tags(&h)}
						fail(fmt.tprintf("timeout: %s %s", flag, value))
					}
					time.sleep(10 * time.Millisecond)
				}
			}
		case "-click-top":
			// -click is the first area with the tag. A quiet banner and the
			// dialog on top of it can share a name; this hits the last-drawn one.
			if i + 1 >= len(args) {fail("-click-top needs a tag")}
			i += 1
			if movie.active {fail("use -tap while recording")}
			if !ui.probe_click_top(&h.p, args[i]) {
				dump_tags(&h)
				fail(fmt.tprintf("no %q on top to click", args[i]))
			}
			ui.probe_frame(&h.p)
		case "-rescan":
			before := model.generation
			ui.probe_key(&h.p, .R, {.Ctrl})
			deadline := time.tick_now()._nsec + i64(120 * time.Second)
			for model.generation <= before || !ui.probe_tagged(&h.p, "Done") {
				ui.probe_frame(&h.p)
				if time.tick_now()._nsec >= deadline {fail("rescan timed out")}
				time.sleep(10 * time.Millisecond)
			}
		case "-frames":
			if i + 2 >= len(args) {fail("-frames needs PREFIX COUNT")}
			prefix := args[i + 1]
			n, ok := strconv.parse_int(args[i + 2])
			if !ok || n < 1 {fail("invalid frame count")}
			i += 2
			for j in 0 ..< n {
				model.dark = args[3] == "dark"
				ui.probe_set_dt(&h.p, 1.0 / 30)
				ui.probe_frame(&h.p)
				if !png(&h, fmt.tprintf("%s%05d.png", prefix, j)) {fail("frame write failed")}
				free_all(context.temp_allocator)
			}
		case:
			// -type only queues a Text event. The next -hold draws it.
			if movie.active &&
			   flag != "-type" {fail("use -tap, -hold, -glide and -type while recording")}
			handled, ok := render.headless_step(&h, args, &i)
			if !handled || !ok {fail(fmt.tprintf("failed step: %s", flag))}
		}
	}
}
