#+build windows
package walk

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import win "core:sys/windows"
import "core:testing"

import "../scan"

foreign import kernel32 "system:Kernel32.lib"

/*
Two names of one file are charged once.

The file is linked from a second folder, so the names are recorded by whichever
workers read the two folders, which is the case Linked_Files exists for. The
reader this replaced knew no link count and charged both names in full.
*/
@(test)
test_a_hard_linked_file_is_charged_once :: proc(t: ^testing.T) {
	root := fresh_root(t, "hardlink")
	defer remove_tree(root)
	make_dir(t, join_path(root, "a"))
	make_dir(t, join_path(root, "b"))
	data := join_path(root, `a\data.bin`)
	write_file(t, data, 256 * 1024)
	link := join_path(root, `b\data-link.bin`)
	if !win.CreateHardLinkW(long(link), long(data), nil) {
		log.errorf("could not link %s: %d", link, win.GetLastError())
		return
	}

	tree := walk_tree(t, root, Config{workers = 2})
	defer scan.tree_destroy(&tree)

	original := only(t, &tree, "data.bin")
	linked := only(t, &tree, "data-link.bin")
	if original == nil || linked == nil {
		return
	}
	extras := int(.Extra_Name in original.flags) + int(.Extra_Name in linked.flags)
	testing.expectf(t, extras == 1, "%d of the two names marked an extra name", extras)
	charged := original if .Extra_Name in linked.flags else linked
	testing.expectf(t, charged.disk >= 256 * 1024, "the file charged %d bytes", charged.disk)
	testing.expect_value(t, tree.bytes_done, charged.disk)
	log.infof(
		"hard link: charged %d bytes for both names; the old reader charged %d",
		tree.bytes_done,
		2 * estimate(256 * 1024),
	)
}

/*
A file of mostly hole is charged the little it occupies, not its length: 64 MiB long
with sixteen bytes written. The reader this replaced charged its whole length.
*/
@(test)
test_a_sparse_file_is_charged_what_it_occupies_on_windows :: proc(t: ^testing.T) {
	root := fresh_root(t, "sparse")
	defer remove_tree(root)
	path := join_path(root, "hole.bin")
	LENGTH :: 64 * 1024 * 1024

	f := create(t, path)
	if f == win.INVALID_HANDLE_VALUE {
		return
	}
	returned: win.DWORD
	sparse := win.DeviceIoControl(f, FSCTL_SET_SPARSE, nil, 0, nil, 0, &returned, nil)
	if !sparse {
		log.errorf("the volume refused to make a file sparse: %d", win.GetLastError())
		win.CloseHandle(f)
		return
	}
	testing.expect(t, bool(win.SetFilePointerEx(f, LENGTH, nil, win.FILE_BEGIN)), "seek")
	testing.expect(t, bool(win.SetEndOfFile(f)), "could not extend the sparse file")
	testing.expect(t, bool(win.SetFilePointerEx(f, 0, nil, win.FILE_BEGIN)), "seek back")
	body := [16]u8 {
		0 ..< 16 = 'x',
	}
	written: win.DWORD
	testing.expect(t, bool(win.WriteFile(f, &body, len(body), &written, nil)), "write")
	// Flushed, so what is measured is what reached the volume.
	testing.expect(t, bool(win.FlushFileBuffers(f)), "flush")
	win.CloseHandle(f)

	tree := walk_tree(t, root)
	defer scan.tree_destroy(&tree)
	hole := only(t, &tree, "hole.bin")
	if hole == nil {
		return
	}
	testing.expectf(
		t,
		hole.disk > 0 && hole.disk < 1024 * 1024,
		"the sparse file charged %d bytes",
		hole.disk,
	)
	log.infof(
		"sparse: charged %d bytes for a %d byte file; the old reader charged %d",
		hole.disk,
		LENGTH,
		estimate(LENGTH),
	)
}

