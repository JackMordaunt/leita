// Capture the real application host and view without a desktop or personal state.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import "../../gui/app"
import "../../gui/view"
import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

// Rasterise the current draws and clips at 2×, then restore their transforms.
png :: proc(h: ^render.Headless, path: string) -> bool {
	frame := ui.probe_current(&h.p)
	scale_frame(frame, 2)
	defer scale_frame(frame, 0.5)
	return render.render_png(&h.r, frame, 2560, 1640, path, h.clear)
}

scale_frame :: proc(frame: ^ui.Frame, density: f32) {
	for &d in frame.draws {d.transform = ops.mul(d.transform, ops.scale(density, density))}
	for &c in frame.clips {c.transform = ops.mul(c.transform, ops.scale(density, density))}
}

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

main :: proc() {
	args := os.args
	if len(args) < 4 {
		fail(
			"usage: capture TARGET ISOLATED_DATA_DIR light|dark [jm headless steps] [-await TAG] [-rescan] [-pick PATH] [-signal PATH] [-await-file PATH] [-frames PREFIX COUNT]",
		)
	}
	if args[3] != "light" && args[3] != "dark" {fail("theme must be light or dark")}
	// The caller must create a dedicated directory. Never discover personal paths.
	if !os.exists(args[2]) {fail("create the isolated data directory first")}
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
		view.view,
		&model,
		{1280, 820},
		faces,
		fallbacks = fallbacks,
		data = &data,
	)
	defer render.headless_destroy(&h)
	h.p.density = 2
	// Reapply the requested theme before each scripted step and waiting frame.
	for i := 4; i < len(args); i += 1 {
		model.dark = args[3] == "dark"
		ui.probe_frame(&h.p)
		flag := args[i]
		switch flag {
		case "-png", "-await", "-pick", "-signal", "-await-file":
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
			case "-await", "-await-file":
				deadline := time.tick_now()._nsec + i64(120 * time.Second)
				for {
					model.dark = args[3] == "dark"
					ui.probe_frame(&h.p)
					ready := ui.probe_tagged(&h.p, value) if flag == "-await" else os.exists(value)
					if ready {break}
					if time.tick_now()._nsec >=
					   deadline {fail(fmt.tprintf("timeout: %s %s", flag, value))}
					time.sleep(10 * time.Millisecond)
				}
			}
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
			handled, ok := render.headless_step(&h, args, &i)
			if !handled || !ok {fail(fmt.tprintf("failed step: %s", flag))}
		}
	}
}
