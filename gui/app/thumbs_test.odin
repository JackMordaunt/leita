package leita_app

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

// prune_fixture makes a fresh folder of thumbnail-shaped files under a scratch
// directory, each written then set to age days old, and returns the folder.
@(private = "file")
prune_fixture :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	folder := fmt.tprintf("%s/leita_gui_thumbs_%s_%d", dir, name, os.get_pid())
	os.remove_all(folder)
	testing.expect(t, os.make_directory(folder) == nil, "could not make the folder")

	write :: proc(t: ^testing.T, folder, name: string, bytes: int, age: time.Duration) {
		path := fmt.tprintf("%s/%s", folder, name)
		body := make([]byte, bytes, context.temp_allocator)
		testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
		used := time.time_add(time.now(), -age)
		testing.expectf(t, os.change_times(path, used, used) == nil, "could not age %s", path)
	}
	// Past THUMB_MAX_AGE: dropped whatever the size bound says.
	write(t, folder, "ancient.png", 50 * 1024, 40 * 24 * time.Hour)
	// Within max_age, but the older of the two once ancient.png is gone, so the
	// size bound drops it first.
	write(t, folder, "stale_big.png", 220 * 1024, 20 * 24 * time.Hour)
	write(t, folder, "fresh_big.png", 220 * 1024, 5 * 24 * time.Hour)
	// Small and just used: nothing should ever have a reason to drop it.
	write(t, folder, "small.png", 4 * 1024, time.Minute)
	return folder
}

@(test)
pruning_drops_stale_and_least_recently_used_thumbnails :: proc(t: ^testing.T) {
	folder := prune_fixture(t, "basic")
	defer os.remove_all(folder)

	max_bytes := i64(300 * 1024)
	thumbs_prune(folder, 30 * 24 * time.Hour, max_bytes)

	testing.expect(
		t,
		!os.exists(fmt.tprintf("%s/ancient.png", folder)),
		"the 40 day old file went",
	)
	testing.expect(
		t,
		!os.exists(fmt.tprintf("%s/stale_big.png", folder)),
		"the older large file went, over the bound",
	)
	testing.expect(
		t,
		os.exists(fmt.tprintf("%s/fresh_big.png", folder)),
		"the newer large file stayed",
	)
	testing.expect(t, os.exists(fmt.tprintf("%s/small.png", folder)), "the small file stayed")

	dir, open_err := os.open(folder)
	testing.expect(t, open_err == nil)
	defer os.close(dir)
	entries, read_err := os.read_dir(dir, -1, context.temp_allocator)
	testing.expect(t, read_err == nil)
	total: i64
	for e in entries {
		total += e.size
	}
	testing.expectf(t, total <= max_bytes, "the folder holds %d bytes, over %d", total, max_bytes)
}

@(test)
pruning_under_a_wide_size_bound_only_drops_stale_files :: proc(t: ^testing.T) {
	folder := prune_fixture(t, "untouched")
	defer os.remove_all(folder)

	// A size bound wide enough that nothing but age matters.
	thumbs_prune(folder, 30 * 24 * time.Hour, i64(1024 * 1024))

	testing.expect(t, !os.exists(fmt.tprintf("%s/ancient.png", folder)), "still dropped by age")
	for name in ([]string{"stale_big.png", "fresh_big.png", "small.png"}) {
		testing.expectf(
			t,
			os.exists(fmt.tprintf("%s/%s", folder, name)),
			"%s stayed under a wide size bound",
			name,
		)
	}
}

/*
thumb_prune_is_unmoved is thumbs_prune's guard against the race a hit and a
concurrent prune make possible: thumb_make can touch a file's modification
time between the walk that found it stale and the remove that follows. A test
driving that race through thumbs_prune itself would need a seam paused between
its read_dir and its remove, just to let the test touch the file in the gap -
more machinery than the guard is worth testing twice over. This exercises the
decision directly instead, cheaper and just as honest about what the guard
does: given a snapshot's modification time, a file touched since does not
match it.
*/
@(test)
a_file_touched_since_the_snapshot_is_no_longer_unmoved :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	path := fmt.tprintf("%s/leita_gui_thumbs_race_%d.png", dir, os.get_pid())
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, []byte{1, 2, 3, 4}) == nil)
	old := time.time_add(time.now(), -(40 * 24 * time.Hour))
	testing.expect(t, os.change_times(path, old, old) == nil, "could not age the file")
	snapshot, stat_err := os.stat(path, context.temp_allocator)
	testing.expect(t, stat_err == nil)

	unmoved, size := thumb_prune_is_unmoved(path, snapshot.modification_time)
	testing.expect(t, unmoved, "untouched since the walk, so still a match")
	testing.expect_value(t, size, i64(4))

	// A hit lands: thumb_make's touch, between the walk and the remove it
	// decided on.
	now := time.now()
	testing.expect(t, os.change_times(path, now, now) == nil, "could not touch the file")
	unmoved, _ = thumb_prune_is_unmoved(path, snapshot.modification_time)
	testing.expect(t, !unmoved, "touched since the snapshot, so backed off rather than removed")

	testing.expect(t, os.remove(path) == nil)
	unmoved, size = thumb_prune_is_unmoved(path, snapshot.modification_time)
	testing.expect(t, !unmoved, "gone already is not a match either")
	testing.expect_value(t, size, i64(0))
}
