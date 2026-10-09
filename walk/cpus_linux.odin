#+build linux
package walk

import "core:os"
import "core:strings"

/*
The CPUs this process may use: those its affinity allows, and no more than the
tightest CPU quota on its cgroup or any cgroup above it.

A container held to one and a half CPUs on an eight-core host is still allowed all
eight cores: under `docker run --cpus=1.5` the affinity counted 8 while cpu.max read
"150000 100000". Counting the cores alone would start workers that spend the share
fighting each other. Only cgroup v2 is read, whose line in /proc/self/cgroup is
"0::<path>" (cgroups(7)); in that container the path was "/", its own group.
*/
@(private)
cpus :: proc() -> int {
	count := max(os.get_processor_core_count(), 1)
	membership, err := os.read_entire_file("/proc/self/cgroup", context.temp_allocator)
	if err != nil {
		return count
	}
	for line in strings.split_lines(string(membership), context.temp_allocator) {
		// The v2 line has hierarchy 0 and no controllers named (cgroups(7)).
		if !strings.has_prefix(line, "0::") {
			continue
		}
		group := line[len("0::"):]
		for {
			path := strings.concatenate(
				{"/sys/fs/cgroup", group, "/cpu.max"},
				context.temp_allocator,
			)
			if text, read_err := os.read_entire_file(path, context.temp_allocator);
			   read_err == nil {
				if limit, limited := cpu_max_limit(string(text)); limited {
					count = min(count, limit)
				}
			}
			if group == "/" || group == "" {
				break
			}
			cut := strings.last_index_byte(group, '/')
			group = group[:max(cut, 1)]
		}
	}
	return count
}
