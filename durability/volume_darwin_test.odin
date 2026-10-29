#+build darwin
package durability

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import jm_path "jm:path"
import "jm:sqlite3"

import "../gui/files"
import "../history"
import "../scan"
import "../settings"
import "../survey"
import "../walk"

// A fixed image bounds both the filesystem being filled and the host storage
// it can consume. No root access, host volume changes, or fault seams are used.
@(private = "file")
APFS_IMAGE_BYTES :: 128 * 1024 * 1024
@(private = "file")
APFS_FIRST :: "preserve this file through full and read-only volumes\n"
@(private = "file")
APFS_SECOND :: "and preserve this nested file too\n"

@(private = "file")
Apfs_Volume :: struct {
	base, image, mount, device: string,
}

// Real ENOSPC must not hide existing settings or history, lose data, or make
// a scan fail. A read-only reattachment must read the same data and reject
// both writes and deletion. Freeing space and reattaching writable recover.
@(test)
a_full_and_read_only_apfs_volume_preserves_existing_data :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	v: Apfs_Volume
	defer apfs_cleanup(t, &v)
	if !apfs_create(t, &v) || !apfs_seed(t, v) {
		return
	}
	apfs_expect_scan(t, v, "before")
	before_total, before_free, known := scan.space(v.mount)
	if !testing.expect(t, known && before_total > 0 && before_total <= APFS_IMAGE_BYTES) {
		return
	}
	kept_settings, _ := os.read_entire_file(in_dir(v.mount, SETTINGS), context.temp_allocator)
	kept_history, _ := os.read_entire_file(in_dir(v.mount, HISTORY), context.temp_allocator)
	if !apfs_fill(t, v) {
		return
	}
	total, free, full_known := scan.space(v.mount)
	testing.expect(t, full_known && total == before_total && free < before_free)
	log.infof(
		"APFS full: total=%d available=%d, before=%d; write returned ENOSPC",
		total,
		free,
		before_free,
	)
	apfs_expect_scan(t, v, "full")
	apfs_expect_volume_scan(t, v, "full")
	apfs_expect_stores(t, v, "before", 1, "full", reject_writes = true)
	apfs_expect_bytes(t, in_dir(v.mount, SETTINGS), kept_settings, "full settings")
	apfs_expect_bytes(t, in_dir(v.mount, HISTORY), kept_history, "full history")

	// The baseline writer replaces atomically: a failed new save must not
	// destroy the old baseline while the target volume is full.
	baseline, _ := os.read_entire_file(in_dir(v.mount, BASELINE), context.temp_allocator)
	tree: scan.Tree
	if testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None) {
		defer scan.tree_destroy(&tree)
		if testing.expect_value(
			t,
			walk.read(in_dir(v.mount, TREE), &tree, {workers = 1}),
			walk.Error.None,
		) {
			testing.expect(
				t,
				!survey.baseline_save(in_dir(v.mount, BASELINE), in_dir(v.mount, TREE), &tree, {}),
			)
			apfs_expect_bytes(
				t,
				in_dir(v.mount, BASELINE),
				baseline,
				"failed full-volume baseline save",
			)
		}
	}
	if !testing.expect(t, os.remove(in_dir(v.mount, "filler")) == nil) {
		return
	}
	// statfs may publish its allocation transaction shortly after unlink.
	// Bound the wait and require capacity reporting to reflect recovery.
	recovered := false
	for _ in 0 ..< 20 {
		recovered_total, recovered_free, capacity_known := scan.space(v.mount)
		if capacity_known &&
		   recovered_total == total &&
		   recovered_free > free + APFS_IMAGE_BYTES / 4 {
			recovered = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, recovered, "removing the filler restores reported free capacity")
	if !apfs_recover(t, v, "after-full", 2) {
		return
	}
	apfs_expect_scan(t, v, "recovered from full")
	kept_settings, _ = os.read_entire_file(in_dir(v.mount, SETTINGS), context.temp_allocator)
	kept_history, _ = os.read_entire_file(in_dir(v.mount, HISTORY), context.temp_allocator)

	if !apfs_detach(t, &v) || !apfs_attach(t, &v, true) {
		return
	}
	st, stat_ok := scan.stat_fs(v.mount)
	if !testing.expect(t, stat_ok && st.flags & 1 != 0, "the image is mounted MNT_RDONLY") {
		return
	}
	apfs_expect_scan(t, v, "read-only")
	apfs_expect_volume_scan(t, v, "read-only")
	apfs_expect_stores(t, v, "after-full", 2, "read-only", reject_writes = true)
	apfs_expect_bytes(t, in_dir(v.mount, SETTINGS), kept_settings, "read-only settings")
	apfs_expect_bytes(t, in_dir(v.mount, HISTORY), kept_history, "read-only history")
	apfs_expect_read_only_io(t, v)
	failed, freed, delete_error := files.delete_tree(in_dir(v.mount, TREE))
	testing.expectf(
		t,
		delete_error != .None && failed > 0 && freed == 0,
		"read-only delete: failed=%d freed=%d error=%v",
		failed,
		freed,
		delete_error,
	)
	apfs_expect_scan(t, v, "after refused deletion")

	if apfs_detach(t, &v) && apfs_attach(t, &v, false) {
		if apfs_recover(t, v, "after-read-only", 3) {
			apfs_expect_stores(t, v, "after-read-only", 3, "writable again", reject_writes = false)
		}
		apfs_expect_scan(t, v, "writable again")
	}
}

