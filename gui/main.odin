package leita_gui

import "jm:ui/shell"

import "../history"
import "../scan"
import "app"
import "brand"
@(require) import "leaks"
import "msg"
import "view"

// run opens the application on path. The executable owns process arguments.
run :: proc(path: string) {
	defer free_all(context.temp_allocator)

	// Each finished scan is kept, to compare the next with.
	kept := history.default_path()
	defer delete(kept)

	h := new(app.Host)
	defer free(h)

	app.init(h, path, shell.wake, kept, made_up = scan.synthetic_day())
	defer app.stop(h)

	m: view.Model
	view.model_init(&m, path, msg.system_locale())
	defer view.model_destroy(&m)

	faces := view.fonts()
	defer delete(faces)

	scripts := view.fallbacks(faces)
	defer delete(scripts)

	shell.run(
		{
			title = view.window_title(path),
			width = 1280,
			height = 820,
			min_width = 640,
			min_height = 420,
			ui = view.view,
			user = &m,
			fonts = faces,
			fallbacks = scripts,
			clear = {255, 255, 255, 255},
			data = app.data_host(h),
			title_bar = .Unified when ODIN_OS == .Darwin else .Drawn,
			icon_light = brand.png(false),
			icon_dark = brand.png(true),
		},
	)
}