/*
An NTFS-compressed file is charged its compressed clusters. A megabyte of one byte
repeated compresses to almost nothing. Skipped, with the reason logged, where the
volume refuses to compress the file.
*/
@(test)
test_a_compressed_file_is_charged_what_it_occupies :: proc(t: ^testing.T) {
	root := fresh_root(t, "compressed")
	defer remove_tree(root)
	path := join_path(root, "squeezed.bin")
	LENGTH :: 1024 * 1024

	f := create(t, path)
	if f == win.INVALID_HANDLE_VALUE {
		return
	}
	format := u16(COMPRESSION_FORMAT_DEFAULT)
	returned: win.DWORD
	compressed := win.DeviceIoControl(
		f,
		FSCTL_SET_COMPRESSION,
		&format,
		size_of(format),
		nil,
		0,
		&returned,
		nil,
	)
	if !compressed {
		log.warnf("skipped: the volume refused to compress a file: %d", win.GetLastError())
		win.CloseHandle(f)
		return
	}
	body := make([]u8, LENGTH, context.temp_allocator)
	slice.fill(body, 'x')
	written: win.DWORD
	testing.expect(t, bool(win.WriteFile(f, raw_data(body), LENGTH, &written, nil)), "write")
	// Flushed, so what is measured is what reached the volume.
	testing.expect(t, bool(win.FlushFileBuffers(f)), "flush")
	win.CloseHandle(f)

	tree := walk_tree(t, root)
	defer scan.tree_destroy(&tree)
	squeezed := only(t, &tree, "squeezed.bin")
	if squeezed == nil {
		return
	}
	testing.expectf(t, squeezed.disk < LENGTH, "the compressed file charged %d", squeezed.disk)
	log.infof(
		"compressed: charged %d bytes for a %d byte file; the old reader charged %d",
		squeezed.disk,
		LENGTH,
		estimate(LENGTH),
	)
}

/*
A junction, a directory symlink and a mounted volume inside the tree are recorded but
not walked. The junction and the symlink lead out of the tree, to a folder holding
outside.txt; the mounted volume is the one the temp directory is on, mounted again,
so walking it would read the whole drive. The first two are links, the third the
directory it appears to be.
*/
@(test)
test_links_and_mounts_are_not_walked :: proc(t: ^testing.T) {
	outside := fresh_root(t, "outside")
	defer remove_tree(outside)
	write_file(t, join_path(outside, "outside.txt"), 10)
	root := fresh_root(t, "links")
	defer remove_tree(root)
	write_file(t, join_path(root, "inside.txt"), 10)

	junction := join_path(root, "junction")
	if !make_junction(t, junction, fmt.tprintf(`\??\%s`, outside)) {
		return
	}
	dirlink := join_path(root, "dirlink")
	flags := win.SYMBOLIC_LINK_FLAG_DIRECTORY | win.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
	symlinked := bool(win.CreateSymbolicLinkW(long(dirlink), long(outside), flags))
	if !symlinked {
		log.warnf("no directory symlink: %d", win.GetLastError())
	}
	mount := join_path(root, "mounted")
	volume, has_volume := volume_of_path(root)
	mounted := has_volume && make_junction(t, mount, fmt.tprintf(`\??\%s`, volume[4:]))
	if !mounted {
		log.warnf("no volume mounted inside the tree")
	}

	tree := walk_tree(t, root)
	defer scan.tree_destroy(&tree)
	_, outsides := named_in(&tree, "outside.txt")
	testing.expect_value(t, outsides, 0)
	// only fails the test itself when a name is missing or doubled, so an empty
	// tree cannot pass.
	testing.expect(t, only(t, &tree, "inside.txt") != nil, "inside.txt was not walked")
	if j := only(t, &tree, "junction"); j != nil {
		testing.expect(t, .Reparse in j.flags, "the junction is not marked a reparse point")
		testing.expect(t, .Directory not_in j.flags, "the junction is counted as a directory")
	}
	if symlinked {
		if l := only(t, &tree, "dirlink"); l != nil {
			testing.expect(t, .Reparse in l.flags, "the symlink is not marked a reparse point")
		}
	}
	if mounted {
		if m := only(t, &tree, "mounted"); m != nil {
			testing.expect(t, .Directory in m.flags, "the mount is not a directory")
			testing.expect(t, .Reparse not_in m.flags, "the mount is marked a link")
			testing.expect(t, .Mount in m.flags, "the mount is not marked a mount")
		}
		// Every node is inside.txt, the three links and the root.
		testing.expectf(t, tree.count <= 5, "%d nodes: the mount was walked", tree.count)
	}
}

// Asked to, a walk goes through a junction, as it goes through a symlink elsewhere.
@(test)
test_a_junction_is_followed_when_asked :: proc(t: ^testing.T) {
	outside := fresh_root(t, "followed")
	defer remove_tree(outside)
	write_file(t, join_path(outside, "outside.txt"), 10)
	root := fresh_root(t, "follow_junction")
	defer remove_tree(root)
	if !make_junction(t, join_path(root, "junction"), fmt.tprintf(`\??\%s`, outside)) {
		return
	}

	tree := walk_tree(t, root, Config{follow = true})
	defer scan.tree_destroy(&tree)
	_, outsides := named_in(&tree, "outside.txt")
	testing.expect_value(t, outsides, 1)
}

