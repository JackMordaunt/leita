#+build darwin
package scan

import "core:os"
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

	_, ok := stat_fs("/nonexistent/sonar")
	testing.expect(t, !ok, "a path that is not there has no filesystem")
}
