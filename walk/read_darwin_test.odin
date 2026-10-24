#+build darwin
package walk

import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

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
			fmt.tprintf("%s/%s", root, scan.name_of(&tree, i)),
			context.temp_allocator,
		)
		st: posix.stat_t
		testing.expectf(
			t,
			posix.lstat(path, &st) == .OK,
			"lstat refused %s",
			scan.name_of(&tree, i),
		)
		testing.expectf(
			t,
			n.disk == u64(st.st_blocks) * 512,
			"%s: disk %d, lstat %d blocks",
			scan.name_of(&tree, i),
			n.disk,
			st.st_blocks,
		)
		checked += 1
	}
	testing.expect_value(t, checked, 5)
}

// A test directory on APFS supplies real kernel clone ids and allocations.
// The source and duplicate share only their data fork; a pure clone charges it
// once while preserving each file's other allocation.
@(test)
test_apfs_clone_is_recognized_and_reduces_charge :: proc(t: ^testing.T) {
	root := fresh_root(t, "clone")
	defer os.remove_all(root)
	st, stat_ok := scan.stat_fs(root)
	if !testing.expect(
		t,
		stat_ok && string(cstring(&st.fstypename[0])) == "apfs",
		"macOS clone fixture requires APFS",
	) {return}
	body := make([]byte, 1 << 20, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/source", root), body) == nil)
	state, _, stderr, err := os.process_exec(
		{
			command = []string {
				"cp",
				"-c",
				fmt.tprintf("%s/source", root),
				fmt.tprintf("%s/clone", root),
			},
		},
		context.temp_allocator,
	)
	if !testing.expectf(
		t,
		err == nil && state.exited && state.exit_code == 0,
		"cp -c failed: %v %s",
		err,
		stderr,
	) {return}
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)
	shared := 0
	file_count := 0
	charged, allocated: u64
	for i in 0 ..< tree.count {
		if i == tree.root {continue}
		n := scan.node(&tree, i)
		if .Used not_in n.flags || .Directory in n.flags {continue}
		file_count += 1
		account, measured := scan.account_of(&tree, i)
		testing.expect(t, measured && .Allocated in account.known)
		allocated += account.allocated
		charged += n.disk
		if .Shared in n.flags {
			shared += 1
			testing.expect(t, scan.freed_of(&tree, i).basis == .Unknown)
		}
	}
	testing.expect_value(t, file_count, 2)
	testing.expect_value(t, shared, 1)
	testing.expect(
		t,
		charged > 0 && charged < allocated,
		"a pure clone must reduce the charged total below two allocations",
	)
}

// A fresh image isolates enumeration from the runner's Time Machine snapshots.
// The expected result for this image is a completed, empty local snapshot list.
@(test)
test_empty_apfs_image_has_no_local_snapshots :: proc(t: ^testing.T) {
	root := fresh_root(t, "snapshots")
	defer os.remove_all(root)
	image := fmt.tprintf("%s.dmg", root)
	mount := fmt.tprintf("%s/mounted", root)
	defer os.remove(image)
	testing.expect(t, os.make_directory(mount) == nil)
	if !hdiutil(t, "create", "-size", "64m", "-fs", "APFS", "-volname", "leita", image) {
		return
	}
	device, attached := attach_image(t, image, mount)
	if !attached {
		return
	}
	defer detach_image(t, device)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	darwin_retention(mount, &tree)
	testing.expect(t, scan.has_snapshot_volume(&tree))
	testing.expect_value(t, scan.retention_of(&tree).snapshots, scan.Snapshot_State.None)
	testing.expect_value(t, len(scan.snapshot_names_of(&tree)), 0)
	// Whatever macOS answers for the image must fit in it.
	got := scan.retention_of(&tree)
	log.infof("purgeable on a fresh APFS image: %d (known %v)", got.purgeable, got.purgeable_known)
	if got.purgeable_known {
		testing.expect(t, got.purgeable <= 64 * 1024 * 1024)
	}
}

