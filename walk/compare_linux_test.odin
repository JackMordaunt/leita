#+build linux
package walk

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

import "../kstat"
import "../scan"

/*
leita's totals against GNU du, on trees this test builds in a temp directory, one
tree per case so a disagreement names what causes it.

du is asked three ways of each tree: -sb (apparent sizes, bytes), -sB1 (bytes
allocated, the unit st_blocks counts in) and -sk. leita does not charge what du
does, and each difference is pinned here rather than allowed as a tolerance:

- Directories. du adds every directory's own st_size and st_blocks (4096 on ext4, the
  entry count on tmpfs); leita charges a directory nothing, the files in it being
  what fills a disk (read_linux.odin charges `.File` alone).
- Symlinks. du adds the link's own length, the length of its target's name, and any
  blocks it holds; leita charges a
  symlink nothing and does not follow it.
- Directories under --apparent-size. Whether du -sb adds a directory's st_size
  depends on the du: 9.12 does not on tmpfs, where it is 20 bytes an entry, and 4096 a
  directory is what ext4 gives it. The test asks du of an empty directory which it is,
  and holds it to that for every tree.
- Hard links. du counts a file once however many names it has, as leita does, and
  du -l counts it once for each name, which leita never does.

So du == leita + the figures of the directories and symlinks in the tree, taken from
the tree's own nodes with statx, and du -l adds the lengths of the further names. A
tool that agrees with leita after exactly those terms and no others has found no
bytes leita missed or invented.

Sparse files hold only the pages written to them in both; a hole is in du's apparent
size and in neither's allocation. Reflinks and compression belong to btrfs and are
held to compsize by `just btrfs-test` (tools/btrfs-fixture); this filesystem, the
temp directory's, is tmpfs or ext4 and has neither.
*/

// 60 directories of 100 bytes each: a path past PATH_MAX (4096), which only
// *at calls can reach. du reaches the file at the bottom (fts_open keeps a
// descriptor on the directory it is in), and so does the walk, which opens a
// directory that deep a piece at a time (open_pieces in read_linux.odin).
@(private = "file")
deep_case := Case {
	name = "path past PATH_MAX", build = proc(t: ^testing.T, root: string) {
			at, err := linux.open(strings.clone_to_cstring(root, context.temp_allocator), {.PATH, .DIRECTORY})
			testing.expect_value(t, err, linux.Errno.NONE)
			if err != .NONE {return}
			step := strings.clone_to_cstring(strings.repeat("p", 100, context.temp_allocator), context.temp_allocator)
			for _ in 0 ..< 60 {
				testing.expect_value(t, linux.mkdirat(at, step, {.IRUSR, .IWUSR, .IXUSR}), linux.Errno.NONE)
				next, open_err := linux.openat(at, step, {.PATH, .DIRECTORY})
				testing.expect_value(t, open_err, linux.Errno.NONE)
				if open_err != .NONE {return}
				linux.close(at)
				at = next
			}
			file, file_err := linux.openat(at, "leaf", {.WRONLY, .CREAT}, {.IRUSR, .IWUSR})
			testing.expect_value(t, file_err, linux.Errno.NONE)
			body := make([]byte, 12_345, context.temp_allocator)
			_, _ = linux.write(file, body)
			linux.close(file)
			linux.close(at)
		}}


// What the tree's directories and symlinks hold, which du charges and leita does
// not, and the sizes of the further names of hard-linked files, which only du -l
// charges. Taken with statx from the root descriptor down, a component at a time, so
// a path past PATH_MAX is reached.
@(private = "file")
Extras :: struct {
	dir_size, dir_blocks:   u64,
	link_size, link_blocks: u64,
	names_size:             u64,
}

@(private = "file")
extras_of :: proc(t: ^testing.T, tree: ^scan.Tree, root: string) -> (sum: Extras) {
	for i in 0 ..< tree.count {
		n := scan.node(tree, i)
		flags := scan.node_flags(n)
		if .Used not_in flags {continue}
		is_dir := .Directory in flags
		is_link := .Reparse in flags
		extra_name := .Extra_Name in flags
		if !is_dir && !is_link && !extra_name {continue}

		// The chain of names from the root down to this node.
		chain: [dynamic]string
		chain.allocator = context.temp_allocator
		for at := u32(i); at != tree.root; at = scan.node(tree, at).parent {
			append(&chain, scan.name_of(tree, at))
		}
		at, err := linux.open(strings.clone_to_cstring(root, context.temp_allocator), {.PATH, .DIRECTORY})
		if !testing.expect_value(t, err, linux.Errno.NONE) {return}
		for k := len(chain) - 1; k >= 1; k -= 1 {
			next, open_err := linux.openat(
				at,
				strings.clone_to_cstring(chain[k], context.temp_allocator),
				{.PATH, .DIRECTORY, .NOFOLLOW},
			)
			linux.close(at)
			if !testing.expect_value(t, open_err, linux.Errno.NONE) {return}
			at = next
		}
		st: linux.Statx
		name := "."
		if len(chain) > 0 {
			name = chain[0]
		}
		stat_err := kstat.statx(
			at,
			strings.clone_to_cstring(name, context.temp_allocator),
			{.SYMLINK_NOFOLLOW},
			{.SIZE, .BLOCKS},
			&st,
		)
		linux.close(at)
		if !testing.expect_value(t, stat_err, linux.Errno.NONE) {return}
		switch {
		case is_dir:
			sum.dir_size += u64(st.size)
			sum.dir_blocks += u64(st.blocks) * 512
		case is_link:
			sum.link_size += u64(st.size)
			sum.link_blocks += u64(st.blocks) * 512
		case extra_name:
			sum.names_size += u64(st.size)
		}
	}
	return
}

