#+build windows, darwin
package walk

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

import "../scan"

// The link a replaced directory becomes: a symlink everywhere, and on Windows a
// junction too, as creating a symlink there may need privilege.
@(private = "file")
Link_Kind :: enum {
	Symlink,
	Junction,
}

// Where one walk replaces a directory with a link: once the walk has finished
// listing `at`, `dir` is renamed aside and a link to `target` put in its place.
@(private = "file")
Native_Swap :: struct {
	at:     string,
	dir:    string,
	target: string,
	kind:   Link_Kind,
	t:      ^testing.T,
	done:   bool,
	linked: bool,
}

@(private = "file")
swap_after_list :: proc(path: string, data: rawptr) {
	swap := cast(^Native_Swap)data
	// The Windows reader queues what it finds under the \\?\ form of the root.
	if swap == nil || swap.done || (path != swap.at && path != fmt.tprintf(`\\?\%s`, swap.at)) {
		return
	}
	swap.done = true
	if os.rename(swap.dir, fmt.tprintf("%s.real", swap.dir)) != nil {
		log.errorf("could not move %s aside", swap.dir)
		return
	}
	swap.linked = link_dir(swap.t, swap.target, swap.dir, swap.kind)
}

@(private = "file")
link_dir :: proc(t: ^testing.T, target, path: string, kind: Link_Kind) -> bool {
	switch kind {
	case .Symlink:
		return symlink_directory(target, path)
	case .Junction:
		when ODIN_OS == .Windows {
			return make_junction(t, path, fmt.tprintf(`\??\%s`, target))
		} else {
			return false
		}
	}
	return false
}

@(private = "file")
KINDS :: []Link_Kind{.Symlink, .Junction} when ODIN_OS == .Windows else []Link_Kind{.Symlink}

@(private = "file")
native_fixture :: proc(t: ^testing.T, name: string) -> (base, root, outside: string) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	base = fmt.tprintf("%s%sleita_walk_native_%s_%d", dir, scan.SEPARATOR, name, os.get_pid())
	os.remove_all(base)
	root = fmt.tprintf("%s%sroot", base, scan.SEPARATOR)
	outside = fmt.tprintf("%s%soutside", base, scan.SEPARATOR)
	testing.expect(t, os.make_directory_all(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory_all(outside) == nil, "could not make the outside")
	return
}

@(private = "file")
walk_with_swap :: proc(t: ^testing.T, root: string, swap: ^Native_Swap) -> scan.Tree {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	cfg := Config {
		workers         = 1,
		after_list      = swap_after_list,
		after_list_data = swap,
	}
	testing.expect_value(t, read(root, &tree, cfg), Error.None)
	return tree
}

/*
A directory listed as a directory, then replaced with a link to a directory outside
the walk before it is opened, must not be followed when the walk does not follow
links.
*/
@(test)
test_native_a_replaced_directory_is_not_followed :: proc(t: ^testing.T) {
	for kind in KINDS {
		base, root, outside := native_fixture(t, fmt.tprintf("final_%v", kind))
		defer os.remove_all(base)

		sub := fmt.tprintf("%s%ssub", root, scan.SEPARATOR)
		testing.expect(t, os.make_directory(sub) == nil)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s%sinside.txt", sub, scan.SEPARATOR), "i") == nil)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s%ssecret.txt", outside, scan.SEPARATOR), "s") == nil)

		swap := Native_Swap{at = root, dir = sub, target = outside, kind = kind, t = t}
		tree := walk_with_swap(t, root, &swap)
		defer scan.tree_destroy(&tree)

		testing.expectf(t, swap.linked, "%v: sub was not replaced", kind)
		_, secrets := named(&tree, "secret.txt")
		_, insides := named(&tree, "inside.txt")
		secret, inside := secrets > 0, insides > 0
		testing.expectf(t, !secret, "%v: the link put in place of sub was followed", kind)
		testing.expectf(t, !inside, "%v: the directory moved aside was still walked", kind)
		expect_unread(t, &tree, "sub", kind)
	}
}

// The directory called name was recorded, and left unread rather than walked.
@(private = "file")
expect_unread :: proc(t: ^testing.T, tree: ^scan.Tree, name: string, kind: Link_Kind) {
	n, count := named(tree, name)
	testing.expectf(t, count == 1, "%v: %d nodes named %s", kind, count, name)
	if n != nil {
		testing.expectf(t, .Unread in n.flags, "%v: %s was not left unread", kind, name)
	}
}

/*
The directory above the one about to be opened is replaced with a link. Refusing
only a link in the last component would still follow this one.
*/
@(test)
test_native_a_replaced_ancestor_is_not_followed :: proc(t: ^testing.T) {
	for kind in KINDS {
		base, root, outside := native_fixture(t, fmt.tprintf("middle_%v", kind))
		defer os.remove_all(base)

		a := fmt.tprintf("%s%sa", root, scan.SEPARATOR)
		b := fmt.tprintf("%s%sb", a, scan.SEPARATOR)
		testing.expect(t, os.make_directory_all(b) == nil)
		testing.expect(t, os.make_directory(fmt.tprintf("%s%sb", outside, scan.SEPARATOR)) == nil)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s%sinside.txt", b, scan.SEPARATOR), "i") == nil)
		testing.expect(
			t,
			os.write_entire_file(fmt.tprintf("%s%sb%ssecret.txt", outside, scan.SEPARATOR, scan.SEPARATOR), "s") == nil,
		)

		swap := Native_Swap{at = a, dir = a, target = outside, kind = kind, t = t}
		tree := walk_with_swap(t, root, &swap)
		defer scan.tree_destroy(&tree)

		testing.expectf(t, swap.linked, "%v: a was not replaced", kind)
		_, secrets := named(&tree, "secret.txt")
		_, insides := named(&tree, "inside.txt")
		secret, inside := secrets > 0, insides > 0
		testing.expectf(t, !secret, "%v: the link put in place of a was followed", kind)
		testing.expectf(t, !inside, "%v: the directory moved aside was still walked", kind)
		expect_unread(t, &tree, "b", kind)
	}
}