/*
macOS answers for purgeable space on the startup Data volume, the one a home
folder scan reaches. The figure is the system's; the test asserts only that it
answers and that the answer is a byte count no larger than the volume.
*/
@(test)
test_purgeable_on_data_volume :: proc(t: ^testing.T) {
	root := "/System/Volumes/Data"
	st, ok := scan.stat_fs(root)
	if !testing.expect(t, ok) {
		return
	}
	purgeable, known := darwin_purgeable(root)
	log.infof("purgeable on %s: %d bytes (known %v)", root, purgeable, known)
	testing.expect(t, known, "macOS 11+ answers both CFURL capacity keys")
	testing.expect(t, purgeable <= u64(st.blocks) * u64(st.bsize))
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
		name := scan.name_of(&tree, i)
		testing.expectf(t, len(name) == 200, "a name came back as %q", name)
		index, ok := strconv.parse_int(name[:4])
		ok = ok && index >= 0 && index < COUNT
		testing.expectf(t, ok && !seen[index], "%s was read twice or not at all", name)
		seen[index] = true
	}
	for s, i in seen {
		testing.expectf(t, s, "entry %d was never read", i)
	}
}

/*
A volume mounted inside the scanned tree is recorded but not walked.

The mount is a real one, a small disk image attached on a directory in the root, since
only the kernel says which directories are mount points. A plain directory beside it
holding a file shows the walk did descend where it should.
*/
@(test)
test_a_mount_point_is_not_walked :: proc(t: ^testing.T) {
	root := fresh_root(t, "mount")
	defer os.remove_all(root)

	image := fmt.tprintf("%s.dmg", root)
	mount := fmt.tprintf("%s/mounted", root)
	plain := fmt.tprintf("%s/plain", root)
	defer os.remove(image)
	testing.expect(t, os.make_directory(mount) == nil, "could not make the mount point")
	testing.expect(t, os.make_directory(plain) == nil, "could not make the plain directory")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/kept", plain), []byte{'x'}) == nil)

	if !hdiutil(t, "create", "-size", "1m", "-fs", "HFS+", "-volname", "leita", image) {
		return
	}
	device, attached := attach_image(t, image, mount)
	if !attached {
		return
	}
	defer detach_image(t, device)

	hidden := fmt.tprintf("%s/hidden", mount)
	testing.expect(t, os.write_entire_file(hidden, []byte{'x'}) == nil, "could not write")

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	names: map[string]u32
	defer delete(names)
	for index in 0 ..< tree.count {
		n := scan.node(&tree, index)
		if .Used in n.flags {
			names[scan.name_of(&tree, index)] = index
		}
	}
	mounted, has_mount := names["mounted"]
	testing.expect(t, has_mount, "the mount point was not recorded")
	testing.expect(t, .Directory in scan.node(&tree, mounted).flags, "not a directory")
	testing.expect(t, .Mount in scan.node(&tree, mounted).flags, "not marked a mount")
	testing.expect(t, "kept" in names, "the plain directory was not walked")
	testing.expect(t, "hidden" not_in names, "the mounted volume was walked")
}

// Run hdiutil, failing the test with what it said if it does not succeed.
@(private = "file")
hdiutil :: proc(t: ^testing.T, args: ..string) -> bool {
	ok, stdout, stderr := capture_hdiutil(args)
	testing.expectf(t, ok, "hdiutil %v failed: %s%s", args, stdout, stderr)
	return ok
}

@(private = "file")
capture_hdiutil :: proc(args: []string) -> (ok: bool, stdout, stderr: string) {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "hdiutil")
	append(&command, ..args)
	state, out, errout, err := os.process_exec({command = command[:]}, context.temp_allocator)
	return err == nil && state.exited && state.exit_code == 0, string(out), string(errout)
}

// Attach image on mount and return the whole-disk device it came up as, the first
// line of what attach prints. The device, not the mount point, is what detach must
// name: once the volume is unmounted the mount point no longer identifies anything.
@(private = "file")
attach_image :: proc(t: ^testing.T, image, mount: string) -> (device: string, ok: bool) {
	args := []string{"attach", "-nobrowse", "-noverify", "-mountpoint", mount, image}
	stdout, stderr: string
	ok, stdout, stderr = capture_hdiutil(args)
	if !testing.expectf(t, ok, "hdiutil %v failed: %s%s", args, stdout, stderr) {
		return
	}

	first, _, _ := strings.partition(stdout, "\n")
	fields := strings.fields(first, context.temp_allocator)
	if !testing.expectf(
		t,
		len(fields) > 0 && strings.has_prefix(fields[0], "/dev/disk"),
		"hdiutil attach named no device: %q",
		stdout,
	) {
		return "", false
	}
	return fields[0], true
}