@(private = "file")
apfs_hdiutil :: proc(v: Apfs_Volume, args: []string) -> (ok: bool, output: string) {
	// A file outside the image avoids pipe deadlocks and remains writable
	// while the fixture itself is full or mounted read-only.
	path := in_dir(v.base, "hdiutil.log")
	capture, oerr := os.open(path, {.Write, .Create, .Trunc})
	if oerr != nil {
		return false, fmt.tprintf("cannot capture hdiutil: %v", oerr)
	}
	defer os.close(capture)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "/usr/bin/hdiutil")
	append(&command, ..args)
	child, err := os.process_start({command = command[:], stdout = capture, stderr = capture})
	if err != nil {
		return false, fmt.tprintf("cannot start hdiutil: %v", err)
	}
	state, wait_error := os.process_wait(child, 45 * time.Second)
	if wait_error != nil {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child)
	}
	data, _ := os.read_entire_file(path, context.temp_allocator)
	ok = wait_error == nil && state.exited && state.exit_code == 0
	if !ok {
		log.errorf("APFS hdiutil state=%v wait=%v", state, wait_error)
	}
	return ok, string(data)
}

@(private = "file")
apfs_create :: proc(t: ^testing.T, v: ^Apfs_Volume) -> bool {
	parent := os.temp_directory(context.temp_allocator) or_else ""
	if !testing.expect(t, parent != "") {
		return false
	}
	// /var is a symlink on macOS. Native deletion refuses paths through
	// links, so use the filesystem's canonical name for every fixture path.
	info, err := os.stat(parent, context.temp_allocator)
	if !testing.expect(t, err == nil && info.fullpath != "") {
		return false
	}
	v.base, err = jm_path.make_directory_temp(
		info.fullpath,
		"leita-apfs-volume-*",
		context.temp_allocator,
	)
	if !testing.expect(t, err == nil) {
		return false
	}
	v.image = in_dir(v.base, "bounded.dmg")
	v.mount = in_dir(v.base, "mounted")
	if !testing.expect(t, os.make_directory(v.mount) == nil) {
		return false
	}
	ok, output := apfs_hdiutil(
		v^,
		{
			"create",
			"-size",
			"128m",
			"-fs",
			"APFS",
			"-type",
			"UDIF",
			"-volname",
			"leita-capacity",
			v.image,
		},
	)
	if !testing.expectf(t, ok, "APFS create: %s", output) {
		return false
	}
	return apfs_attach(t, v, false)
}

@(private = "file")
apfs_attach :: proc(t: ^testing.T, v: ^Apfs_Volume, read_only: bool) -> bool {
	args := make([dynamic]string, context.temp_allocator)
	append(
		&args,
		"attach",
		"-nobrowse",
		"-noverify",
		"-noautoopen",
		"-owners",
		"on",
		"-mountpoint",
		v.mount,
	)
	if read_only {
		append(&args, "-readonly")
	}
	append(&args, v.image)
	ok, output := apfs_hdiutil(v^, args[:])
	for line in strings.split_iterator(&output, "\n") {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) > 0 && strings.has_prefix(fields[0], "/dev/disk") {
			v.device = fields[0]
			break
		}
	}
	if !testing.expectf(t, ok && v.device != "", "APFS attach: %s", output) {
		return false
	}
	st, stat_ok := scan.stat_fs(v.mount)
	parent_st, parent_ok := scan.stat_fs(v.base)
	return testing.expectf(
		t,
		stat_ok &&
		parent_ok &&
		st.fsid != parent_st.fsid &&
		string(cstring(&st.fstypename[0])) == "apfs" &&
		string(cstring(&st.mntonname[0])) == v.mount &&
		st.blocks * u64(st.bsize) <= APFS_IMAGE_BYTES,
		"refusing a fixture outside the bounded mounted APFS image: %s",
		v.mount,
	)
}

