package leita_monitor

import "core:fmt"
import jm_path "jm:path"
import "core:os"
import "core:testing"

@(test)
a_place_is_due_once_its_period_is_nearly_up :: proc(t: ^testing.T) {
	hour :: 60 * 60
	testing.expect(t, due(.Weekly, 0, 1000), "never scanned is due")
	testing.expect(t, due(.Hourly, 10 * hour, 11 * hour - 4 * 60), "a run five minutes early")
	testing.expect(t, !due(.Hourly, 10 * hour, 10 * hour + 30 * 60))
	testing.expect(t, !due(.Daily, 0 + 1, 20 * hour))
	testing.expect(t, due(.Daily, 1, 24 * hour - 5 * 60))
	testing.expect(t, !due(.Weekly, 1, 6 * 24 * hour))
	testing.expect(t, due(.Weekly, 1, 7 * 24 * hour))
}

@(test)
a_run_holds_a_lock_another_run_stands_aside_for :: proc(t: ^testing.T) {
	dir, err := jm_path.make_directory_temp("", "leita-lock-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/%s", dir, LOCK_FILE)

	l, taken := lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	unlock(&l)
	l, taken = lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	// A second open of the file is refused while the first holds it.
	_, again := lock(path)
	testing.expect_value(t, again, Lock_Result.Held)
	unlock(&l)
	l, taken = lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	unlock(&l)
	_, taken = lock(fmt.tprintf("%s/missing/%s", dir, LOCK_FILE))
	testing.expect_value(t, taken, Lock_Result.Failed)
}
