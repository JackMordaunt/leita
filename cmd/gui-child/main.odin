/*
Leita-child: the view half of Leita under hot reload, the process the host
respawns on every build. It holds only the view and its model; the frames' needs
and commands go to the host over the pipe, where the scan answers them.
*/
package main

import "core:debug/trace"

@(require) import "jm:debug"
import "jm:ui/child"

import "../../gui/msg"
import "../../gui/view"

main :: proc() {
	when ODIN_DEBUG {
		da: debug.Allocator
		debug.init(&da, context.allocator)
		defer debug.destroy(&da)
		defer debug.report(&da)
		context.allocator = debug.allocator(&da)
	}
	context.assertion_failure_proc = trace.assertion_failure_proc

	m: view.Model
	view.model_init(&m, "", msg.system_locale())
	defer view.model_destroy(&m)
	faces := view.fonts()
	defer delete(faces)
	scripts := view.fallbacks(faces)
	defer delete(scripts)
	child.run({ui = view.view, user = &m, fonts = faces, fallbacks = scripts})
	free_all(context.temp_allocator)
}
