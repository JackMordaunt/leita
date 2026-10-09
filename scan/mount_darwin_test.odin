#+build darwin
package scan

import "core:os"
import "core:strings"
import "core:testing"

/*
A directory resolves to the mount statfs names for it and keeps the path asked for.
The Data volume's own mount point is a mount like any other; a home directory is
reached from the system volume by a firmlink into /System/Volumes/Data, so it does
not lie under that mount point and takes the root as its mount instead.
*/
@(test)
a_directory_resolves_to_its_mount_and_keeps_its_path :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.temp_allocator)
	cases := []struct {
		path, mount: string,
	}{{"/System/Volumes/Data", "/System/Volumes/Data"}, {home, "/"}, {"/", "/"}}
	for c in cases {
		info, stat_err := os.stat(c.path, context.temp_allocator)
		if !testing.expectf(t, stat_err == nil, "%s is not there", c.path) {
			continue
		}
		target, choice, err := resolve(c.path, context.temp_allocator)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, target.mount, c.mount)
		testing.expectf(t, target.volume != "", "%s has a device", c.path)
		testing.expect_value(t, target.fs, Filesystem.Other)
		testing.expect_value(t, choice.engine, Engine.Walk)
		testing.expect_value(t, location(target, context.temp_allocator), info.fullpath)
	}

	_, ok := stat_fs("/nonexistent/estoile")
	testing.expect(t, !ok, "a path that is not there has no filesystem")
}

/*
The medium resolved for a volume is the one diskutil reports for its device.

diskutil answers for the device without this code, so the two agreeing on / and the
home directory, both APFS volumes inside a container, says the search climbed from
the volume to the drive. A name no device has, and no name at all, are Unknown.
*/
@(test)
a_volume_has_the_medium_diskutil_reports :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.temp_allocator)
	for path in ([]string{"/", home}) {
		target, _, err := resolve(path, context.temp_allocator)
		if !testing.expect_value(t, err, Error.None) {
			continue
		}
		state, stdout, _, exec_err := os.process_exec(
			{command = {"diskutil", "info", target.volume}},
			context.temp_allocator,
		)
		if !testing.expectf(t, exec_err == nil && state.exit_code == 0, "diskutil failed") {
			continue
		}
		want := Media.Unknown
		for line in strings.split_lines(string(stdout), context.temp_allocator) {
			field := strings.trim_space(line)
			if strings.has_prefix(field, "Solid State:") {
				answer := strings.trim_space(field[len("Solid State:"):])
				want = .Solid if answer == "Yes" else .Rotational if answer == "No" else .Unknown
			}
		}
		testing.expectf(t, target.media == want, "%s: %v, diskutil %v", path, target.media, want)
	}
	testing.expect_value(t, media_of("/dev/disk-estoile-none"), Media.Unknown)
	testing.expect_value(t, media_of(""), Media.Unknown)
}