/*
A path past 260 characters and names outside ASCII are read like any other. The
deepest file sits under five directories of 60 characters each, beyond the limit
before the temp directory is even counted.
*/
@(test)
test_long_paths_and_unicode_names_are_read :: proc(t: ^testing.T) {
	root := fresh_root(t, "long")
	defer remove_tree(root)
	deep := root
	for c in ([]u8{'d', 'e', 'f', 'g', 'h'}) {
		segment := strings.repeat(fmt.tprintf("%c", c), 60, context.temp_allocator)
		deep = join_path(deep, segment)
		make_dir(t, deep)
	}
	testing.expectf(t, len(deep) > 300, "the deep path is only %d long", len(deep))
	write_file(t, join_path(deep, "deep.txt"), 5000)
	unicode := []string{"naïve 日本語 😀.txt", "каталог"}
	write_file(t, join_path(root, unicode[0]), 100)
	make_dir(t, join_path(root, unicode[1]))
	write_file(t, join_path(root, `каталог\файл.txt`), 5000)

	tree := walk_tree(t, root)
	defer scan.tree_destroy(&tree)
	for name in ([]string{"deep.txt", "naïve 日本語 😀.txt", "каталог", "файл.txt"}) {
		only(t, &tree, name)
	}
	if d := only(t, &tree, "deep.txt"); d != nil {
		testing.expectf(t, d.disk >= 5000, "deep.txt charged %d", d.disk)
	}
	// The root, five directories, deep.txt, two names and a file in one of them.
	testing.expect_value(t, tree.count, u32(10))
}

// Make `path` a symlink to the directory `target`, which core:os's symlink refuses
// on Windows as unsupported (core/os/file_windows.odin). Needs Developer Mode or an
// elevated process.
@(private)
symlink_directory :: proc(target, path: string) -> bool {
	flags := win.SYMBOLIC_LINK_FLAG_DIRECTORY | win.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
	link := win.utf8_to_wstring(path, context.temp_allocator)
	return bool(
		win.CreateSymbolicLinkW(link, win.utf8_to_wstring(target, context.temp_allocator), flags),
	)
}

// What the reader this replaced charged a file of `length` bytes: its length rounded
// up to four kilobytes, whatever it occupied.
@(private = "file")
estimate :: proc(length: u64) -> u64 {
	return (length + 4095) / 4096 * 4096
}

@(private = "file")
walk_tree :: proc(t: ^testing.T, root: string, cfg := Config{}) -> scan.Tree {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, max(cfg.workers, 1)), scan.Error.None)
	testing.expect_value(t, read(root, &tree, cfg), Error.None)
	return tree
}

@(private = "file")
named_in :: proc(tree: ^scan.Tree, name: string) -> (^scan.Node, int) {
	found: ^scan.Node
	count := 0
	for i in 0 ..< tree.count {
		n := scan.node(tree, i)
		if .Used in n.flags && scan.name_of(tree, i) == name {
			found = n
			count += 1
		}
	}
	return found, count
}

// The one node named `name`, failing the test unless there is exactly one.
@(private = "file")
only :: proc(t: ^testing.T, tree: ^scan.Tree, name: string) -> ^scan.Node {
	n, count := named_in(tree, name)
	if count != 1 {
		log.errorf("expected one %s, found %d", name, count)
		return nil
	}
	return n
}

@(private = "file")
fresh_root :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := join_path(
		strings.trim_right(dir, `\/`),
		fmt.tprintf("leita_walk_win_%s_%d", name, os.get_pid()),
	)
	remove_tree(root)
	make_dir(t, root)
	return root
}

@(private = "file")
join_path :: proc(dir, name: string) -> string {
	return fmt.tprintf(`%s\%s`, dir, name)
}

