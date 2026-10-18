#+build linux
package walk

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

import "../btrfs"
import "../scan"

// Every fixture file refers to one compressed extent. The real parser and
// shared extent set decide which name pays, independent of enumeration order.
@(private = "file")
charge_update_extent :: proc(
	dir: linux.Fd,
	ino: u64,
	args: ^btrfs.Search_Args,
	extents: ^btrfs.Extents,
	owner: u64,
) -> (
	c: btrfs.Charge,
	err: btrfs.Error,
) {
	item: [53]u8
	item[20] = 1
	endian.put_u64(item[21:29], .Little, 1 << 20)
	endian.put_u64(item[29:37], .Little, 512)
	if btrfs.charge_shared(item[:], extents, owner, &c) != .None {
		return c, .Malformed
	}
	return c, .None
}

@(private = "file")
refuse_update_extent :: proc(
	dir: linux.Fd,
	ino: u64,
	args: ^btrfs.Search_Args,
	extents: ^btrfs.Extents,
	owner: u64,
) -> (
	btrfs.Charge,
	btrfs.Error,
) {
	return {}, .Not_Permitted
}

@(private = "file")
update_file_charge :: proc(tree: ^scan.Tree) -> (bytes: u64, files: int) {
	for i in 0 ..< scan.slots(tree) {
		n := scan.node(tree, i)
		flags := scan.node_flags(n)
		if .Used in flags && flags & {.Directory, .Reparse, .Extra_Name} == {} {
			bytes += n.disk
			files += 1
		}
	}
	return
}

// Reuse must not carry a first payer across a new extent set, nor mix old
// charges with st_blocks after privilege is lost. No btrfs mount or root needed.
@(test)
btrfs_updates_remeasure_one_basis :: proc(t: ^testing.T) {
	temp, temp_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_err == nil)
	root := fmt.tprintf("%s/leita_btrfs_update_basis", temp)
	os.remove_all(root)
	defer os.remove_all(root)
	for dir in ([]string{"kept", "changed"}) {
		testing.expect(t, os.make_directory_all(fmt.tprintf("%s/%s", root, dir)) == nil)
		testing.expect(
			t,
			os.write_entire_file(fmt.tprintf("%s/%s/file", root, dir), []byte{'x'}) == nil,
		)
	}
	search_stand_in = charge_update_extent
	defer search_stand_in = nil
	base: scan.Tree
	testing.expect_value(t, scan.tree_init(&base, 2), scan.Error.None)
	defer scan.tree_destroy(&base)
	testing.expect_value(t, read(root, &base, Config{workers = 2}), Error.None)
	before, n := update_file_charge(&base)
	testing.expect_value(t, before, 512)
	testing.expect_value(t, n, 2)

	// A new name sharing the same extent is found even with all Keep marks.
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/changed/new", root), []byte{'y'}) == nil,
	)
	for mark in ([]Mark{.Keep, .List, .Deep}) {
		marks := make(map[u32]Mark, context.temp_allocator)
		for i in 0 ..< scan.slots(&base) {
			if scan.name_of(&base, i) == "changed" {
				marks[i] = mark
			}
		}
		updated: scan.Tree
		testing.expect_value(t, scan.tree_init(&updated, 2), scan.Error.None)
		u := Update {
			base   = &base,
			marks  = marks,
			restat = 1,
		}
		testing.expect_value(t, update(root, &u, &updated, Config{workers = 2}), Error.None)
		charged, count := update_file_charge(&updated)
		testing.expect_value(t, charged, 512)
		testing.expect_value(t, count, 3)
		testing.expect(t, !scan.is_logical(&updated))
		scan.tree_destroy(&updated)
	}

	// Remove the actual first payer from the old tree. The surviving clone must
	// pay once, rather than retaining its old zero charge.
	for i in 0 ..< scan.slots(&base) {
		node := scan.node(&base, i)
		if .Directory not_in scan.node_flags(node) && node.disk == 512 {
			testing.expect(t, os.remove(scan.path(&base, i, context.temp_allocator)) == nil)
			break
		}
	}
	for refused in ([]bool{false, true}) {
		search_stand_in = refuse_update_extent if refused else charge_update_extent
		updated, full: scan.Tree
		testing.expect_value(t, scan.tree_init(&updated, 2), scan.Error.None)
		testing.expect_value(t, scan.tree_init(&full, 2), scan.Error.None)
		u := Update {
			base = &base,
		}
		testing.expect_value(t, update(root, &u, &updated, Config{workers = 2}), Error.None)
		testing.expect_value(t, read(root, &full, Config{workers = 2}), Error.None)
		got, count := update_file_charge(&updated)
		want, full_count := update_file_charge(&full)
		testing.expect_value(t, got, want)
		testing.expect_value(t, count, full_count)
		testing.expect_value(t, count, 2)
		testing.expect_value(t, scan.is_logical(&updated), refused)
		if refused {
			for i in 0 ..< scan.slots(&updated) {
				node := scan.node(&updated, i)
				if .Used not_in scan.node_flags(node) || .Directory in scan.node_flags(node) {
					continue
				}
				path := strings.clone_to_cstring(
					scan.path(&updated, i, context.temp_allocator),
					context.temp_allocator,
				)
				st: linux.Statx
				testing.expect_value(
					t,
					linux.statx(linux.AT_FDCWD, path, {}, {.BLOCKS}, &st),
					linux.Errno.NONE,
				)
				testing.expect_value(t, node.disk, st.blocks * 512)
				testing.expect(t, .Shared not_in scan.node_flags(node))
			}
		} else {
			testing.expect_value(t, got, 512)
			payers, shared := 0, 0
			for i in 0 ..< scan.slots(&updated) {
				node := scan.node(&updated, i)
				flags := scan.node_flags(node)
				if .Used not_in flags || .Directory in flags {
					continue
				}
				// The payer may be either survivor, but it must still exist and
				// must hold the whole extent; the other survivor holds zero.
				testing.expect(t, os.exists(scan.path(&updated, i, context.temp_allocator)))
				testing.expect(t, node.disk == 0 || node.disk == 512)
				if node.disk == 512 {payers += 1}
				if .Shared in flags {shared += 1}
			}
			testing.expect_value(t, payers, 1)
			testing.expect_value(t, shared, 1)
		}
		scan.tree_destroy(&full)
		scan.tree_destroy(&updated)
	}
}