@(private = "file")
apfs_detach :: proc(t: ^testing.T, v: ^Apfs_Volume) -> bool {
	if v.device == "" {
		return true
	}
	output: string
	for _ in 0 ..< 20 {
		ok: bool
		ok, output = apfs_hdiutil(v^, {"detach", "-force", v.device})
		if ok || !os.exists(v.device) {
			log.infof("APFS detached %s", v.device)
			v.device = ""
			return true
		}
		if !strings.contains(output, "busy") {
			break
		}
		time.sleep(250 * time.Millisecond)
	}
	return testing.expectf(t, false, "APFS detach %s: %s", v.device, output)
}

@(private = "file")
apfs_cleanup :: proc(t: ^testing.T, v: ^Apfs_Volume) {
	if v.base == "" {
		return
	}
	if v.device == "" {
		if st, mounted := scan.stat_fs(v.mount);
		   mounted && string(cstring(&st.mntonname[0])) == v.mount {
			// An interrupted attach may have mounted the image before returning
			// its whole-disk device. The native mount source is still ours.
			v.device = string(cstring(&st.mntfromname[0]))
		}
	}
	if !apfs_detach(t, v) {
		log.errorf("APFS image retained for cleanup at %s", v.image)
		return
	}
	if st, ok := scan.stat_fs(v.mount); ok && string(cstring(&st.mntonname[0])) == v.mount {
		testing.expectf(t, false, "refusing to remove a still-mounted fixture: %s", v.mount)
		return
	}
	testing.expectf(t, os.remove_all(v.base) == nil, "remove APFS fixture %s", v.base)
}

@(private = "file")
apfs_seed :: proc(t: ^testing.T, v: Apfs_Volume) -> bool {
	place := in_dir(v.mount, TREE)
	if !testing.expect(t, os.make_directory(place) == nil) ||
	   !testing.expect(t, os.make_directory(in_dir(place, "nested")) == nil) ||
	   !testing.expect(t, os.write_entire_file(in_dir(place, "first"), APFS_FIRST) == nil) ||
	   !testing.expect(
			   t,
			   os.write_entire_file(in_dir(place, "nested/second"), APFS_SECOND) == nil,
		   ) {
		return false
	}
	tree: scan.Tree
	if !testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None) {
		return false
	}
	defer scan.tree_destroy(&tree)
	if !testing.expect_value(t, walk.read(place, &tree, {workers = 1}), walk.Error.None) ||
	   !testing.expect(t, survey.baseline_save(in_dir(v.mount, BASELINE), place, &tree, {})) {
		return false
	}
	return apfs_recover(t, v, "before", 1)
}

@(private = "file")
apfs_expect_scan :: proc(t: ^testing.T, v: Apfs_Volume, phase: string) {
	tree: scan.Tree
	if !testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None) {
		return
	}
	defer scan.tree_destroy(&tree)
	if !testing.expect_value(
		t,
		walk.read(in_dir(v.mount, TREE), &tree, {workers = 1}),
		walk.Error.None,
	) {
		return
	}
	testing.expectf(
		t,
		tree.count == 4 && tree.unread == 0,
		"APFS %s: scan count=%d unread=%d",
		phase,
		tree.count,
		tree.unread,
	)
	logical, files_seen: u64
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if .Directory not_in scan.node_flags(n) {
			a, known := scan.account_of(&tree, i)
			testing.expect(t, known)
			logical += a.logical
			files_seen += 1
		}
	}
	testing.expectf(
		t,
		files_seen == 2 && logical == len(APFS_FIRST) + len(APFS_SECOND),
		"APFS %s: file count/lengths changed",
		phase,
	)
	apfs_expect_bytes(
		t,
		in_dir(v.mount, TREE + "/first"),
		transmute([]byte)string(APFS_FIRST),
		phase,
	)
	apfs_expect_bytes(
		t,
		in_dir(v.mount, TREE + "/nested/second"),
		transmute([]byte)string(APFS_SECOND),
		phase,
	)
}

