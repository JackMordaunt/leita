#+build darwin
package walk

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "../scan"

/*
Every file's length and allocation agree with what lstat says of it.

lstat is the yardstick: an empty file, a written one, one of mostly hole, a name
outside ASCII and one as long as APFS allows, so the parse is tried on names of every
width.
*/
@(test)
test_bulk_agrees_with_lstat :: proc(t: ^testing.T) {
	root := fresh_root(t, "agree")
	defer os.remove_all(root)

	body := make([]byte, 70_000, context.temp_allocator)
	slice.fill(body, 'x')
	long := strings.repeat("n", 255, context.temp_allocator)
	for name in ([]string{"empty", "written", "naïve résumé ☃", long}) {
		size := 0 if name == "empty" else len(body)
		path := fmt.tprintf("%s/%s", root, name)
		testing.expectf(
			t,
			os.write_entire_file(path, body[:size]) == nil,
			"could not write %s",
			name,
		)
	}
	hole, hole_err := os.open(fmt.tprintf("%s/hole", root), {.Write, .Create, .Trunc})
	testing.expect(t, hole_err == nil, "could not create the sparse file")
	testing.expect(t, os.truncate(hole, 64 << 20) == nil, "could not extend the sparse file")
	os.close(hole)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	checked := 0
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i == tree.root || .Used not_in n.flags {
			continue
		}
		path := strings.clone_to_cstring(
			fmt.tprintf("%s/%s", root, n.name),
			context.temp_allocator,
		)
		st: posix.stat_t
		testing.expectf(t, posix.lstat(path, &st) == .OK, "lstat refused %s", n.name)
		testing.expectf(
			t,
			n.size == u64(st.st_size),
			"%s: size %d, lstat %d",
			n.name,
			n.size,
			st.st_size,
		)
		testing.expectf(
			t,
			n.disk == u64(st.st_blocks) * 512,
			"%s: disk %d, lstat %d blocks",
			n.name,
			n.disk,
			st.st_blocks,
		)
		checked += 1
	}
	testing.expect_value(t, checked, 5)
}

/*
A directory too big for one buffer comes back whole over several calls.

Each name here is 200 bytes, so 400 of them fill the 32 KB buffer a few times over;
an entry lost or read twice at a batch's edge would show as a wrong count or a
repeated name.
*/
@(test)
test_a_directory_larger_than_a_batch_is_read_whole :: proc(t: ^testing.T) {
	root := fresh_root(t, "batches")
	defer os.remove_all(root)

	COUNT :: 400
	pad := strings.repeat("p", 196, context.temp_allocator)
	for i in 0 ..< COUNT {
		path := fmt.tprintf("%s/%04d%s", root, i, pad)
		testing.expectf(t, os.write_entire_file(path, []byte{'x'}) == nil, "could not write %d", i)
	}

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	seen: [COUNT]bool
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i == tree.root || .Used not_in n.flags {
			continue
		}
		testing.expectf(t, len(n.name) == 200, "a name came back as %q", n.name)
		index, ok := strconv.parse_int(n.name[:4])
		ok = ok && index >= 0 && index < COUNT
		testing.expectf(t, ok && !seen[index], "%s was read twice or not at all", n.name)
		seen[index] = true
	}
	for s, i in seen {
		testing.expectf(t, s, "entry %d was never read", i)
	}
}

// An entry claiming more than the buffer holds, or a name lying outside its entry, is
// refused rather than read as a file.
@(test)
test_a_malformed_entry_is_refused :: proc(t: ^testing.T) {
	// length, returned set, name reference, then the name itself.
	entry :: proc(length: u32, name_offset: i32, name_length: u32) -> [40]u8 {
		b: [40]u8
		endian.put_u32(b[0:], .Little, length)
		endian.put_u32(b[4:], .Little, ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME)
		endian.put_u32(b[24:], .Little, u32(name_offset))
		endian.put_u32(b[28:], .Little, name_length)
		copy(b[32:], "abc\x00")
		return b
	}

	good := entry(40, 8, 4)
	e, length, ok := parse_entry(good[:])
	testing.expect(t, ok, "a well-formed entry was refused")
	testing.expect_value(t, e.name, "abc")
	testing.expect_value(t, length, 40)

	too_long := entry(41, 8, 4)
	_, _, ok = parse_entry(too_long[:])
	testing.expect(t, !ok, "an entry longer than its buffer was accepted")

	too_short := entry(20, 8, 4)
	_, _, ok = parse_entry(too_short[:])
	testing.expect(t, !ok, "an entry too short for its header was accepted")

	name_outside := entry(40, 8, 9)
	_, _, ok = parse_entry(name_outside[:])
	testing.expect(t, !ok, "a name running past its entry was accepted")

	name_behind := entry(40, -8, 4)
	_, _, ok = parse_entry(name_behind[:])
	testing.expect(t, !ok, "a name before its reference was accepted")

	_, _, ok = parse_entry(good[:3])
	testing.expect(t, !ok, "a buffer too short for a length was accepted")
}

@(private = "file")
fresh_root :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/sonar_walk_darwin_%s", dir, name)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	return root
}
