package leita_settings

import "core:time"

import "../licence"

/*
TRIAL is when the 30-day Pro evaluation began, in unix seconds. It is
kept here as well as in the first-use file beside this store
(licence.first_use), so that deleting either does not start the trial again.
*/
TRIAL :: "trial"

// trial_ledger keeps the trial's start in st for licence.first_use; nil keeps
// it nowhere.
trial_ledger :: proc(st: ^Store) -> licence.Ledger {
	if st == nil {
		return {}
	}
	return {user = st, get = trial_get, set = trial_set}
}

/*
trial_began is when the trial began, as the first-use file and the store
beside the history store at kept remember it (licence.first_use): for the
command line, which opens the store for this alone. A store that will not open
leaves the file to remember it alone.
*/
trial_began :: proc(kept: string, now: time.Time) -> time.Time {
	if kept == "" {
		return licence.first_use("", {}, now)
	}
	st: Store
	opened := open(&st, licence.path_beside(kept, context.temp_allocator, FILE)) == nil
	defer if opened {
		close(&st)
	}
	return licence.first_use(
		licence.path_beside(kept, context.temp_allocator, licence.FIRST_USE),
		trial_ledger(&st if opened else nil),
		now,
	)
}

@(private = "file")
trial_get :: proc(user: rawptr) -> (string, bool) {
	return get((^Store)(user), TRIAL, context.temp_allocator)
}

@(private = "file")
trial_set :: proc(user: rawptr, text: string) -> bool {
	return set((^Store)(user), TRIAL, text) == nil
}