// Also scan the mount itself, rather than only the seeded data subtree.
// Native private directories can legitimately be unreadable; the known files
// must still be present with correct lengths and no unread flag of their own.
@(private = "file")
apfs_expect_volume_scan :: proc(t: ^testing.T, v: Apfs_Volume, phase: string) {
	tree: scan.Tree
	if !testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None) {
		return
	}
	defer scan.tree_destroy(&tree)
	if !testing.expect_value(t, walk.read(v.mount, &tree, {workers = 1}), walk.Error.None) {
		return
	}
	found: int
	for i in 0 ..< tree.count {
		path := scan.path(&tree, i, context.temp_allocator)
		if path != in_dir(v.mount, TREE + "/first") &&
		   path != in_dir(v.mount, TREE + "/nested/second") {
			continue
		}
		n := scan.node(&tree, i)
		a, known := scan.account_of(&tree, i)
		expected := len(APFS_FIRST) if scan.name_of(&tree, i) == "first" else len(APFS_SECOND)
		testing.expectf(
			t,
			known && a.logical == u64(expected) && .Unread not_in scan.node_flags(n),
			"APFS %s: whole-volume scan changed %s",
			phase,
			path,
		)
		found += 1
	}
	testing.expectf(t, found == 2, "APFS %s: whole-volume scan missed existing files", phase)
	log.infof("APFS %s whole-volume scan: nodes=%d unread=%d", phase, tree.count, tree.unread)
}

@(private = "file")
apfs_fill :: proc(t: ^testing.T, v: Apfs_Volume) -> bool {
	st, ok := scan.stat_fs(v.mount)
	if !testing.expect(
		t,
		ok &&
		string(cstring(&st.mntonname[0])) == v.mount &&
		st.blocks * u64(st.bsize) <= APFS_IMAGE_BYTES,
	) {
		return false
	}
	mount_stat, parent_stat: posix.stat_t
	if !testing.expect(
		t,
		posix.stat(strings.clone_to_cstring(v.mount, context.temp_allocator), &mount_stat) ==
			.OK &&
		posix.stat(strings.clone_to_cstring(v.base, context.temp_allocator), &parent_stat) ==
			.OK &&
		mount_stat.st_dev != parent_stat.st_dev,
	) {
		return false
	}
	fd := posix.open(
		strings.clone_to_cstring(in_dir(v.mount, "filler"), context.temp_allocator),
		{.WRONLY, .CREAT, .TRUNC, .CLOEXEC, .NOFOLLOW},
		posix.mode_t{.IRUSR, .IWUSR},
	)
	if !testing.expect(t, fd >= 0) {
		return false
	}
	defer posix.close(fd)
	file_stat: posix.stat_t
	if !testing.expect(
		t,
		posix.fstat(fd, &file_stat) == .OK &&
		file_stat.st_dev == mount_stat.st_dev &&
		file_stat.st_dev != parent_stat.st_dev,
		"the filler descriptor belongs to the image, never the host filesystem",
	) {
		return false
	}
	chunk := make([]byte, 1024 * 1024, context.temp_allocator)
	for &b, i in chunk {
		b = byte(1 + (i * 97 + 31) % 251)
	}
	written: int
	seen_enospc := false
	for size in ([]int{1024 * 1024, 4096, 512}) {
		for written <= 2 * APFS_IMAGE_BYTES {
			n := posix.write(fd, raw_data(chunk), uint(size))
			if n < 0 {
				errno := posix.errno()
				if !testing.expectf(
					t,
					errno == .ENOSPC,
					"fill returned %v instead of ENOSPC",
					errno,
				) {
					return false
				}
				seen_enospc = true
				break
			}
			if !testing.expect(t, n > 0) {
				return false
			}
			written += int(n)
			if posix.fsync(fd) != .OK && posix.errno() != .ENOSPC {
				testing.expectf(t, false, "fill fsync: %v", posix.errno())
				return false
			}
		}
	}
	return testing.expectf(
		t,
		seen_enospc && written <= 2 * APFS_IMAGE_BYTES,
		"bounded fill did not prove ENOSPC after %d bytes",
		written,
	)
}

@(private = "file")
apfs_expect_bytes :: proc(t: ^testing.T, path: string, expected: []byte, phase: string) {
	got, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(
		t,
		err == nil && string(got) == string(expected),
		"APFS %s: existing bytes changed at %s (%v)",
		phase,
		path,
		err,
	)
}