@(test)
test_totals_agree_with_du_after_the_documented_differences :: proc(t: ^testing.T) {
	temp, _ := os.temp_directory(context.temp_allocator)
	top := fmt.tprintf("%s/leita_walk_du_%d", temp, os.get_pid())
	os.remove_all(top)
	defer os.remove_all(top)

	testing.expect(t, os.make_directory(top) == nil)
	if !has_tool({"du", "--version"}) {
		// Not GNU du (BusyBox, say): none of its flags below are known to it.
		fmt.eprintln("skipped: du --version failed")
		return
	}

	// Does this du add directories' own sizes to the apparent total?
	probe := fmt.tprintf("%s/probe", top)
	testing.expect(t, os.make_directory(probe) == nil)
	probe_size, _, probe_ok := run_tool({"du", "-sb", probe})
	testing.expect(t, probe_ok, "du -sb failed on an empty directory")
	dirs_counted := probe_size != 0
	fmt.eprintfln("du -sb adds directories' sizes: %v (an empty directory: %d)", dirs_counted, probe_size)

	fmt.eprintfln("%-22s %12s %12s | %12s %12s | %s", "case", "leita app.", "du -sb", "leita alloc", "du -sB1", "differences du adds")
	all: [dynamic]Case
	all.allocator = context.temp_allocator
	append(&all, ..common_cases[:])
	append(&all, deep_case)
	for c in all {
		root := fmt.tprintf("%s/%s", top, strings.replace_all(c.name, " ", "_", context.temp_allocator))
		testing.expect(t, os.make_directory(root) == nil)
		c.build(t, root)

		tree: scan.Tree
		testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
		defer scan.tree_destroy(&tree)

		testing.expect_value(t, read(root, &tree, Config{}), Error.None)
		sum := totals_of(&tree)
		extras := extras_of(t, &tree, root)

		apparent, _, a_ok := run_tool({"du", "-sb", root})
		allocated, _, b_ok := run_tool({"du", "-sB1", root})
		kib, _, k_ok := run_tool({"du", "-sk", root})
		linked, _, l_ok := run_tool({"du", "-sb", "-l", root})
		testing.expectf(t, a_ok && b_ok && k_ok && l_ok, "%s: du failed", c.name)

		fmt.eprintfln(
			"%-22s %12d %12d | %12d %12d | dirs %d+%d, symlinks %d+%d, names %d",
			c.name,
			sum.apparent,
			apparent,
			sum.allocated,
			allocated,
			extras.dir_size,
			extras.dir_blocks,
			extras.link_size,
			extras.link_blocks,
			extras.names_size,
		)
		testing.expect_value(t, tree.bytes_done, sum.allocated)
		testing.expect_value(t, tree.unread, 0)
		dir_size := extras.dir_size if dirs_counted else 0
		testing.expectf(
			t,
			apparent == sum.apparent + dir_size + extras.link_size,
			"%s: du -sb says %d; leita %d + directories %d + symlinks %d",
			c.name,
			apparent,
			sum.apparent,
			dir_size,
			extras.link_size,
		)
		testing.expectf(
			t,
			allocated == sum.allocated + extras.dir_blocks + extras.link_blocks,
			"%s: du -sB1 says %d; leita %d + directories %d + symlinks %d",
			c.name,
			allocated,
			sum.allocated,
			extras.dir_blocks,
			extras.link_blocks,
		)
		// -sk is -sB1 in kibibytes, rounded up.
		testing.expect_value(t, kib, (allocated + 1023) / 1024)
		// du -l counts each name of a file again; leita, and du by default, do not.
		testing.expect_value(t, linked, apparent + extras.names_size)
		if !c.linked {
			testing.expect_value(t, extras.names_size, 0)
		}
	}
}
