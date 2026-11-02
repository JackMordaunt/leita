#+build freebsd
package survey

import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// ZFS can keep st_blocks at its pre-TXG allocation after close and fsync. These
// physical-size fixtures need committed allocation; production scans never sync.
@(private)
fixture_sync_fd :: proc(t: ^testing.T, fd: int, length: int) {
	posix.sync()
	start := time.tick_now()
	for {
		st: posix.stat_t
		if posix.fstat(posix.FD(fd), &st) == .OK &&
		   i64(st.st_size) == i64(length) && i64(st.st_blocks) >= 0 &&
		   u64(st.st_blocks) * 512 >= u64(length) {
			return
		}
		if time.tick_since(start) >= 10 * time.Second {
			testing.expectf(t, false, "fixture allocation did not settle in 10s: length %d, stat size %d, blocks %d", length, st.st_size, st.st_blocks)
			return
		}
		time.sleep(10 * time.Millisecond)
	}
}

@(private)
fixture_sync :: proc(t: ^testing.T, path: string, length: int) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC})
	if !testing.expect(t, fd >= 0, "cannot open the physical-size fixture") {
		return
	}
	defer posix.close(fd)
	fixture_sync_fd(t, int(fd), length)
}
