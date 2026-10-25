package leita_settings

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "../licence"
import "../testtmp"

// The trial's start is kept in the store as well as the first-use file, so
// deleting the file gives it back rather than starting the trial again.
@(test)
the_store_keeps_the_trial_start_when_the_file_is_deleted :: proc(t: ^testing.T) {
	dir, derr := testtmp.make_dir("", "leita-trial-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	kept, _ := filepath.join({dir, "data", "history.db"}, context.temp_allocator)
	now := time.unix(1_800_000_000, 0)

	testing.expect_value(t, time.to_unix_seconds(trial_began(kept, now)), 1_800_000_000)
	file := licence.path_beside(kept, context.temp_allocator, licence.FIRST_USE)
	testing.expect(t, os.remove(file) == nil)
	later := time.time_add(now, 40 * licence.DAY)
	testing.expect_value(t, time.to_unix_seconds(trial_began(kept, later)), 1_800_000_000)
	testing.expect(t, os.exists(file), "the file is written again")

	st: Store
	testing.expect(t, open(&st, licence.path_beside(kept, context.temp_allocator, FILE)) == nil)
	defer close(&st)
	start, found := get(&st, TRIAL, context.temp_allocator)
	testing.expect(t, found)
	testing.expect_value(t, start, "1800000000")
	testing.expect_value(t, trial_began("", now), licence.TRIAL_OVER)
}
