#+build linux
package durability

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"

import "../gui/files"
import "../history"
import "../licence"
import "../report"
import "../scan"
import "../settings"
import "../survey"
import "../walk"
import "../testtmp"

/*
Real volumes that are full or read-only, not the seam's word for it: a tmpfs of a
fixed size, and as root an ext4 image on a loop device, each mounted at a directory
of its own. Mounting needs root or a user namespace (tools/in-namespace); without
either these tests are skipped, unless ENV_MUST says they must run.
*/

Kind :: enum {
	Tmpfs,
	Ext4, // root only: mkfs.ext4 and a loop device
}

// ENV_MUST says the volume tests must run; ENV_EXT4 that they may make ext4 images,
// as root with a loop device.
ENV_MUST :: "LEITA_VOLUME_TEST"
ENV_EXT4 :: "LEITA_VOLUME_EXT4"

// IMAGE_SIZE is how large the ext4 image is, and the tmpfs.
IMAGE_SIZE :: "8m"

@(private = "file")
Volume :: struct {
	kind:  Kind,
	dir:   string, // where it is mounted
	image: string, // the ext4 image, "" for a tmpfs
}

@(private = "file")
c :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// mount_volume mounts a fresh volume of kind, or says why it cannot.
@(private = "file")
mount_volume :: proc(t: ^testing.T, kind: Kind) -> (v: Volume, why: string) {
	v.kind = kind
	base := workdir_for(t, fmt.tprintf("volume-%v", kind))
	v.dir = in_dir(base, "mnt")
	if os.make_directory(v.dir) != nil {
		return v, "no mount point"
	}
	switch kind {
	case .Tmpfs:
		if err := linux.mount("tmpfs", c(v.dir), "tmpfs", {}, rawptr(c("size=" + IMAGE_SIZE))); err != .NONE {
			return v, fmt.tprintf("a tmpfs would not mount: %v", err)
		}
	case .Ext4:
		if os.get_env(ENV_EXT4, context.temp_allocator) == "" {
			return v, "an ext4 image needs root and a loop device; " + ENV_EXT4 + " says there are both"
		}
		v.image = in_dir(base, "image")
		steps := [][]string {
			{"truncate", "-s", IMAGE_SIZE, v.image},
			{"mkfs.ext4", "-q", "-F", v.image},
			{"mount", "-o", "loop", v.image, v.dir},
		}
		for step in steps {
			state, _, said, err := os.process_exec({command = step}, context.temp_allocator)
			if err != nil || !state.success {
				return v, fmt.tprintf("%s failed: %v %s", step[0], err, said)
			}
		}
	}
	return v, ""
}

@(private = "file")
unmount_volume :: proc(v: Volume) {
	linux.umount2(c(v.dir), {.MNT_DETACH})
	os.remove_all(os.dir(v.dir))
}

/*
make_read_only remounts v read-only, and whether it went. A file still open to write on
it makes it busy, and one was in 1 of 6 runs here just after the stores closed
(2026-10-25, cause not found), so a busy volume is asked again for up to 5 s.
*/
@(private = "file")
make_read_only :: proc(t: ^testing.T, v: Volume) -> bool {
	err: linux.Errno
	for _ in 0 ..< 50 {
		err = linux.mount(nil, c(v.dir), nil, {.REMOUNT, .RDONLY}, nil)
		if err != .EBUSY {
			break
		}
		time.sleep(100 * time.Millisecond)
	}
	testing.expectf(t, err == .NONE, "%v would not go read-only: %v", v.kind, err)
	return err == .NONE
}

// workdir_for is a fresh directory, outside any volume a test mounts.
@(private = "file")
workdir_for :: proc(t: ^testing.T, name: string) -> string {
	parent := os.temp_directory(context.temp_allocator) or_else "."
	dir, err := testtmp.make_dir(parent, fmt.tprintf("leita-durability-%s-*", name), context.temp_allocator)
	testing.expectf(t, err == nil, "no work directory: %v", err)
	return dir
}

