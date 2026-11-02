#+build freebsd
package scan

import "core:mem"
import "core:testing"

@(test)
freebsd_mount_queries_return_owned_names_and_explicit_errors :: proc(t: ^testing.T) {
	_, invalid := mount_id_freebsd(-1)
	testing.expect(t, !invalid, "an invalid descriptor has no mount identity")
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	device, point, _, ok := mounted_at_freebsd("/", allocator)
	testing.expect(t, ok, "the root has a mount")
	testing.expect(t, len(device) > 0 && point == "/", "the mount names the root and its source")
	testing.expect_value(t, len(track.allocation_map), 2)
	delete(device, allocator)
	delete(point, allocator)
	testing.expect_value(t, len(track.allocation_map), 0)
	_, _, _, absent := mounted_at_freebsd("/nonexistent/leita/freebsd")
	testing.expect(t, !absent, "a missing path has no mount")
	points, listed := mounts_freebsd(allocator)
	testing.expect(t, listed, "the native mount table can be enumerated")
	root_seen := false
	for p in points {
		testing.expect(t, len(p) > 0 && p[0] == '/', "mount paths are absolute")
		root_seen ||= p == "/"
		delete(p, allocator)
	}
	delete(points, allocator)
	testing.expect(t, root_seen, "the snapshot includes the root mount")
	testing.expect_value(t, len(track.allocation_map), 0)
}
