package scan

import "core:testing"

@(test)
test_choose_prefers_the_mft_when_it_can_be_read :: proc(t: ^testing.T) {
	ntfs := Target{fs = .Ntfs, volume = `\\.\C:`}
	testing.expect_value(t, choose(ntfs, elevated = true).engine, Engine.Mft)

	// Without the privilege the reader is unavailable rather than merely slower, so
	// the fallback runs and the caller is told relaunching would pay.
	fallback := choose(ntfs, elevated = false)
	testing.expect_value(t, fallback.engine, Engine.Walk)
	testing.expect(t, fallback.elevation_would_help)
}

@(test)
test_choose_walks_what_it_cannot_read_directly :: proc(t: ^testing.T) {
	// Elevation buys nothing on these, so it must not be suggested. A mount point is
	// what makes a target walkable, and `resolve` sets one for everything that has a
	// directory tree behind it.
	for fs in ([]Filesystem{.Refs, .Exfat, .Fat32, .Network, .Other}) {
		c := choose(Target{fs = fs, volume = `\\.\D:`, mount = `D:\`}, elevated = true)
		testing.expect_value(t, c.engine, Engine.Walk)
		testing.expect(t, !c.elevation_would_help)
	}
}

@(test)
test_choose_reads_an_image_without_elevation :: proc(t: ^testing.T) {
	// An image is a file like any other: opening it is the whole of the permission
	// needed, so asking for more would send a reader that cannot work.
	image := Target{fs = .Ntfs, volume = "disk.img", image = true}
	testing.expect_value(t, choose(image, elevated = false).engine, Engine.Mft)
}

@(test)
test_choose_gives_up_on_a_volume_it_cannot_name :: proc(t: ^testing.T) {
	// A raw device or an image whose filesystem went unrecognised has no tree to
	// walk, so offering the walker would report an empty volume as an answer.
	for v in ([]Target{{volume = "/dev/sda1"}, {volume = "disk.img", image = true}}) {
		testing.expect_value(t, choose(v, elevated = true).engine, Engine.None)
	}
}

@(test)
test_choose_gives_up_on_a_target_with_no_volume :: proc(t: ^testing.T) {
	testing.expect_value(t, choose(Target{}, elevated = true).engine, Engine.None)
}

@(test)
test_resolve_finds_the_volume_behind_a_path :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		return
	}
	// The system drive is the one target every Windows machine has, and reading its
	// name needs no privilege.
	root, err := resolve("C:")
	testing.expect_value(t, err, Error.None)
	defer target_destroy(&root)
	testing.expect_value(t, root.mount, `C:\`)
	testing.expect_value(t, root.volume, `\\.\C:`)
	testing.expect_value(t, root.root, "")

	// A path below the mount point keeps the same volume and records the subtree.
	sub, sub_err := resolve(`C:\Windows`)
	testing.expect_value(t, sub_err, Error.None)
	defer target_destroy(&sub)
	testing.expect_value(t, sub.volume, root.volume)
	testing.expect_value(t, sub.root, `\Windows`)
	testing.expect_value(t, sub.fs, root.fs)
}

@(test)
test_resolve_rejects_what_is_not_there :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		return
	}
	_, err := resolve(`Q:\no\such\path`)
	testing.expect_value(t, err, Error.Target_Not_Found)
}
