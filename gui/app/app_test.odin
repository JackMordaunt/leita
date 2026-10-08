package sonar_app

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:ui"
import bl "jm:ui/blend2d"
import "jm:ui/ops"
import "jm:ui/render"

import "../query"
import "../view"

// The whole application, less the window: the view runs in a probe, the probe's
// needs and commands go to the host as the frame loop would send them, and the
// host's answers are drained into the probe before the next frame. Everything
// between is the real pipeline, desk and reader on their real threads, over a
// real directory.

@(private = "file")
Rig :: struct {
	h:        Host,
	m:        view.Model,
	// The probe, as p, with a renderer and the window's fonts beside it, so a
	// test can look at pixels as well as tags.
	using hl: render.Headless,
	data:     ui.Data_Host,
	needs:    ui.Subscriptions,
}

@(private = "file")
rig_open :: proc(r: ^Rig, path: string) {
	init(&r.h, path)
	r.data = data_host(&r.h)
	view.model_init(&r.m, path)
	ui.subscriptions_init(&r.needs)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&r.hl, view.view, &r.m, {1100, 700}, fonts)
	hand_on(r)
}

@(private = "file")
rig_close :: proc(r: ^Rig) {
	render.headless_destroy(&r.hl)
	ui.subscriptions_destroy(&r.needs)
	view.model_destroy(&r.m)
	stop(&r.h)
}

// hand_on does what the frame loop does after a frame: the need diff and the
// commands go to the host.
@(private = "file")
hand_on :: proc(r: ^Rig) {
	ui.data_after_frame(&r.data, &r.needs, &r.p.router)
}

// settle drains the host's answers into the probe and runs a frame, until a
// frame finds the name tagged (or not), or the deadline passes. A finished scan
// sends nothing more, so the frame already drawn is looked at first.
@(private = "file")
settle :: proc(r: ^Rig, name: string, present := true) -> bool {
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for time.tick_now()._nsec < deadline {
		if ui.probe_tagged(&r.p, name) == present {
			return true
		}
		if ui.inbox_pending(&r.h.inbox) {
			ui.inbox_drain(&r.h.inbox, &r.p.layout)
			ui.probe_frame(&r.p)
			hand_on(r)
			if ui.probe_tagged(&r.p, name) == present {
				return true
			}
		}
		time.sleep(time.Millisecond)
	}
	return false
}

// open_row clicks a directory's name in the listing. The probe gives a row's
// button the bounds of the whole row, whose centre is on the share bar, so this
// clicks near the row's start, where the name is.
@(private = "file")
open_row :: proc(r: ^Rig, name: string, button := ui.Button.Left) {
	b := ui.probe_bounds(&r.p, name)
	ui.probe_click_at(&r.p, {b.x + 24, b.y + b.h / 2}, button)
	ui.probe_frame(&r.p)
	hand_on(r)
}

// trash_env is held by a test that points XDG_DATA_HOME at a Trash of its own:
// the environment is the process's, and the runner runs tests side by side.
@(private = "file")
trash_env: sync.Mutex

/*
A directory to scan, made fresh:

	<root>/photos/big.raw    256 KiB
	<root>/photos/small.jpg  8 KiB
	<root>/notes.txt         4 KiB
*/
@(private = "file")
fixture :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/sonar_gui_%s", dir, name)
	os.remove_all(root)

	write :: proc(t: ^testing.T, path: string, size: int) {
		body := make([]byte, size, context.temp_allocator)
		slice.fill(body, 'x')
		testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
	}
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(
		t,
		os.make_directory(fmt.tprintf("%s/photos", root)) == nil,
		"could not make photos",
	)
	write(t, fmt.tprintf("%s/photos/big.raw", root), 256 * 1024)
	write(t, fmt.tprintf("%s/photos/small.jpg", root), 8 * 1024)
	write(t, fmt.tprintf("%s/notes.txt", root), 4 * 1024)
	return root
}

@(test)
a_scan_streams_into_the_window_and_a_directory_opens :: proc(t: ^testing.T) {
	root := fixture(t, "browse")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)

	// The scan runs to the end, and the listing of the top shows both entries,
	// the directory first because it holds more.
	testing.expect(t, settle(&r, "Done"), "the scan finished")
	testing.expect(t, settle(&r, "photos"), "the directory is listed")
	testing.expect(t, ui.probe_tagged(&r.p, "notes.txt"), "the file is listed")
	testing.expect(t, ui.probe_tagged(&r.p, "big.raw"), "the largest file is ranked")
	testing.expect(t, r.h.desk.scan.state == .Done)
	testing.expect(t, r.h.desk.scan.disk_total > 0, "the disk it is on was measured")
	testing.expect(t, r.h.desk.scan.disk_free <= r.h.desk.scan.disk_total)

	// Opening the directory is a new need; the desk answers it at once.
	open_row(&r, "photos")
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"), "the directory's contents are listed")
	testing.expect(t, ui.probe_tagged(&r.p, "arc big.raw"), "the sunburst followed")
}

