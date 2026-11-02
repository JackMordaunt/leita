#+build freebsd
package walk

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/posix"
import "core:testing"

import "../scan"

// /dev is devfs on a normal FreeBSD installation. This requires no mount
// privilege and exercises a followed link crossing the opened root's mount.
@(test)
freebsd_a_followed_link_stops_at_another_mount :: proc(t: ^testing.T) {
	fd := posix.open("/dev", {.DIRECTORY, .CLOEXEC})
	if fd < 0 {
		log.info("skipped: /dev could not be opened")
		return
	}
	defer posix.close(fd)
	other, other_ok := scan.mount_id_freebsd(fd)
	temp, temp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_err == nil)
	root := fmt.tprintf("%s/leita_freebsd_mount_link_%d", temp, os.get_pid())
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil)
	defer os.remove_all(root)
	a, err := anchor_prepare(root, true, context.allocator)
	testing.expect(t, err == nil && a.errno == .NONE)
	defer anchor_release(&a)
	if !other_ok || other == a.mount {
		log.info("skipped: /dev is not known to be a different mount")
		return
	}
	testing.expect(t, os.symlink("/dev", fmt.tprintf("%s/dev", root)) == nil)
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{follow = true}), Error.None)
	n, count := named(&tree, "dev")
	testing.expect_value(t, count, 1)
	if n != nil {
		testing.expect(t, .Mount in scan.node_flags(n), "the boundary was recorded")
	}
	unread, _ := scan.unread(&tree)
	testing.expect_value(t, unread, u64(0))
	testing.expect_value(t, tree.count, u32(2))
}

// Direct update callers also get a fresh walk: an unmarked baseline cannot
// retain old names or allocation while FreeBSD has no validated reuse source.
@(test)
freebsd_an_update_reads_every_directory_and_current_names :: proc(t: ^testing.T) {
	temp, temp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_err == nil)
	root := fmt.tprintf("%s/leita_freebsd_update_whole_%d", temp, os.get_pid())
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil)
	defer os.remove_all(root)
	sub := fmt.tprintf("%s/sub", root)
	testing.expect(t, os.make_directory(sub) == nil)
	old := fmt.tprintf("%s/old.bin", sub)
	testing.expect(t, os.write_entire_file(old, "before") == nil)
	base: scan.Tree
	testing.expect_value(t, scan.tree_init(&base, 1), scan.Error.None)
	defer scan.tree_destroy(&base)
	testing.expect_value(t, read(root, &base, Config{workers = 1}), Error.None)
	testing.expect(t, os.remove(old) == nil)
	fresh := fmt.tprintf("%s/fresh.bin", sub)
	testing.expect(
		t,
		os.write_entire_file(fresh, "after: a new name the baseline never held") == nil,
	)
	got, want: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 1), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, scan.tree_init(&want, 1), scan.Error.None)
	defer scan.tree_destroy(&want)
	listed := 0
	u := Update {
		base = &base,
	}
	cfg := Config {
		workers = 1,
		after_list = proc(path: string, data: rawptr) {(^int)(data)^ += 1},
		after_list_data = &listed,
	}
	testing.expect_value(t, update(root, &u, &got, cfg), Error.None)
	testing.expect(t, u.whole != "", "the full-read fallback explains itself")
	testing.expect_value(t, listed, 2)
	testing.expect_value(t, read(root, &want, Config{workers = 1}), Error.None)
	testing.expect_value(t, got.count, want.count)
	testing.expect_value(t, got.bytes_done, want.bytes_done)
	_, stale_names := named(&got, "old.bin")
	_, new_names := named(&got, "fresh.bin")
	testing.expect_value(t, stale_names, 0)
	testing.expect_value(t, new_names, 1)
}
