#+build linux
package scan

import "core:os"
import "core:path/filepath"
import "core:strings"

/*
What stores `device`, as the block layer reports it in sysfs.

A whole disk has `queue/rotational` under its sysfs entry and a partition does not,
so a partition is answered by the disk above it, as vdb1 was by vdb in a Docker VM. A
source that is not a block device, such as a network share or tmpfs, has no entry and
is Unknown.
*/
@(private)
media_of :: proc(device: string) -> Media {
	// sysfs names a device by its node, so a link to one, such as a /dev/mapper name,
	// is followed to it. A source that is no file at all reads as no link and finds
	// no entry below.
	node := device
	if target, err := os.read_link(device, context.temp_allocator); err == nil {
		node = target
	}
	block := strings.concatenate(
		{"/sys/class/block/", filepath.base(node)},
		context.temp_allocator,
	)
	for queue in ([]string{"/queue/rotational", "/../queue/rotational"}) {
		path := strings.concatenate({block, queue}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			continue
		}
		switch strings.trim_space(string(data)) {
		case "0":
			return .Solid
		case "1":
			return .Rotational
		}
		return .Unknown
	}
	return .Unknown
}
