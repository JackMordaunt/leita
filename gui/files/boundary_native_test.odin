#+build windows, darwin
package leita_files

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
Link_Kind :: enum {
	Symlink,
	Junction,
}

@(private = "file")
KINDS :: []Link_Kind{.Symlink, .Junction} when ODIN_OS == .Windows else []Link_Kind{.Symlink}

@(private = "file")
link_dir :: proc(kind: Link_Kind, target, path: string) -> bool {
	switch kind {
	case .Symlink:
		return symlink_directory(target, path)
	case .Junction:
		return junction_directory(target, path)
	}
	return false
}

// A private directory under the temp dir, with every link in its own path resolved,
// since a delete refuses one there.
@(private = "file")
native_root :: proc(t: ^testing.T, name: string) -> string {
	root := strings.concatenate(
		{temp_root(), SEPARATOR, fmt.tprintf("leita_files_native_%s_%d", name, os.get_pid())},
		context.temp_allocator,
	)
	os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	return root
}

@(private = "file")
at :: proc(parts: ..string) -> string {
	return strings.join(parts, SEPARATOR, context.temp_allocator)
}

@(private = "file")
put :: proc(t: ^testing.T, path, text: string) {
	testing.expectf(t, os.write_entire_file(path, text) == nil, "could not write %s", path)
}

/*
real/tree and decoy/tree, and via a link to decoy: via/tree reads as a path to one
tree while the tree it reaches is decoy's.
*/
@(private = "file")
decoy_fixture :: proc(t: ^testing.T, name: string, kind: Link_Kind) -> (root: string, linked: bool) {
	root = native_root(t, fmt.tprintf("%s_%v", name, kind))
	testing.expect(t, os.make_directory_all(at(root, "real", "tree")) == nil)
	testing.expect(t, os.make_directory_all(at(root, "decoy", "tree")) == nil)
	put(t, at(root, "real", "tree", "secret"), "real")
	put(t, at(root, "decoy", "tree", "keep"), "decoy")
	put(t, at(root, "decoy", "item"), "decoy")
	linked = link_dir(kind, at(root, "decoy"), at(root, "via"))
	testing.expectf(t, linked, "%v: could not link via", kind)
	return
}

@(test)
native_a_delete_through_a_linked_ancestor_leaves_the_target :: proc(t: ^testing.T) {
	for kind in KINDS {
		root, linked := decoy_fixture(t, "delete_ancestor", kind)
		defer os.remove_all(root)

		if !linked {
			continue
		}
		failed, _, err := delete_tree(at(root, "via", "tree"))
		testing.expectf(t, err == .Not_Directory && failed == 0, "%v: %v, %d left", kind, err, failed)
		kept := os.exists(at(root, "decoy", "tree", "keep"))
		testing.expectf(t, kept, "%v: delete through via emptied decoy/tree", kind)
	}
}

@(test)
native_a_rename_through_a_linked_ancestor_leaves_the_target :: proc(t: ^testing.T) {
	for kind in KINDS {
		root, linked := decoy_fixture(t, "rename_ancestor", kind)
		defer os.remove_all(root)

		if !linked {
			continue
		}
		_, err := rename(at(root, "via", "item"), "moved", context.temp_allocator)
		testing.expectf(t, err == .Not_Directory, "%v: %v", kind, err)
		kept := os.exists(at(root, "decoy", "item"))
		testing.expectf(t, kept, "%v: rename through via renamed decoy/item", kind)
	}
}

// A rename in a folder reached without a link still goes, by either separator.
@(test)
native_a_rename_without_a_link_goes :: proc(t: ^testing.T) {
	root := native_root(t, "rename_plain")
	defer os.remove_all(root)

	put(t, at(root, "item"), "x")
	to, err := rename(strings.concatenate({root, "/item"}, context.temp_allocator), "moved", context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, to != "" && os.exists(at(root, "moved")), "renamed on disk")
	testing.expect(t, !os.exists(at(root, "item")), "the old name is gone")
	put(t, at(root, "taken"), "y")
	_, taken := rename(at(root, "moved"), "taken", context.temp_allocator)
	testing.expect_value(t, taken, Error.Exists)
}

@(test)
native_a_trash_through_a_linked_ancestor_leaves_the_target :: proc(t: ^testing.T) {
	for kind in KINDS {
		root, linked := decoy_fixture(t, "trash_ancestor", kind)
		defer os.remove_all(root)

		if !linked {
			continue
		}
		err := trash(at(root, "via", "item"))
		testing.expectf(t, err == .Not_Directory, "%v: %v", kind, err)
		kept := os.exists(at(root, "decoy", "item"))
		testing.expectf(t, kept, "%v: trash through via moved decoy/item", kind)
	}
}