@(test)
a_rescan_starts_over_at_the_top :: proc(t: ^testing.T) {
	root := fixture(t, "rescan")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)

	testing.expect(t, settle(&r, "photos"))
	open_row(&r, "photos")
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"), "photos is open")
	first := r.m.generation

	// Scanning again renumbers the tree, so the view goes back to the top.
	testing.expect(t, ui.probe_click(&r.p, "Scan"))
	hand_on(&r)
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"), "the top is listed again")
	testing.expect(t, r.m.generation > first, "a new generation")
}

@(test)
a_path_that_is_not_there_fails_with_a_reason :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r, "/nonexistent/sonar/path")
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Failed"), "the failure is shown")
	testing.expect(
		t,
		ui.probe_tagged(&r.p, "cannot scan /nonexistent/sonar/path: Target_Not_Found"),
		"the reason is shown",
	)
}

@(test)
a_click_on_an_arc_opens_it_and_the_hub_goes_back_up :: proc(t: ^testing.T) {
	root := fixture(t, "rings")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)

	// The first ring holds the top's two entries; photos is the larger.
	testing.expect(t, settle(&r, "Done"), "the scan finished")
	testing.expect(t, settle(&r, "arc photos"), "photos has an arc")
	testing.expect(t, ui.probe_tagged(&r.p, "arc notes.txt"), "notes.txt has an arc")

	// Clicking the arc makes photos the hub: its files are the first ring now.
	// photos, the larger, sweeps from twelve o'clock round past six, so the first
	// ring straight below the hub is photos, once the arcs have grown into place.
	ui.probe_advance(&r.p, 60, 1.0 / 60)
	b := ui.probe_bounds(&r.p, "Sunburst")
	radius := b.w / 2
	ring := radius * (view.HUB + (1 - view.HUB) / (2 * query.RING_DEPTH))
	ui.probe_click_at(&r.p, {b.x + b.w / 2, b.y + b.h / 2 + ring})
	ui.probe_frame(&r.p)
	hand_on(&r)
	testing.expect(t, settle(&r, "arc big.raw"), "photos opened")
	testing.expect(t, ui.probe_tagged(&r.p, "264.0 KiB in 2 items"), "the listing followed")

	// The hub goes back up to the top.
	testing.expect(t, ui.probe_click(&r.p, "hub"))
	ui.probe_frame(&r.p)
	hand_on(&r)
	testing.expect(t, settle(&r, "arc photos"), "back at the top")
}

// ring_point is the point in the sunburst's first ring at turn t, clockwise from
// twelve o'clock, in device space, once the rings have grown into place.
@(private = "file")
ring_point :: proc(r: ^Rig, t: f32) -> ops.Point {
	// The arcs grow into place; a second of frames lets them arrive.
	ui.probe_advance(&r.p, 60, 1.0 / 60)
	b := ui.probe_bounds(&r.p, "Sunburst")
	radius := b.w / 2
	dist := radius * (view.HUB + (1 - view.HUB) / (2 * query.RING_DEPTH))
	a := t * math.TAU - math.PI / 2
	return {b.x + b.w / 2 + dist * math.cos(a), b.y + b.h / 2 + dist * math.sin(a)}
}

// press_and_hand_on hands the host what the frame a click or key ran in asked
// for, commands among it, then runs one more frame and hands on its needs: a
// frame run first would clear the commands unsent.
@(private = "file")
press_and_hand_on :: proc(r: ^Rig) {
	hand_on(r)
	ui.probe_frame(&r.p)
	hand_on(r)
}

@(test)
the_back_and_forward_buttons_walk_the_directories_opened :: proc(t: ^testing.T) {
	root := fixture(t, "history")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)

	testing.expect(t, settle(&r, "arc photos"))
	ui.probe_click_at(&r.p, ring_point(&r, 0.5))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "arc big.raw"), "photos opened")

	ui.probe_key(&r.p, .Browser_Back)
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "arc photos"), "back at the top")

	ui.probe_key(&r.p, .Browser_Forward)
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "arc big.raw"), "forward into photos again")
}

