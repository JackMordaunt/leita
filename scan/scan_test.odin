package scan

import "core:os"
import "core:testing"

@(test)
test_choose_prefers_the_mft_when_it_can_be_read :: proc(t: ^testing.T) {
	ntfs := Target {
		fs     = .Ntfs,
		volume = `\\.\C:`,
	}
	testing.expect_value(t, choose(ntfs, readable = true).engine, Engine.Mft)

	// A volume that would not open leaves the reader unavailable rather than merely
	// slower, so the fallback runs and the caller is told what would pay.
	fallback := choose(ntfs, readable = false)
	testing.expect_value(t, fallback.engine, Engine.Walk)
	testing.expect(t, fallback.permission_would_help)
}

@(test)
test_choose_walks_a_directory_within_an_ntfs_volume_without_a_record :: proc(t: ^testing.T) {
	// resolve found the subtree but not its record (or never tried): the MFT reader
	// has nothing to root the tree at, so it is walked instead. Elevation is not
	// suggested because the volume already opened.
	sub := Target {
		fs     = .Ntfs,
		volume = `\\.\C:`,
		mount  = `C:\`,
		root   = `Users\ann\src`,
	}
	c := choose(sub, readable = true)
	testing.expect_value(t, c.engine, Engine.Walk)
	testing.expect(t, !c.permission_would_help)
	sub.root = ""
	testing.expect_value(t, choose(sub, readable = true).engine, Engine.Mft)
}

@(test)
test_choose_sizes_a_directory_with_a_record_before_the_mft :: proc(t: ^testing.T) {
	// resolve found root's file reference number, so the MFT reader could root the
	// tree at it, but it reads the whole volume's table to do so: what the subtree
	// holds decides which reader is faster.
	sub := Target {
		fs     = .Ntfs,
		volume = `\\.\C:`,
		mount  = `C:\`,
		root   = `Users\ann\src`,
		record = 123,
	}
	Case :: struct {
		name: string,
		size: Size,
		want: Choice,
	}
	cases := []Case {
		{"nothing known: walk, probing", {}, {engine = .Walk, probe = true}},
		{"a probe that finished walks", {probe = .Within}, {engine = .Walk}},
		{"a probe past its budget reads the MFT", {probe = .Over}, {engine = .Mft}},
		{"a small prior walks", {prior = 10}, {engine = .Walk}},
		{"a prior at the most walks", {prior = WALK_MOST}, {engine = .Walk}},
		{"a prior past the most reads the MFT", {prior = WALK_MOST + 1}, {engine = .Mft}},
		{"an empty prior walks", {prior = 0}, {engine = .Walk}},
		// The probe measured the subtree now; the prior is the last time it was kept.
		{"a probe outranks a large prior", {prior = 10 * WALK_MOST, probe = .Within}, {engine = .Walk}},
		{"a probe outranks a small prior", {prior = 1, probe = .Over}, {engine = .Mft}},
	}
	for c in cases {
		testing.expectf(t, choose(sub, true, c.size) == c.want, "%s: %v, want %v", c.name, choose(sub, true, c.size), c.want)
	}

	// The whole volume is the MFT's own cost: it is read from the MFT whatever is
	// known of its size, and never probed.
	whole := sub
	whole.root, whole.record = "", nil
	for c in cases {
		testing.expectf(t, choose(whole, true, c.size) == Choice{engine = .Mft}, "whole volume, %s", c.name)
	}

	// The volume itself did not open: elevation would help, a record and a size
	// notwithstanding.
	for c in cases {
		testing.expectf(
			t,
			choose(sub, false, c.size) == Choice{engine = .Walk, permission_would_help = true},
			"not readable, %s",
			c.name,
		)
	}
}

@(test)
test_choose_walks_what_it_cannot_read_directly :: proc(t: ^testing.T) {
	// Elevation buys nothing on these, so it must not be suggested. A mount point is
	// what makes a target walkable, and `resolve` sets one for everything that has a
	// directory tree behind it.
	for fs in ([]Filesystem{.Refs, .Exfat, .Fat32, .Network, .Other}) {
		c := choose(Target{fs = fs, volume = `\\.\D:`, mount = `D:\`}, readable = true)
		testing.expect_value(t, c.engine, Engine.Walk)
		testing.expect(t, !c.permission_would_help)
	}
}

@(test)
test_choose_reads_an_image_without_elevation :: proc(t: ^testing.T) {
	// An image is a file like any other: opening it is the whole of the permission
	// needed, so asking for more would send a reader that cannot work.
	image := Target {
		fs     = .Ntfs,
		volume = "disk.img",
		image  = true,
	}
	testing.expect_value(t, choose(image, readable = true).engine, Engine.Mft)
}

@(test)
test_choose_gives_up_on_a_volume_it_cannot_name :: proc(t: ^testing.T) {
	// A raw device or an image whose filesystem went unrecognised has no tree to
	// walk, so offering the walker would report an empty volume as an answer.
	for v in ([]Target{{volume = "/dev/sda1"}, {volume = "disk.img", image = true}}) {
		testing.expect_value(t, choose(v, readable = true).engine, Engine.None)
	}
}

@(test)
test_choose_gives_up_on_a_target_with_no_volume :: proc(t: ^testing.T) {
	testing.expect_value(t, choose(Target{}, readable = true).engine, Engine.None)
}

@(test)
test_resolve_finds_the_volume_behind_a_path :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		return
	}
	// The system drive is the one target every Windows machine has, and reading its
	// name needs no privilege.
	root, _, err := resolve("C:")
	testing.expect_value(t, err, Error.None)
	defer target_destroy(&root)
	testing.expect_value(t, root.mount, `C:\`)
	testing.expect_value(t, root.volume, `\\.\C:`)
	testing.expect_value(t, root.root, "")

	// A path below the mount point keeps the same volume and records the subtree.
	sub, _, sub_err := resolve(`C:\Windows`)
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
	_, _, err := resolve(`Q:\no\such\path`)
	testing.expect_value(t, err, Error.Target_Not_Found)
}

@(test)
the_space_of_a_mounted_directory_is_its_filesystems :: proc(t: ^testing.T) {
	dir, err := os.temp_directory(context.temp_allocator)
	testing.expect(t, err == nil)
	total, free, ok := space(dir)
	testing.expect(t, ok, "the platform answered")
	testing.expect(t, total > 0, "a filesystem has a size")
	testing.expect(t, free <= total, "no more is free than there is")

	_, _, missing := space("/nonexistent/leita")
	testing.expect(t, !missing, "a path that is not there has no filesystem")
}