// `path` with the prefix that lifts the 260-character limit, which every call here
// passes so the long-path test needs nothing special.
@(private = "file")
long :: proc(path: string) -> win.wstring {
	slashed, _ := strings.replace_all(path, "/", `\`, context.temp_allocator)
	return win.utf8_to_wstring(fmt.tprintf(`\\?\%s`, slashed), context.temp_allocator)
}

@(private = "file")
make_dir :: proc(t: ^testing.T, path: string) {
	if !win.CreateDirectoryW(long(path), nil) {
		log.errorf("could not make %s: %d", path, win.GetLastError())
	}
}

@(private = "file")
create :: proc(t: ^testing.T, path: string) -> win.HANDLE {
	f := win.CreateFileW(
		long(path),
		win.GENERIC_READ | win.GENERIC_WRITE,
		0,
		nil,
		win.CREATE_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if f == win.INVALID_HANDLE_VALUE {
		log.errorf("could not create %s: %d", path, win.GetLastError())
	}
	return f
}

@(private = "file")
write_file :: proc(t: ^testing.T, path: string, size: int) {
	f := create(t, path)
	if f == win.INVALID_HANDLE_VALUE {
		return
	}
	defer win.CloseHandle(f)
	body := make([]u8, size, context.temp_allocator)
	slice.fill(body, 'x')
	written: win.DWORD
	if !win.WriteFile(f, raw_data(body), win.DWORD(size), &written, nil) {
		log.errorf("could not write %s: %d", path, win.GetLastError())
	}
}

/*
Make `path` a junction to `target`, an NT path such as \??\C:\dir or
\??\Volume{guid}\, by writing it a mount-point reparse point. Not ok, with the reason
logged, where the volume refuses it.
*/
@(private = "file")
make_junction :: proc(t: ^testing.T, path, target: string) -> bool {
	make_dir(t, path)
	d := win.CreateFileW(
		long(path),
		win.GENERIC_WRITE,
		0,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if d == win.INVALID_HANDLE_VALUE {
		log.errorf("could not open %s: %d", path, win.GetLastError())
		return false
	}
	defer win.CloseHandle(d)

	substitute := win.utf8_to_wstring(target, context.temp_allocator)
	units := len(string16(substitute))
	// The substitute name and the print name, each terminated; the print name is
	// left empty.
	names := u16((units + 1 + 1) * size_of(u16))
	buf: [1024]u32
	raw := ([^]u8)(&buf)
	rdb := (^win.REPARSE_DATA_BUFFER)(raw)
	rdb.ReparseTag = win.IO_REPARSE_TAG_MOUNT_POINT
	mp := (^win.MOUNT_POINT_REPARSE_BUFFER)(&raw[size_of(win.REPARSE_DATA_BUFFER)])
	mp.SubstituteNameOffset = 0
	mp.SubstituteNameLength = u16(units * size_of(u16))
	mp.PrintNameOffset = u16((units + 1) * size_of(u16))
	mp.PrintNameLength = 0
	path_buffer := ([^]u16)(&mp.PathBuffer)
	copy(path_buffer[:units], ([^]u16)(substitute)[:units])
	path_buffer[units] = 0
	path_buffer[units + 1] = 0
	data := u16(offset_of(win.MOUNT_POINT_REPARSE_BUFFER, PathBuffer)) + names
	rdb.ReparseDataLength = data
	total := win.DWORD(size_of(win.REPARSE_DATA_BUFFER)) + win.DWORD(data)
	returned: win.DWORD
	if !win.DeviceIoControl(d, win.FSCTL_SET_REPARSE_POINT, &buf, total, nil, 0, &returned, nil) {
		log.warnf("could not make %s a junction to %s: %d", path, target, win.GetLastError())
		return false
	}
	return true
}

// The volume `path` is on, as \\?\Volume{guid}\.
@(private = "file")
volume_of_path :: proc(path: string) -> (string, bool) {
	mount: [512]u16
	if !GetVolumePathNameW(
		win.utf8_to_wstring(path, context.temp_allocator),
		&mount[0],
		len(mount),
	) {
		return "", false
	}
	volume: [64]u16
	if !GetVolumeNameForVolumeMountPointW(win.wstring(&mount[0]), &volume[0], len(volume)) {
		return "", false
	}
	name, err := win.wstring_to_utf8(win.wstring(&volume[0]), -1, context.temp_allocator)
	return name, err == nil && strings.has_prefix(name, `\\?\Volume{`)
}

/*
Delete `path` and everything under it, never through a reparse point: a junction or
a symlink is removed itself, and what it names is left alone. core:os's remove_all
hands the work to SHFileOperationW, which promises neither that nor paths past 260
characters, and one of these trees holds a junction to the whole drive.
*/
@(private = "file")
remove_tree :: proc(path: string) {
	attributes := win.GetFileAttributesW(long(path))
	if attributes == win.INVALID_FILE_ATTRIBUTES {
		return
	}
	if attributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 {
		win.DeleteFileW(long(path))
		return
	}
	if attributes & win.FILE_ATTRIBUTE_REPARSE_POINT == 0 {
		found: win.WIN32_FIND_DATAW
		h := win.FindFirstFileW(long(join_path(path, "*")), &found)
		if h != win.INVALID_HANDLE_VALUE {
			for {
				name, _ := win.wstring_to_utf8(win.wstring(&found.cFileName[0]), -1)
				if name != "." && name != ".." {
					remove_tree(join_path(path, name))
				}
				if !win.FindNextFileW(h, &found) {
					break
				}
			}
			win.FindClose(h)
		}
	}
	win.RemoveDirectoryW(long(path))
}

@(private = "file")
FSCTL_SET_SPARSE :: 0x000900c4
@(private = "file")
FSCTL_SET_COMPRESSION :: 0x0009c040
@(private = "file")
COMPRESSION_FORMAT_DEFAULT :: 1

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	GetVolumePathNameW                :: proc(file_name: win.wstring, mount: [^]u16, length: win.DWORD) -> win.BOOL ---
	GetVolumeNameForVolumeMountPointW :: proc(mount: win.wstring, volume: [^]u16, length: win.DWORD) -> win.BOOL ---
}