@(test)
a_right_click_renames_an_entry_on_disk_and_in_the_rings :: proc(t: ^testing.T) {
	root := fixture(t, "rename")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)

	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	ui.probe_click_at(&r.p, ring_point(&r, 0.5), .Right)
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Rename"), "the menu offers Rename")
	press_and_hand_on(&r)
	press_and_hand_on(&r)

	// The field opens holding the old name, selected, so typing replaces it.
	testing.expect_value(t, ui.probe_focus_name(&r.p), "New name")
	ui.probe_type(&r.p, "pictures")
	ui.probe_key(&r.p, .Enter)
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "Renamed photos to pictures"), "the notice says so")
	testing.expect(t, settle(&r, "arc pictures"), "the arc took the new name")
	testing.expect(t, os.exists(fmt.tprintf("%s/pictures/big.raw", root)), "renamed on disk")
	testing.expect(t, !os.exists(fmt.tprintf("%s/photos", root)))
}

@(test)
a_right_click_moves_an_entry_to_the_trash_and_out_of_the_totals :: proc(t: ^testing.T) {
	root := fixture(t, "trash")
	defer os.remove_all(root)
	// The Trash is the test's own, beside the fixture, never the user's.
	data := fmt.tprintf("%s-data", root)
	os.remove_all(data)
	defer os.remove_all(data)
	sync.guard(&trash_env)
	testing.expect(t, os.set_env("XDG_DATA_HOME", data) == nil)
	defer os.unset_env("XDG_DATA_HOME")

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)

	// notes.txt is the smaller entry, the last stretch of the ring before twelve.
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc notes.txt"))
	ui.probe_click_at(&r.p, ring_point(&r, 0.9925), .Right)
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the menu offers the Trash")
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the dialog asks first")
	press_and_hand_on(&r)

	testing.expect(t, settle(&r, "Moved notes.txt to the Trash"), "the notice says so")
	testing.expect(t, settle(&r, "arc notes.txt", present = false), "its arc is gone")
	testing.expect(t, settle(&r, "264.0 KiB in 1 items"), "the totals dropped")
	testing.expect(t, !os.exists(fmt.tprintf("%s/notes.txt", root)), "gone from the folder")
	testing.expect(t, os.exists(fmt.tprintf("%s/Trash/files/notes.txt", data)), "in the Trash")
	testing.expect(t, os.exists(fmt.tprintf("%s/Trash/info/notes.txt.trashinfo", data)))
}

@(test)
a_right_click_on_a_contents_row_trashes_it :: proc(t: ^testing.T) {
	root := fixture(t, "rowtrash")
	defer os.remove_all(root)
	data := fmt.tprintf("%s-data", root)
	os.remove_all(data)
	defer os.remove_all(data)
	sync.guard(&trash_env)
	testing.expect(t, os.set_env("XDG_DATA_HOME", data) == nil)
	defer os.unset_env("XDG_DATA_HOME")

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"))

	open_row(&r, "notes.txt", .Right)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the row's menu offers Trash")
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the dialog asks first")
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "264.0 KiB in 1 items"), "the row is gone from the totals")
	testing.expect(t, os.exists(fmt.tprintf("%s/Trash/files/notes.txt", data)), "in the Trash")
}

@(test)
a_right_click_on_a_largest_file_renames_it :: proc(t: ^testing.T) {
	root := fixture(t, "rowrename")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "big.raw"))

	// At the top, big.raw is in no list but the largest files.
	open_row(&r, "big.raw", .Right)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Rename"), "the row's menu offers Rename")
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	ui.probe_type(&r.p, "huge.raw")
	ui.probe_key(&r.p, .Enter)
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "Renamed big.raw to huge.raw"), "the notice says so")
	testing.expect(t, settle(&r, "huge.raw"), "the list took the new name")
	testing.expect(t, os.exists(fmt.tprintf("%s/photos/huge.raw", root)), "renamed on disk")
}

@(test)
a_largest_files_name_opens_its_folder :: proc(t: ^testing.T) {
	root := fixture(t, "rowopen")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "big.raw"))
	open_row(&r, "big.raw")
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"), "photos opened")
}