// A link given to trash itself is what goes, not what it points at. Not on Windows,
// where it would leave the link in the Recycle Bin that
// the_recycle_bin_is_sized_per_volume_and_empty_refuses_a_non_bin expects empty.
@(test)
native_trashing_a_link_leaves_its_target :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	for kind in KINDS {
		root, linked := decoy_fixture(t, "trash_link", kind)
		defer os.remove_all(root)

		if !linked {
			continue
		}
		err := trash(at(root, "via"))
		kept := os.exists(at(root, "decoy", "item")) && os.exists(at(root, "decoy", "tree", "keep"))
		gone := !os.exists(at(root, "via"))
		testing.expectf(t, err == .None && gone, "%v: %v, link gone %v", kind, err, gone)
		testing.expectf(t, kept, "%v: trashing the link took what it points at", kind)
	}
}

// Where a delete replaces a directory with a link as it is about to enter it.
@(private = "file")
Swap :: struct {
	name:   string,
	dir:    string,
	target: string,
	kind:   Link_Kind,
	done:   bool,
	linked: bool,
}

// Per thread, since tests run in parallel: the hook is installed for good, and fires
// only for the thread that set its swap.
@(private = "file", thread_local)
swap: Swap

@(private = "file")
swap_on_enter :: proc(name: string) {
	if swap.done || name != swap.name {
		return
	}
	swap.done = true
	if os.rename(swap.dir, fmt.tprintf("%s.real", swap.dir)) != nil {
		return
	}
	swap.linked = link_dir(swap.kind, swap.target, swap.dir)
}

/*
A directory inside the tree, looked at as a directory and replaced with a link to
one outside before the delete enters it, must not have what the link points at
deleted.
*/
@(test)
native_a_directory_replaced_during_a_delete_leaves_the_target :: proc(t: ^testing.T) {
	for kind in KINDS {
		root := native_root(t, fmt.tprintf("delete_swap_%v", kind))
		defer os.remove_all(root)

		sub := at(root, "tree", "swapped")
		testing.expect(t, os.make_directory_all(sub) == nil)
		testing.expect(t, os.make_directory_all(at(root, "decoy")) == nil)
		put(t, at(sub, "inside"), "inside")
		put(t, at(root, "decoy", "keep"), "decoy")

		swap = Swap {
			name   = "swapped",
			dir    = sub,
			target = at(root, "decoy"),
			kind   = kind,
		}
		before_enter = swap_on_enter
		failed, _, err := delete_tree(at(root, "tree"))
		kept := os.exists(at(root, "decoy", "keep"))
		testing.expectf(t, swap.linked, "%v: the directory was not replaced", kind)
		testing.expectf(t, kept, "%v: the delete followed the link into decoy", kind)
		// The link is left, and the tree holding it.
		testing.expectf(t, err == .Partly && failed == 1, "%v: %v, %d left", kind, err, failed)
	}
}

/*
Permission recovery: a directory its owner cannot list, and on Windows a read-only
file, are still deleted, since the delete gives the owner back what it needs.
*/
@(test)
native_a_tree_its_owner_cannot_list_is_deleted :: proc(t: ^testing.T) {
	root := native_root(t, "locked")
	defer os.remove_all(root)

	locked := at(root, "tree", "locked")
	testing.expect(t, os.make_directory_all(locked) == nil)
	put(t, at(locked, "file"), "x")
	put(t, at(root, "tree", "read_only"), "x")
	testing.expect(t, set_read_only(at(root, "tree", "read_only"), true))
	when ODIN_OS == .Windows {
		testing.expect(t, set_read_only(locked, true) && is_read_only(locked), "locked is not read-only")
	} else {
		testing.expect(t, os.change_mode(locked, {}) == nil)
	}
	failed, _, err := delete_tree(at(root, "tree"))
	gone := !os.exists(at(root, "tree"))
	if !gone {
		_ = os.change_mode(locked, os.Permissions_All)
		_ = set_read_only(locked, false)
		_ = set_read_only(at(root, "tree", "read_only"), false)
	}
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, failed, 0)
	testing.expect(t, gone, "the tree is still there")
}