// each_volume runs body on a fresh volume of each kind this process can mount.
@(private = "file")
each_volume :: proc(t: ^testing.T, body: proc(t: ^testing.T, v: Volume)) {
	for kind in Kind {
		v, why := mount_volume(t, kind)
		if why != "" {
			os.remove_all(os.dir(v.dir))
			asked := ENV_EXT4 if kind == .Ext4 else ENV_MUST
			if os.get_env(asked, context.temp_allocator) != "" {
				testing.fail_now(t, fmt.tprintf("%s is set, but %s", asked, why))
			}
			log.warnf("%v skipped: %s", kind, why)
			continue
		}
		body(t, v)
		unmount_volume(v)
	}
}

// fill writes a file on the volume at dir until the volume is full, and whether it
// filled.
@(private = "file")
fill :: proc(dir: string) -> bool {
	f, err := os.open(in_dir(dir, "filler"), {.Write, .Create, .Trunc})
	if err != nil {
		return false
	}
	defer os.close(f)

	for size := 64 * 1024; size >= 512; size /= 8 {
		chunk := make([]byte, size, context.temp_allocator)
		for {
			if _, werr := os.write(f, chunk); werr != nil {
				break
			}
		}
	}
	return true
}

// keep_all keeps each store and file in dir, as the next test expects them.
@(private = "file")
keep_all :: proc(t: ^testing.T, dir: string) {
	// The stores make their errors in the allocator they were opened in.
	context.allocator = context.temp_allocator
	testing.expect_value(t, licence.save(in_dir(dir, LICENCE), LINE_BEFORE), licence.Error.None)
	testing.expect(t, os.write_entire_file(in_dir(dir, REPORT), REPORT_BEFORE) == nil)
	setup_selection(t, dir)

	place := in_dir(dir, TREE)
	testing.expect(t, os.make_directory(place) == nil)
	testing.expect(t, os.write_entire_file(in_dir(place, "a"), "a") == nil)
	tree: scan.Tree
	defer scan.tree_destroy(&tree)

	testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
	testing.expect_value(t, walk.read(place, &tree, walk.Config{workers = 2}), walk.Error.None)
	testing.expect(t, survey.baseline_save(in_dir(dir, BASELINE), place, &tree, {}))

	st: settings.Store
	testing.expect(t, settings.open(&st, in_dir(dir, SETTINGS)) == nil)
	testing.expect(t, settings.set(&st, "kept", "before") == nil)
	settings.close(&st)

	h: history.Store
	testing.expect(t, history.open(&h, in_dir(dir, HISTORY)) == nil)
	_, herr := history.save(&h, place_of(1), 1, 1, 1, entries_of(1))
	testing.expect(t, herr == nil)
	history.close(&h)
}

// expect_kept checks that each store and file keep_all kept reads as it was kept.
@(private = "file")
expect_kept :: proc(t: ^testing.T, v: Volume, after: string) {
	// The stores make their errors in the allocator they were opened in.
	context.allocator = context.temp_allocator
	dir := v.dir
	line, _ := os.read_entire_file(in_dir(dir, LICENCE), context.temp_allocator)
	testing.expectf(t, string(line) == LINE_BEFORE + "\n", "%v %s: the licence holds %q", v.kind, after, line)
	got, _ := os.read_entire_file(in_dir(dir, REPORT), context.temp_allocator)
	testing.expectf(t, string(got) == REPORT_BEFORE, "%v %s: the report holds %q", v.kind, after, got)
	expect_whole(t, dir, in_dir(dir, SELECTION), 0)

	tree: scan.Tree
	defer scan.tree_destroy(&tree)

	_, why, ok := survey.baseline_load(in_dir(dir, BASELINE), in_dir(dir, TREE), &tree)
	testing.expectf(t, ok, "%v %s: the baseline does not load: %s", v.kind, after, why)

	st: settings.Store
	if err := settings.open(&st, in_dir(dir, SETTINGS)); err != nil {
		// Reported, not read: card 760 is to read it.
		log.infof("%v %s: settings do not open: %s", v.kind, after, history.describe(err))
	} else {
		value, found := settings.get(&st, "kept", context.temp_allocator)
		testing.expectf(t, found && value == "before", "%v %s: the setting is lost", v.kind, after)
		testing.expectf(t, integrity(st.db) == "ok", "%v %s: the settings store is damaged", v.kind, after)
		settings.close(&st)
	}

	h: history.Store
	if err := history.open(&h, in_dir(dir, HISTORY)); err != nil {
		log.infof("%v %s: history does not open: %s", v.kind, after, history.describe(err))
	} else {
		snaps, _ := history.list(&h, place_of(1))
		testing.expectf(t, len(snaps) == 1, "%v %s: the scan kept is lost", v.kind, after)
		testing.expectf(t, integrity(h.db) == "ok", "%v %s: the history store is damaged", v.kind, after)
		history.close(&h)
	}
}