@(private = "file")
apfs_expect_stores :: proc(
	t: ^testing.T,
	v: Apfs_Volume,
	value: string,
	snapshots: int,
	phase: string,
	reject_writes: bool,
) {
	for name in ([]string{SETTINGS, HISTORY}) {
		path := in_dir(v.mount, name)
		log.infof(
			"APFS %s %s: wal=%v shm=%v",
			phase,
			name,
			os.exists(fmt.tprintf("%s-wal", path)),
			os.exists(fmt.tprintf("%s-shm", path)),
		)
		// Preserve the exact native SQLite failure in baseline evidence.
		db, open_error := sqlite3.open(path, {read_only = true})
		if open_error == nil {
			query_error := sqlite3.exec(db, "SELECT name FROM sqlite_master")
			log.infof(
				"APFS %s %s direct read-only SQLite: open=%v read=%v",
				phase,
				name,
				open_error,
				query_error,
			)
			sqlite3.close(&db)
		} else {
			log.infof("APFS %s %s direct read-only SQLite: open=%v", phase, name, open_error)
		}
	}
	st: settings.Store
	if err := settings.open(&st, in_dir(v.mount, SETTINGS));
	   testing.expectf(t, err == nil, "APFS %s: settings must remain readable: %v", phase, err) {
		defer settings.close(&st)
		got, found := settings.get(&st, "kept", context.temp_allocator)
		testing.expect(t, found && got == value)
		testing.expect(t, integrity(st.db) == "ok")
		if reject_writes {
			err = settings.set(
				&st,
				"kept",
				strings.repeat("must-not-stick-", 512 * 1024, context.temp_allocator),
			)
			fault, failed := err.(sqlite3.Fault)
			testing.expectf(
				t,
				failed &&
				(fault.code == .Read_Only ||
						fault.code == .Full ||
						fault.code == .Io ||
						fault.code == .Cant_Open),
				"APFS %s: growing settings mutation must fail: %v",
				phase,
				err,
			)
		}
	}
	h: history.Store
	if err := history.open(&h, in_dir(v.mount, HISTORY));
	   testing.expectf(t, err == nil, "APFS %s: history must remain readable: %v", phase, err) {
		defer history.close(&h)
		rows, list_error := history.list(&h, in_dir(v.mount, TREE))
		testing.expect(
			t,
			list_error == nil && len(rows) == snapshots && rows[0].taken == i64(snapshots),
		)
		testing.expect(t, integrity(h.db) == "ok")
		if list_error == nil && len(rows) > 0 {
			entries, load_error := history.load(&h, rows[0].id, context.temp_allocator)
			testing.expectf(
				t,
				load_error == nil &&
				len(entries) == 2 &&
				entries[""] == 1 &&
				entries["dir-1/file-1"] == 1,
				"APFS %s: stored snapshot entries changed",
				phase,
			)
		}
		if reject_writes {
			growth := make([]history.Entry, 8192, context.temp_allocator)
			long_name := strings.repeat("grow", 256, context.temp_allocator)
			for &entry, i in growth {
				entry = {fmt.tprintf("%d/%s", i, long_name), u64(i)}
			}
			_, err = history.save(&h, in_dir(v.mount, TREE), 99, 99, u64(len(growth)), growth)
			fault, failed := err.(sqlite3.Fault)
			testing.expectf(
				t,
				failed &&
				(fault.code == .Read_Only ||
						fault.code == .Full ||
						fault.code == .Io ||
						fault.code == .Cant_Open),
				"APFS %s: growing history mutation must fail: %v",
				phase,
				err,
			)
		}
	}
}

@(private = "file")
apfs_recover :: proc(t: ^testing.T, v: Apfs_Volume, value: string, taken: i64) -> bool {
	st: settings.Store
	if err := settings.open(&st, in_dir(v.mount, SETTINGS));
	   !testing.expectf(t, err == nil, "APFS recovery settings: %v", err) {
		return false
	}
	defer settings.close(&st)
	if err := settings.set(&st, "kept", value);
	   !testing.expectf(t, err == nil, "APFS recovered settings write: %v", err) {
		return false
	}
	h: history.Store
	if err := history.open(&h, in_dir(v.mount, HISTORY));
	   !testing.expectf(t, err == nil, "APFS recovery history: %v", err) {
		return false
	}
	defer history.close(&h)
	_, err := history.save(&h, in_dir(v.mount, TREE), taken, 123, 2, entries_of(1))
	return testing.expectf(t, err == nil, "APFS recovered history write: %v", err)
}

@(private = "file")
apfs_expect_read_only_io :: proc(t: ^testing.T, v: Apfs_Volume) {
	path := strings.clone_to_cstring(in_dir(v.mount, TREE + "/first"), context.temp_allocator)
	fd := posix.open(path, {.WRONLY, .CLOEXEC})
	testing.expectf(
		t,
		fd < 0 && posix.errno() == .EROFS,
		"read-only open-for-write: fd=%d errno=%v",
		fd,
		posix.errno(),
	)
	if fd >= 0 {
		posix.close(fd)
	}
	testing.expect(
		t,
		posix.unlink(path) != .OK && posix.errno() == .EROFS,
		"read-only unlink must fail with EROFS",
	)
}