/*
Permission recovery against a swap: a directory its owner cannot list is replaced
with a link to one outside after it was looked at. The recovery must not change
the link target's mode nor delete what it holds.
*/
@(test)
native_permission_recovery_does_not_follow_a_swapped_link :: proc(t: ^testing.T) {
	for kind in KINDS {
		root := native_root(t, fmt.tprintf("locked_swap_%v", kind))
		defer os.remove_all(root)

		sub := at(root, "tree", "swapped")
		testing.expect(t, os.make_directory_all(sub) == nil)
		testing.expect(t, os.make_directory_all(at(root, "decoy")) == nil)
		put(t, at(root, "decoy", "keep"), "decoy")
		testing.expect(t, set_read_only(at(root, "decoy"), true), "could not make decoy read-only")
		testing.expect(t, is_read_only(at(root, "decoy")), "decoy is not read-only")
		when ODIN_OS == .Windows {
			testing.expect(t, set_read_only(sub, true) && is_read_only(sub), "sub is not read-only")
		} else {
			testing.expect(t, os.change_mode(sub, {}) == nil)
		}

		swap = Swap {
			name   = "swapped",
			dir    = sub,
			target = at(root, "decoy"),
			kind   = kind,
		}
		before_enter = swap_on_enter
		failed, _, err := delete_tree(at(root, "tree"))
		kept := os.exists(at(root, "decoy", "keep"))
		still := is_read_only(at(root, "decoy"))
		_ = set_read_only(at(root, "decoy"), false)
		_ = os.change_mode(fmt.tprintf("%s.real", sub), os.Permissions_All)
		_ = set_read_only(fmt.tprintf("%s.real", sub), false)
		testing.expectf(t, swap.linked, "%v: the directory was not replaced", kind)
		testing.expectf(t, kept, "%v: the delete followed the link into decoy", kind)
		testing.expectf(t, still, "%v: the decoy lost its read-only mode", kind)
		testing.expectf(t, err == .Partly && failed == 1, "%v: %v, %d left", kind, err, failed)
	}
}

// Where a trash replaces a folder above the entry with a link after the folder is
// checked and before the entry is moved.
@(private = "file")
Trash_Swap :: struct {
	dir:     string,
	target:  string,
	kind:    Link_Kind,
	fired:   bool,
	linked:  bool,
	refused: bool,
	lock:    rawptr,
}

@(private = "file", thread_local)
trash_swap: Trash_Swap

@(private = "file")
swap_on_trash :: proc(path: string) {
	s := &trash_swap
	if s.fired || s.dir == "" {
		return
	}
	s.fired = true
	if os.rename(s.dir, fmt.tprintf("%s.real", s.dir)) != nil {
		// The trash holds the folder still. Lock the entry, so the move that follows
		// fails and nothing reaches the user's Recycle Bin.
		s.refused = true
		s.lock = lock_file(path)
		return
	}
	s.linked = link_dir(s.kind, s.target, s.dir)
}

/*
A folder above the entry, its own or one higher, replaced with a link to a decoy of
the same shape after trash checked it, must not have the decoy's entry moved. On
macOS the swap goes ahead and the real entry is what is trashed; on Windows the swap
itself is refused.

	root/top/mid/item      what is trashed
	root/decoy/mid/item    what a link at top or at mid would reach
*/
@(test)
native_a_folder_swapped_before_a_trash_leaves_the_target :: proc(t: ^testing.T) {
	for kind in KINDS {
		for swapped in ([]string{"top", "mid"}) {
			root := native_root(t, fmt.tprintf("trash_swap_%v_%s", kind, swapped))
			defer os.remove_all(root)

			testing.expect(t, os.make_directory_all(at(root, "top", "mid")) == nil)
			testing.expect(t, os.make_directory_all(at(root, "decoy", "mid")) == nil)
			item := at(root, "top", "mid", "item")
			put(t, item, "real")
			put(t, at(root, "decoy", "mid", "item"), "decoy")
			// Where the real item is once its folder is moved aside.
			aside := at(root, "top.real", "mid", "item")
			trash_swap = Trash_Swap {
				dir    = at(root, "top"),
				target = at(root, "decoy"),
				kind   = kind,
			}
			if swapped == "mid" {
				aside = at(root, "top", "mid.real", "item")
				trash_swap.dir = at(root, "top", "mid")
				trash_swap.target = at(root, "decoy", "mid")
			}

			before_trash = swap_on_trash
			when ODIN_OS == .Darwin {
				landed, err := trash_to(item, context.temp_allocator)
				if landed != "" {
					os.remove(landed)
				}
			} else {
				err := trash(item)
			}
			before_trash = nil
			unlock_file(trash_swap.lock)
			s := trash_swap

			kept := os.exists(at(root, "decoy", "mid", "item"))
			testing.expectf(t, kept, "%v %s: the trash followed the link into decoy (%v)", kind, swapped, err)
			when ODIN_OS == .Windows {
				testing.expectf(t, s.refused && !s.linked, "%v %s: the folder was swapped", kind, swapped)
				testing.expectf(t, err != .None && os.exists(item), "%v %s: %v, the item moved", kind, swapped, err)
			} else {
				testing.expectf(t, s.linked, "%v %s: the folder was not replaced", kind, swapped)
				testing.expectf(t, err == .None, "%v %s: %v", kind, swapped, err)
				testing.expectf(t, !os.exists(aside), "%v %s: the real item was not trashed", kind, swapped)
			}
		}
	}
}