// Eject the image's disk, retrying while the kernel reports it busy.
//
// On a loaded macOS runner (load average 10 to 19, GitHub Actions runs 40029404222,
// 40029515459 and 40091300468) `detach -force <mount>` unmounted the APFS volume and still
// failed to eject its container, "couldn't eject disk7 - Resource busy"; ten
// seconds of retries by mount point then said "No such file or directory", the
// volume being gone, so the device is what gets retried. Who held the container is
// not known; the retry waits for it to let go.
@(private = "file")
detach_image :: proc(t: ^testing.T, device: string) {
	ATTEMPTS :: 40
	stdout, stderr: string
	for attempt in 1 ..= ATTEMPTS {
		ok: bool
		ok, stdout, stderr = capture_hdiutil({"detach", "-force", device})
		if ok {
			if attempt > 1 {
				log.infof(
					"hdiutil detach %s: ejected on attempt %d, after it was busy",
					device,
					attempt,
				)
			}
			return
		}
		if !strings.contains(stderr, "busy") {
			break
		}
		time.sleep(500 * time.Millisecond)
	}
	testing.expectf(t, false, "hdiutil detach %s failed: %s%s", device, stdout, stderr)
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

@(test)
test_extended_apfs_entry_reads_each_returned_fact :: proc(t: ^testing.T) {
	b: [104]u8
	endian.put_u32(b[0:], .Little, u32(len(b)))
	endian.put_u32(
		b[4:],
		.Little,
		ATTR_CMN_RETURNED_ATTRS |
		ATTR_CMN_NAME |
		ATTR_CMN_DEVID |
		ATTR_CMN_OBJTYPE |
		ATTR_CMN_FILEID,
	)
	endian.put_u32(
		b[16:],
		.Little,
		ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH | ATTR_FILE_DATAALLOCSIZE,
	)
	endian.put_u32(
		b[20:],
		.Little,
		ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_REALDEVID | ATTR_CMNEXT_CLONEID,
	)
	endian.put_u32(b[24:], .Little, 72) // name starts at 96, relative to attrreference
	endian.put_u32(b[28:], .Little, 4)
	endian.put_u32(b[32:], .Little, 4)
	endian.put_u32(b[36:], .Little, 1) // VREG
	endian.put_u64(b[40:], .Little, 99)
	endian.put_u32(b[48:], .Little, 1)
	endian.put_u64(b[52:], .Little, 12288)
	endian.put_u64(b[60:], .Little, 7000)
	endian.put_u64(b[68:], .Little, 8192)
	endian.put_u64(b[76:], .Little, 4096)
	endian.put_u32(b[84:], .Little, 8)
	endian.put_u64(b[88:], .Little, 101)
	copy(b[96:], "one\x00")
	e, length, ok := parse_entry(b[:])
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, length, len(b))
	testing.expect_value(t, e.name, "one")
	testing.expect_value(t, e.id.device, u64(4))
	testing.expect_value(t, e.id.inode, u64(99))
	testing.expect_value(t, e.links, u32(1))
	testing.expect_value(t, e.darwin.account.links, u32(1))
	testing.expect(t, !e.directory && !e.symlink, "VREG must remain a regular file")
	testing.expect_value(t, e.disk, u64(12288))
	testing.expect_value(t, e.darwin.account.logical, u64(7000))
	testing.expect_value(t, e.darwin.data_allocated, u64(8192))
	testing.expect_value(t, e.darwin.account.exclusive, u64(4096))
	testing.expect_value(t, e.darwin.device, u64(8))
	testing.expect_value(t, e.darwin.clone, u64(101))
	testing.expect(t, e.darwin.account.known == {.Allocated, .Logical, .Exclusive, .Links})
}

@(private = "file")
fresh_root :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_walk_darwin_%s_%d", dir, name, os.get_pid())
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	return root
}