// try_all makes every write keep_all made once more, and says which held.
@(private = "file")
try_all :: proc(t: ^testing.T, dir: string) -> (held: [dynamic]string) {
	// The stores make their errors in the allocator they were opened in.
	context.allocator = context.temp_allocator
	held = make([dynamic]string, context.temp_allocator)
	if licence.save(in_dir(dir, LICENCE), LINE_AFTER) == .None {
		append(&held, "licence")
	}
	r := sample_report()
	if e, _ := report.save(in_dir(dir, REPORT), &r, .Json); e == .None {
		append(&held, "report")
	}

	place := in_dir(dir, TREE)
	tree: scan.Tree
	defer scan.tree_destroy(&tree)

	testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
	testing.expect_value(t, walk.read(place, &tree, walk.Config{workers = 2}), walk.Error.None)
	if survey.baseline_save(in_dir(dir, BASELINE), place, &tree, {}) {
		append(&held, "baseline")
	}

	st: settings.Store
	if settings.open(&st, in_dir(dir, SETTINGS)) == nil {
		if settings.set(&st, "kept", strings.repeat("after", 4096, context.temp_allocator)) == nil {
			append(&held, "setting")
		}
		settings.close(&st)
	}

	h: history.Store
	if history.open(&h, in_dir(dir, HISTORY)) == nil {
		if _, err := history.save(&h, place_of(1), 2, 2, 2, entries_of(4000)); err == nil {
			append(&held, "history")
		}
		history.close(&h)
	}
	return
}

/*
On a volume that is full, each write says it failed and the copy before stays: the
licence, the report and the baseline byte for byte or whole, the stores sound and
holding what they held. Once there is room again, each write holds.
*/
@(test)
a_full_volume_keeps_every_copy_before :: proc(t: ^testing.T) {
	each_volume(t, proc(t: ^testing.T, v: Volume) {
		keep_all(t, v.dir)
		testing.expectf(t, fill(v.dir), "%v did not fill", v.kind)
		held := try_all(t, v.dir)
		for name in held {
			// A store may still have room in pages it holds already.
			if name != "setting" && name != "history" {
				testing.expectf(t, false, "%v full: the %s save said it held", v.kind, name)
			}
		}
		expect_kept(t, v, "full")

		testing.expect(t, os.remove(in_dir(v.dir, "filler")) == nil)
		again := try_all(t, v.dir)
		testing.expectf(t, len(again) == 5, "%v with room again: only %v held", v.kind, again[:])
	})
}

/*
On a volume that is read-only, every store reads, or says it cannot be opened, and
none is lost; each write says it failed; a delete takes nothing and says so. The
Trash is not tried here: one on this volume is the seam's Read_Only, in gui/files.
*/
@(test)
a_read_only_volume_reads_every_store_and_deletes_nothing :: proc(t: ^testing.T) {
	each_volume(t, proc(t: ^testing.T, v: Volume) {
		keep_all(t, v.dir)
		if !make_read_only(t, v) {
			return
		}
		held := try_all(t, v.dir)
		testing.expectf(t, len(held) == 0, "%v read-only: %v held", v.kind, held[:])
		expect_kept(t, v, "read-only")

		failed, freed, err := files.delete_tree(in_dir(v.dir, SELECTION))
		testing.expectf(t, err != .None && failed > 0, "%v read-only: the delete said %v, %d left", v.kind, err, failed)
		testing.expectf(t, freed == 0, "%v read-only: the delete freed %d", v.kind, freed)
		expect_whole(t, v.dir, in_dir(v.dir, SELECTION), 0)
	})
}
