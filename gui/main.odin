/*
sonar-gui: see what is using the disk, as the scan finds it.

	sonar-gui              scan the home directory
	sonar-gui PATH         scan a directory, drive or image

The window is jm:ui in Primer. Its pieces are gui's packages:

	query    the reads the window may need, and their results   (leaf)
	command  what the window may ask the application to do      (leaf)
	app      the host: the pipeline, the desk and the reader     (io)
	view     the window: shapes in, commands out                 (ui)

This is the window around app.
*/
package main

import "core:debug/trace"
import "core:os"

@(require) import "jm:debug"
import "jm:ui"
import "jm:ui/ops"
import "jm:ui/shell"

import "app"
import "view"

main :: proc() {
	when ODIN_DEBUG {
		da: debug.Allocator
		debug.init(&da, context.allocator)
		defer debug.destroy(&da)
		defer debug.report(&da)
		context.allocator = debug.allocator(&da)
	}
	context.assertion_failure_proc = trace.assertion_failure_proc

	path :=
		os.args[1] if len(os.args) > 1 else (os.user_home_dir(context.temp_allocator) or_else "/")

	h := new(app.Host)
	defer free(h)
	app.init(h, path, shell.wake)

	m: view.Model
	view.model_init(&m, path)
	defer view.model_destroy(&m)

	faces := fonts()
	defer delete(faces)

	shell.run(
		{
			title = "sonar",
			width = 1280,
			height = 820,
			min_width = 640,
			min_height = 420,
			ui = view.view,
			user = &m,
			fonts = faces,
			clear = {255, 255, 255, 255},
			data = app.data_host(h),
		},
	)
	app.stop(h)
	free_all(context.temp_allocator)
}

// fonts are the faces view.FONTS names: jm:ui's default font at Primer's three
// weights, and again as the monospace face.
fonts :: proc() -> []ops.Font_Ref {
	path := ui.default_font()
	out := make([]ops.Font_Ref, 4)
	weights := [3]f32{400, 500, 600}
	for w, i in weights {
		out[i] = {
			id     = ops.Font_Id(i),
			path   = path,
			weight = w,
		}
	}
	out[3] = {
		id     = 3,
		path   = path,
		weight = 400,
	}
	return out
}

/*
What LeakSanitizer is not to report in a build under -sanitize:address: the one
allocation the system's EGL makes, through pthread_once, when SDL loads it for the
window's renderer, and keeps for the life of the process. It is the driver's, not
sonar's; reported, it would bury a real leak under one nobody can fix here.
*/
@(export, link_name = "__lsan_default_suppressions")
lsan_default_suppressions :: proc "c" () -> cstring {
	return "leak:SDL_EGL_LoadLibrary\n"
}
