// The window half of the logo lab: owns the SDL window and respawns the
// tools/logo child whenever the pointer file names a new build. It never
// links the marks' own code, so a rebuild of tools/logo is all a change
// takes. See `just logo`.
//
//	logo-host build/logo.watch          follow the watcher's builds
//	logo-host build/debug/logo          a fixed child, no reload
package main

import "jm:ui/shell"

main :: proc() {
	shell.run_host_from_args(
		{title = "estoile · logo lab", width = 1440, height = 960, clear = {250, 250, 247, 255}},
	)
}
