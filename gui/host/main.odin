/*
Estoile-host: the window half of Estoile under hot reload. It owns the window
and the application, the scan and the pipeline answering the view, and runs the
view in a subprocess it respawns whenever the pointer file names a new build of
gui/child. Editing the view reloads it in place; the scan keeps running.

	Estoile-host build/hot/view.watch [PATH]

`just hot` builds this, keeps the pointer file fresh, and runs it.
*/
package main

import "core:debug/trace"
import "core:fmt"
import "core:os"

@(require) import "jm:debug"
import "jm:ui/shell"

import "../app"
import "../history"
@(require) import "../leaks"

main :: proc() {
	when ODIN_DEBUG {
		da: debug.Allocator
		debug.init(&da, context.allocator)
		defer debug.destroy(&da)
		defer debug.report(&da)
		context.allocator = debug.allocator(&da)
	}
	context.assertion_failure_proc = trace.assertion_failure_proc

	if len(os.args) < 2 {
		fmt.eprintfln("usage: %s <pointer-file.watch> [path]", os.args[0])
		os.exit(2)
	}
	path :=
		os.args[2] if len(os.args) > 2 else (os.user_home_dir(context.temp_allocator) or_else "/")

	h := new(app.Host)
	defer free(h)
	// Each finished scan is kept, to compare the next with.
	kept := history.default_path()
	defer delete(kept)
	app.init(h, path, shell.wake, kept)
	shell.run_host(
		{
			title = "estoile",
			width = 1280,
			height = 820,
			min_width = 640,
			min_height = 420,
			watch = os.args[1],
			clear = {255, 255, 255, 255},
			data = app.data_host(h),
		},
	)
	app.stop(h)
	free_all(context.temp_allocator)
}
