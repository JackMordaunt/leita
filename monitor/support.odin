package leita_monitor

import "../licence"
import "../settings"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// place_of is path as a place is watched: absolute, in the temp allocator.
place_of :: proc(path: string) -> string {
	abs, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil {
		return path
	}
	if len(abs) > 1 {
		abs = strings.trim_right(abs, `/\`)
		if len(abs) == 2 && abs[1] == ':' {
			abs = strings.concatenate({abs, `\`}, context.temp_allocator)
		}
	}
	return abs
}

/*
licence_beside is whose licence leita runs under at now for the stores beside
the history store at kept, "" for none, and whether Pro works. Pro is
licence.entitled_to_pro: the paid-through grant for this build, or the 30-day
evaluation (settings.trial_began). given is the licence LEITA_LICENCE holds for
this run, in place of the one kept. key is what a licence is checked against,
nil for the key leita was built with. problem says why given was not taken, ""
when it was or there is none; the run goes on without it. The command line's
report and the monitor both ask here. In the temp allocator.
*/
licence_beside :: proc(
	kept, given: string,
	now: time.Time,
	key: []byte = nil,
) -> (
	licensee: string,
	unlocked: bool,
	problem: string,
) {
	l, from, err := licence.in_use(licence.path_beside(kept, context.temp_allocator), given, key)
	if from == .Env && err != .None {
		problem = fmt.tprintf(
			"%s holds no licence this leita takes: %s",
			licence.ENV,
			licence.describe(err),
		)
	}
	checked: licence.Licence
	if err == .None {
		licensee = l.licensee
		checked = l
	}
	return licensee,
		licence.entitled_to_pro(checked, settings.trial_began(kept, now), now),
		problem
}