@(test)
a_long_name_stops_short_of_its_share_bar :: proc(t: ^testing.T) {
	root := fixture(t, "longname")
	defer os.remove_all(root)
	long := "a_name_far_too_long_to_fit_beside_its_share_bar_in_the_contents_list.bin"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, long), "x") == nil)

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, long))

	// The name's label is as wide as it is, but clipped to its cell: just above the
	// bar, where a name running on would draw its letters, there is only the
	// background.
	bar := ui.probe_bounds(&r.p, fmt.tprintf("%s share", long))
	img: bl.ImageCore
	bl.image_init(&img)
	defer bl.image_destroy(&img)
	testing.expect(t, bl.image_create(&img, 1100, 700, .PRGB32) == 0)
	render.render(&r.r, ui.probe_current(&r.p), &img, r.clear)
	data: bl.ImageData
	testing.expect(t, bl.image_get_data(&img, &data) == 0)
	// inked counts the pixels other than the background in a strip of the rows just
	// above the bar, from x0 to x1.
	inked :: proc(data: bl.ImageData, bar: ops.Rect, x0, x1: f32) -> (n: int) {
		for y in int(bar.y) - 7 ..< int(bar.y) {
			line := ([^]u32)(rawptr(uintptr(data.pixel_data) + uintptr(y * int(data.stride))))
			for x in int(x0) ..< int(x1) {
				if line[x] != 0xFFFFFFFF {
					n += 1
				}
			}
		}
		return
	}
	// The name is drawn where it fits, so a strip with nothing in it means clipped,
	// not a frame that drew nothing.
	testing.expect(
		t,
		inked(data, bar, bar.x - 200, bar.x - 60) > 0,
		"the name is drawn before the bar",
	)
	over := inked(data, bar, bar.x, bar.x + bar.w)
	testing.expectf(t, over == 0, "%d pixels over the bar are not background", over)
}

@(test)
the_grips_share_the_window_and_fold_the_side_column_away :: proc(t: ^testing.T) {
	root := fixture(t, "grips")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "Contents"))
	ui.probe_advance(&r.p, 30, 1.0 / 60)
	contents := ui.probe_bounds(&r.p, "Contents")

	// Dragged right past SIDE_FOLD, the column folds away and the grip stays.
	testing.expect(t, ui.probe_drag(&r.p, "Resize panels", 300, 0))
	ui.probe_advance(&r.p, 30, 1.0 / 60)
	testing.expect(t, !ui.probe_tagged(&r.p, "Contents"), "the column folded away")
	testing.expect(t, ui.probe_tagged(&r.p, "Resize panels"), "the grip stays to bring it back")

	// Dragged back out, it returns at the width the drag ends at.
	testing.expect(t, ui.probe_drag(&r.p, "Resize panels", -500, 0))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "Contents"), "the column came back")
	wider := ui.probe_bounds(&r.p, "Contents")
	testing.expectf(
		t,
		wider.x < contents.x - 50,
		"the column is wider: Contents at %v, was %v",
		wider.x,
		contents.x,
	)

	// The grip between the lists gives the contents more of the column.
	largest := ui.probe_bounds(&r.p, "Largest files")
	testing.expect(t, ui.probe_drag(&r.p, "Resize lists", 0, 80))
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	lower := ui.probe_bounds(&r.p, "Largest files")
	testing.expectf(
		t,
		lower.y > largest.y + 40,
		"the largest files moved down from %v to %v",
		largest.y,
		lower.y,
	)

	// A double click folds the column, and another brings it back.
	testing.expect(t, ui.probe_click(&r.p, "Resize panels", clicks = 2))
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	testing.expect(t, !ui.probe_tagged(&r.p, "Contents"), "a double click folds it")
	testing.expect(t, ui.probe_click(&r.p, "Resize panels", clicks = 2))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "Contents"), "and another unfolds it")
}

@(test)
the_sunburst_sits_in_the_middle_of_its_room :: proc(t: ^testing.T) {
	root := fixture(t, "centre")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	caption := fmt.tprintf("%s · 268.0 KiB", root)

	// The disc's room runs from under the caption, past the column's 8 point gap,
	// to the window's margin, and across from the window's margin to the grip.
	// Wide, the disc is held by its height and has as much room left as right;
	// tall, by its width, with as much above as below.
	for size in ([]ops.Size{{1100, 700}, {760, 1100}}) {
		r.p.size = size
		ui.probe_advance(&r.p, 60, 1.0 / 60)
		disc := ui.probe_bounds(&r.p, "Sunburst")
		grip := ui.probe_bounds(&r.p, "Resize panels")
		said := ui.probe_bounds(&r.p, caption)
		left, right := disc.x - view.PAD, grip.x - (disc.x + disc.w)
		above, below := disc.y - (said.y + said.h + 8), size.y - view.PAD - (disc.y + disc.h)
		testing.expectf(
			t,
			abs(left - right) < 2,
			"at %v, %v left of the disc and %v right",
			size,
			left,
			right,
		)
		testing.expectf(
			t,
			abs(above - below) < 2,
			"at %v, %v above the disc and %v below",
			size,
			above,
			below,
		)
	}
}
