#+build linux
package btrfs

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

/*
measure says what the walk needs to know: off btrfs the kernel does not know the
ioctl, on btrfs without root it refuses it, and as root on btrfs a written and synced
file is charged what it wrote. Which of the three a run sees depends on where the
file lies and who runs it, so the test works that out and expects that one.
LEITA_BTRFS_SCRATCH names a btrfs directory to write in, as tools/btrfs-fixture
sets it, and the test then fails if it is not btrfs; the temp directory otherwise.
*/
@(test)
test_measure_reads_or_says_why :: proc(t: ^testing.T) {
	dir := os.get_env("LEITA_BTRFS_SCRATCH", context.temp_allocator)
	if dir == "" {
		temp, temp_err := os.temp_directory(context.temp_allocator)
		testing.expect(t, temp_err == nil, "no temp directory")
		dir = temp
	}
	path := fmt.tprintf("%s/leita_btrfs_measure_%d", dir, os.get_pid())
	defer os.remove(path)
	data := make([]u8, 256 * 1024, context.temp_allocator)
	for &b, i in data {
		b = u8(i * 7919 >> 3)
	}
	f, open_err := os.open(path, {.Write, .Create, .Trunc})
	testing.expect(t, open_err == nil, "could not create")
	_, write_err := os.write(f, data)
	testing.expect(t, write_err == nil, "could not write")
	// Synced, so the extent has been written when the tree is searched.
	testing.expect(t, os.sync(f) == nil, "could not sync")
	os.close(f)

	fs: linux.Stat_FS
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	testing.expect_value(t, linux.statfs(cdir, &fs), linux.Errno.NONE)
	want := Error.None
	if fs.type != .BTRFS_SUPER_MAGIC {
		testing.expectf(
			t,
			os.get_env("LEITA_BTRFS_SCRATCH", context.temp_allocator) == "",
			"LEITA_BTRFS_SCRATCH is on %v, not btrfs",
			fs.type,
		)
		want = .Not_Btrfs
	} else if linux.geteuid() != 0 {
		want = .Not_Permitted
	}

	u: Usage
	defer usage_destroy(&u)
	testing.expect_value(t, measure(path, &u), want)
	if want != .None {
		testing.expect_value(t, u.files, 0)
		return
	}
	testing.expect_value(t, u.files, 1)
	s := total(u)
	testing.expect_value(t, s.referenced, u64(len(data)))
	testing.expect(t, s.disk > 0 && s.disk <= u64(len(data)), "disk is at most what was written")
}
