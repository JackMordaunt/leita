package sonar_history

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

// A lock held turns away a second taker until it is let go.
@(test)
a_lock_held_turns_away_another :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "sonar-history-lock-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	db, _ := filepath.join({dir, "history.db"}, context.temp_allocator)
	path := lock_path(db, "/srv/data", context.temp_allocator)
	testing.expect(
		t,
		path != lock_path(db, "/srv", context.temp_allocator),
		"each place has its own",
	)

	first, taken := lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	_, again := lock(path)
	testing.expect_value(t, again, Lock_Result.Held)
	unlock(&first)
	testing.expect(t, free_soon(path), "a lock let go can be taken again")
}

/*
free_soon says whether the lock at path can be taken within a second, and lets it
go again. A lock lasts as long as any copy of its open file: a process another
test forks while the lock is held keeps a copy until it runs its program, so the
lock goes a moment after unlock, not at once.
*/
@(private)
free_soon :: proc(path: string) -> bool {
	for _ in 0 ..< 100 {
		l, result := lock(path)
		if result == .Taken {
			unlock(&l)
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}
