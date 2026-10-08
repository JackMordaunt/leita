package sonar_app

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:stream"

import "jm:ui"
import bl "jm:ui/blend2d"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../command"
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
	testing.expect(t, settle(&r, "notes.txt"), "the file is listed")
	testing.expect(t, settle(&r, "big.raw"), "the largest file is ranked")
	testing.expect(t, r.h.desk.scan.state == .Done)
	testing.expect(t, r.h.desk.scan.disk_total > 0, "the disk it is on was measured")
	testing.expect(t, r.h.desk.scan.disk_free <= r.h.desk.scan.disk_total)

	// Opening the directory is a new need; the desk answers it at once.
	open_row(&r, "photos")
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"), "the directory's contents are listed")
	testing.expect(t, settle(&r, "arc big.raw"), "the sunburst followed")
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
	testing.expect(t, ui.probe_click(&r.p, "Rescan"))
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
	testing.expect(t, settle(&r, "arc notes.txt"), "notes.txt has an arc")

	// Clicking the arc makes photos the hub: its files are the first ring now.
	// photos, the larger, sweeps from twelve o'clock round past six, so the first
	// ring straight below the hub is photos, once the arcs have grown into place.
	ui.probe_advance(&r.p, 60, 1.0 / 60)
	b := ui.probe_bounds(&r.p, "Sunburst chart")
	radius := b.w / 2
	ring := radius * (view.HUB + (1 - view.HUB) / (2 * query.RING_DEPTH))
	ui.probe_click_at(&r.p, {b.x + b.w / 2, b.y + b.h / 2 + ring})
	ui.probe_frame(&r.p)
	hand_on(&r)
	testing.expect(t, settle(&r, "arc big.raw"), "photos opened")
	// The listing is its own need, answered apart from the rings: wait for it too.
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"), "the listing followed")

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
	b := ui.probe_bounds(&r.p, "Sunburst chart")
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
	// The name is in the largest files as soon as they land, which can be before
	// the listing: wait for its row's bar itself.
	share := fmt.tprintf("%s share", long)
	testing.expect(t, settle(&r, share))

	// The name's label is as wide as it is, but clipped to its cell: just above the
	// bar, where a name running on would draw its letters, there is only the
	// background.
	bar := ui.probe_bounds(&r.p, share)
	if !testing.expectf(t, bar.w > 0 && bar.y >= 8, "the bar is at %v", bar) {
		return
	}
	img: bl.ImageCore
	bl.image_init(&img)
	defer bl.image_destroy(&img)
	testing.expect(t, bl.image_create(&img, 1100, 700, .PRGB32) == 0)
	render.render(&r.r, ui.probe_current(&r.p), &img, r.clear)
	data: bl.ImageData
	testing.expect(t, bl.image_get_data(&img, &data) == 0)
	// inked counts the pixels other than the background in a strip of the rows just
	// above the bar, from x0 to x1.
	// It reads only inside the image.
	inked :: proc(data: bl.ImageData, bar: ops.Rect, x0, x1: f32) -> (n: int) {
		for y in max(int(bar.y) - 7, 0) ..< min(int(bar.y), int(data.size.h)) {
			line := ([^]u32)(rawptr(uintptr(data.pixel_data) + uintptr(y * int(data.stride))))
			for x in max(int(x0), 0) ..< min(int(x1), int(data.size.w)) {
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
	// The disc's room runs from under the info block, three lines whose second is
	// the open directory's size, past the column's 8 point gap,
	// to the window's margin, and across from the window's margin to the grip.
	// Wide, the disc is held by its height and has as much room left as right;
	// tall, by its width, with as much above as below.
	for size in ([]ops.Size{{1100, 700}, {760, 1100}}) {
		r.p.size = size
		ui.probe_advance(&r.p, 60, 1.0 / 60)
		disc := ui.probe_bounds(&r.p, "Sunburst chart")
		grip := ui.probe_bounds(&r.p, "Resize panels")
		title := primer.text_style(.Medium, .Semibold).line_height + view.INFO_GAP
		block := ui.probe_bounds(&r.p, "268.0 KiB").y - title + view.info_height()
		left, right := disc.x - view.PAD, grip.x - (disc.x + disc.w)
		above, below := disc.y - (block + 8), size.y - view.PAD - (disc.y + disc.h)
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

@(test)
hovering_a_long_path_leaves_the_sunburst_where_it_is :: proc(t: ^testing.T) {
	root := fixture(t, "hover")
	defer os.remove_all(root)
	long := "a_directory_whose_name_runs_on_far_past_the_width_of_the_window_it_is_drawn_in"
	testing.expect(t, os.make_directory(fmt.tprintf("%s/%s", root, long)) == nil)
	body := make([]byte, 512 * 1024, context.temp_allocator)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s/big.bin", root, long), body) == nil)

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, fmt.tprintf("arc %s", long)))
	r.p.size = {760, 900}
	ui.probe_advance(&r.p, 60, 1.0 / 60)
	before := ui.probe_bounds(&r.p, "Sunburst chart")

	// The long directory is the largest, the first quarter of the ring from
	// twelve o'clock: hover there, and the block says so in a line it cuts.
	at := ring_point(&r, 0.1)
	ui.probe_move(&r.p, at.x, at.y)
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, long), "the block names what is hovered")
	after := ui.probe_bounds(&r.p, "Sunburst chart")
	testing.expectf(t, before == after, "the disc moved from %v to %v", before, after)
}

@(test)
the_location_bar_walks_the_path_and_scans_above_it :: proc(t: ^testing.T) {
	root := fixture(t, "bar")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	testing.expect(t, settle(&r, "sonar_gui_bar"), "the scan's top is a step")
	testing.expect(t, settle(&r, "tmp"), "and so is the directory above it")

	// Into photos and back by its step.
	ui.probe_click_at(&r.p, ring_point(&r, 0.5))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "photos"), "photos is a step now")
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"))
	testing.expect(t, ui.probe_click(&r.p, "sonar_gui_bar"))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"), "the top's step opened the top")

	// A step above the scan asks for a scan from there.
	testing.expect(t, ui.probe_click(&r.p, "tmp"))
	scanned := ""
	for c in ui.probe_commands(&r.p) {
		if cmd, ok := ui.command_as(c, command.Command); ok {
			if scan, is := cmd.(command.Scan); is {
				scan := scan
				scanned = strings.clone(command.text_of(&scan.path), context.temp_allocator)
			}
		}
	}
	testing.expect_value(t, scanned, "/tmp/")
	ui.router_commands_clear(&r.p.router)
}

@(test)
the_location_bar_edits_into_a_field_and_back :: proc(t: ^testing.T) {
	root := fixture(t, "edit")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "sonar_gui_edit"))

	// The bar's empty end opens the field, focused, holding the path.
	bar := ui.probe_bounds(&r.p, "Location")
	ui.probe_click_at(&r.p, {bar.x + bar.w - 20, bar.y + bar.h / 2})
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, r.m.editing, "the bar is a field")
	testing.expect_value(t, ui.text_string(&r.m.path), root)
	testing.expect_value(t, ui.probe_focus_name(&r.p), "Location")

	// Escape puts the steps back.
	ui.probe_key(&r.p, .Escape)
	press_and_hand_on(&r)
	testing.expect(t, !r.m.editing, "Escape closes the field")
	testing.expect(t, settle(&r, "sonar_gui_edit"))

	// Enter scans what the field holds.
	ui.probe_click_at(&r.p, {bar.x + bar.w - 20, bar.y + bar.h / 2})
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	first := r.m.generation
	ui.probe_type(&r.p, fmt.tprintf("%s/photos", root))
	ui.probe_key(&r.p, .Enter)
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"), "photos was scanned")
	testing.expect(t, r.m.generation > first, "as a new scan")
}

@(test)
a_deep_path_shows_its_deepest_steps :: proc(t: ^testing.T) {
	root := fixture(t, "deep")
	defer os.remove_all(root)
	deep := root
	for name in ([]string{"first_level_directory", "second_level_directory", "third_level_directory", "fourth_level_directory"}) {
		deep = fmt.tprintf("%s/%s", deep, name)
		testing.expect(t, os.make_directory(deep) == nil)
	}
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/leaf.bin", deep), "x") == nil)

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	r.p.size = {760, 700}
	testing.expect(t, settle(&r, "Done"))
	// Walk down to the deepest directory by the contents list.
	for name in ([]string{"first_level_directory", "second_level_directory", "third_level_directory", "fourth_level_directory"}) {
		testing.expect(t, settle(&r, name))
		open_row(&r, name)
		testing.expect(t, settle(&r, "leaf.bin" if name == "fourth_level_directory" else name))
	}
	testing.expect(t, settle(&r, "fourth_level_directory"), "the deepest is a step")
	ui.probe_advance(&r.p, 10, 1.0 / 60)

	bar := ui.probe_bounds(&r.p, "Location")
	rescan := ui.probe_bounds(&r.p, "Rescan")
	testing.expectf(
		t,
		bar.x + bar.w <= rescan.x,
		"the bar ends at %v, before the Rescan button at %v",
		bar.x + bar.w,
		rescan.x,
	)
	deepest := ui.probe_bounds(&r.p, "fourth_level_directory")
	top := ui.probe_bounds(&r.p, "tmp")
	testing.expectf(
		t,
		deepest.x + deepest.w <= bar.x + bar.w,
		"the deepest step ends at %v, inside the bar to %v",
		deepest.x + deepest.w,
		bar.x + bar.w,
	)
	testing.expectf(
		t,
		top.x < bar.x,
		"the top has scrolled off the left: tmp at %v, bar from %v",
		top.x,
		bar.x,
	)

	// A wheel's notch moves the strip as far as a scroll box moves its content,
	// back toward the top, and the strip stops following the deepest. probe_scroll
	// runs the frame the notch lands in.
	before := r.m.location_offset
	testing.expect(t, ui.probe_scroll(&r.p, "Location", -1))
	moved := before - r.m.location_offset
	testing.expectf(
		t,
		moved == min(ui.SCROLL_STEP, before),
		"one notch moved the strip %v of %v",
		moved,
		before,
	)
	testing.expect(t, !r.m.location_follow, "and it stays where it was scrolled")
}

@(test)
the_treemap_draws_the_same_directory_as_boxes :: proc(t: ^testing.T) {
	root := fixture(t, "treemap")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))

	testing.expect(t, ui.probe_click(&r.p, "Treemap"))
	press_and_hand_on(&r)
	ui.probe_advance(&r.p, 60, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, "box photos"), "photos is a box")
	testing.expect(t, ui.probe_tagged(&r.p, "box notes.txt"), "and so is notes.txt")
	testing.expect(t, !ui.probe_tagged(&r.p, "Sunburst chart"), "the sunburst is put away")

	// photos holds 264 of the 268 KiB, so its box takes nearly all the room.
	room := ui.probe_bounds(&r.p, "Treemap chart")
	photos := ui.probe_bounds(&r.p, "box photos")
	share := (photos.w * photos.h) / (room.w * room.h)
	testing.expectf(t, share > 0.95 && share < 0.99, "photos takes %v of the room", share)

	// The entry menu, and a click on a directory's box opens it.
	ui.probe_click_at(&r.p, {photos.x + photos.w / 2, photos.y + photos.h / 2}, .Right)
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_tagged(&r.p, "Rename"), "the box has the entry menu")
	ui.probe_key(&r.p, .Escape)
	press_and_hand_on(&r)
	ui.probe_click_at(&r.p, {photos.x + photos.w / 2, photos.y + photos.h / 2})
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"), "photos opened")
	testing.expect(t, settle(&r, "box big.raw"), "and shows its files as boxes")
}

@(test)
hovering_a_contents_row_lights_its_arc_and_its_box :: proc(t: ^testing.T) {
	root := fixture(t, "link")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc notes.txt"))
	// The listing is answered apart from the rings; its rows must be there to hover.
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"))

	// The info block says what the chart has lit, the same as pointing at it.
	said := "4.0 KiB · 1.5% of sonar_gui_link"
	testing.expect(t, !ui.probe_tagged(&r.p, said), "nothing is lit yet")
	row := ui.probe_bounds(&r.p, "notes.txt")
	ui.probe_move(&r.p, row.x + 24, row.y + row.h / 2)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(&r.p, said),
		"hovering the row lights notes.txt in the sunburst",
	)

	// Off the row, the light goes out.
	ui.probe_move(&r.p, 4, 4)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	testing.expect(t, !ui.probe_tagged(&r.p, said), "and goes out off it")

	// The same in the treemap.
	testing.expect(t, ui.probe_click(&r.p, "Treemap"))
	press_and_hand_on(&r)
	ui.probe_advance(&r.p, 30, 1.0 / 60)
	ui.probe_move(&r.p, row.x + 24, row.y + row.h / 2)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, said), "hovering the row lights notes.txt's box")
}

@(test)
the_icicle_opens_a_bar_and_its_top_goes_up :: proc(t: ^testing.T) {
	root := fixture(t, "icicle")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"))
	// The bars come from the rings' answer, which lands apart from the listing.
	testing.expect(t, settle(&r, "arc photos"))

	testing.expect(t, ui.probe_click(&r.p, "Icicle"))
	press_and_hand_on(&r)
	ui.probe_advance(&r.p, 60, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, "top bar"), "the directory shown is the top bar")
	testing.expect(t, ui.probe_tagged(&r.p, "bar photos"), "photos is a bar")
	room := ui.probe_bounds(&r.p, "Icicle chart")
	photos := ui.probe_bounds(&r.p, "bar photos")
	testing.expectf(t, photos.w / room.w > 0.95, "photos is %v of the width", photos.w / room.w)

	ui.probe_click_at(&r.p, {photos.x + photos.w / 2, photos.y + photos.h / 2})
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"), "photos opened")
	testing.expect(t, settle(&r, "bar big.raw"), "its files are the first row")

	top := ui.probe_bounds(&r.p, "top bar")
	ui.probe_click_at(&r.p, {top.x + top.w / 2, top.y + top.h / 2})
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"), "the top bar went up")
}

@(test)
colouring_by_type_names_the_kind :: proc(t: ^testing.T) {
	root := fixture(t, "kinds")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"))
	testing.expect(t, !ui.probe_tagged(&r.p, "Archive"), "no legend by folder")

	// The kind is read off the rings' answer, which lands apart from the listing.
	testing.expect(t, settle(&r, "arc notes.txt"))
	testing.expect(t, ui.probe_click(&r.p, "Type"))
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_tagged(&r.p, "Archive"), "the legend names the kinds")
	row := ui.probe_bounds(&r.p, "notes.txt")
	ui.probe_move(&r.p, row.x + 24, row.y + row.h / 2)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	said := "4.0 KiB · 1.5% of sonar_gui_kinds · Text"
	testing.expect(t, ui.probe_tagged(&r.p, said), "the info block names the kind")
}

@(test)
hovering_a_largest_file_lights_its_arc :: proc(t: ^testing.T) {
	root := fixture(t, "lfh")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"))

	// The largest files are an answer of their own, too.
	testing.expect(t, settle(&r, "/tmp/sonar_gui_lfh/photos/big.raw"))

	// big.raw is in the largest files, and in the second ring, under photos.
	said := "256.0 KiB · 95.5% of sonar_gui_lfh"
	testing.expect(t, !ui.probe_tagged(&r.p, said))
	row := ui.probe_bounds(&r.p, "big.raw")
	ui.probe_move(&r.p, row.x + 24, row.y + row.h / 2)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, said), "hovering the largest file lights its arc")
}

@(test)
every_window_size_lays_out_without_a_clash :: proc(t: ^testing.T) {
	root := fixture(t, "layout")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"))

	overlaps :: proc(a, b: ops.Rect) -> bool {
		return(
			a.w > 0 &&
			b.w > 0 &&
			a.x < b.x + b.w - 0.5 &&
			b.x < a.x + a.w - 0.5 &&
			a.y < b.y + b.h - 0.5 &&
			b.y < a.y + a.h - 0.5 \
		)
	}
	for colour in view.Colouring {
		r.m.colour = colour
		for height in ([]f32{420, 900}) {
			for width := f32(640); width <= 1600; width += 160 {
				r.p.size = {width, height}
				ui.probe_advance(&r.p, 30, 1.0 / 60)
				at := fmt.tprintf("%v at %vx%v", colour, width, height)
				tool := []string{"sonar", "Location", "Rescan", "Dark theme"}
				for i in 0 ..< len(tool) {
					for j in i + 1 ..< len(tool) {
						a, b := ui.probe_bounds(&r.p, tool[i]), ui.probe_bounds(&r.p, tool[j])
						testing.expectf(
							t,
							!overlaps(a, b),
							"%s: %s overlaps %s",
							at,
							tool[i],
							tool[j],
						)
					}
				}
				grip := ui.probe_bounds(&r.p, "Resize panels")
				for name in ([]string{"Sunburst chart", "Reclaim", "Type"}) {
					b := ui.probe_bounds(&r.p, name)
					testing.expectf(
						t,
						b.x + b.w <= grip.x + 0.5,
						"%s: %s runs to %v, past the grip at %v",
						at,
						name,
						b.x + b.w,
						grip.x,
					)
				}
				disc := ui.probe_bounds(&r.p, "Sunburst chart")
				testing.expectf(
					t,
					disc.y + disc.h <= height + 0.5,
					"%s: the disc ends at %v, below the window",
					at,
					disc.y + disc.h,
				)
				testing.expectf(t, disc.w >= 120, "%s: the disc is only %v wide", at, disc.w)
				dark := ui.probe_bounds(&r.p, "Dark theme")
				testing.expectf(
					t,
					dark.x + dark.w <= width + 0.5,
					"%s: the toolbar runs past the window",
					at,
				)
			}
		}
	}

	// Reclaim mode's list stays on its side of the grip and inside the window.
	r.m.mode = .Reclaim
	ui.probe_frame(&r.p)
	hand_on(&r)
	for height in ([]f32{420, 900}) {
		for width := f32(640); width <= 1600; width += 160 {
			r.p.size = {width, height}
			ui.probe_advance(&r.p, 30, 1.0 / 60)
			testing.expect(t, settle(&r, "Nothing here is safe to reclaim."))
			grip := ui.probe_bounds(&r.p, "Resize panels")
			for name in ([]string{"Reclaim", "Nothing here is safe to reclaim."}) {
				b := ui.probe_bounds(&r.p, name)
				testing.expectf(
					t,
					b.w > 0 && b.x + b.w <= grip.x + 0.5 && b.y + b.h <= height + 0.5,
					"Reclaim at %vx%v: %s is at %v, past the grip at %v or the window",
					width,
					height,
					name,
					b,
					grip.x,
				)
			}
		}
	}
}

@(test)
switching_colouring_moves_nothing :: proc(t: ^testing.T) {
	root := fixture(t, "steady")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))

	// The legend's row is as tall either way, so the chart under it stays put,
	// at a width where the chips take one line and where they wrap.
	for width in ([]f32{1100, 700}) {
		r.p.size = {width, 700}
		r.m.colour = .Folder
		ui.probe_advance(&r.p, 30, 1.0 / 60)
		testing.expect(t, ui.probe_tagged(&r.p, "Coloured by top-level folder"))
		before := ui.probe_bounds(&r.p, "Sunburst chart")
		r.m.colour = .Type
		ui.probe_advance(&r.p, 30, 1.0 / 60)
		testing.expect(t, ui.probe_tagged(&r.p, "Multimedia"), "the chips name the kinds")
		after := ui.probe_bounds(&r.p, "Sunburst chart")
		testing.expectf(
			t,
			before == after,
			"at %v wide the chart moved from %v to %v",
			width,
			before,
			after,
		)
	}
}

@(test)
type_chips_turn_on_and_off_and_light_their_kind :: proc(t: ^testing.T) {
	root := fixture(t, "chips")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	testing.expect(t, ui.probe_click(&r.p, "Type"))
	press_and_hand_on(&r)
	before := ui.probe_bounds(&r.p, "Sunburst chart")

	testing.expect(t, ui.probe_click(&r.p, "Text"))
	ui.probe_frame(&r.p)
	testing.expect_value(t, r.m.kinds_on, bit_set[view.Kind]{.Text})
	testing.expect(t, ui.probe_click(&r.p, "Image"))
	ui.probe_frame(&r.p)
	testing.expect_value(t, r.m.kinds_on, bit_set[view.Kind]{.Text, .Image})
	testing.expect(t, ui.probe_click(&r.p, "Text"))
	ui.probe_frame(&r.p)
	testing.expect_value(t, r.m.kinds_on, bit_set[view.Kind]{.Image})

	chip := ui.probe_bounds(&r.p, "Archive")
	ui.probe_move(&r.p, chip.x + chip.w / 2, chip.y + chip.h / 2)
	ui.probe_advance(&r.p, 2, 1.0 / 60)
	kind, hovering := r.m.kind_hover.?
	testing.expect(t, hovering && kind == .Archive, "the chip under the pointer lights its kind")
	testing.expect_value(t, ui.probe_bounds(&r.p, "Sunburst chart"), before)
}

@(test)
opening_a_directory_never_blanks_the_panels :: proc(t: ^testing.T) {
	root := fixture(t, "steady_open")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	testing.expect(t, settle(&r, "268.0 KiB in 2 items"))

	// Open photos, then draw frames with no answer delivered: until the new ones
	// land, the panels show what they had, never nothing.
	ui.probe_click_at(&r.p, ring_point(&r, 0.5))
	hand_on(&r)
	for _ in 0 ..< 3 {
		ui.probe_frame(&r.p)
		testing.expect(t, ui.probe_tagged(&r.p, "Sunburst chart"), "the chart is drawn")
		// The pointer rests where it clicked, on photos, which the block describes.
		testing.expect(
			t,
			ui.probe_tagged(&r.p, "264.0 KiB · 98.5% of sonar_gui_steady_open · click to open"),
			"the info block keeps its text",
		)
		testing.expect(
			t,
			ui.probe_tagged(&r.p, "268.0 KiB in 2 items"),
			"the contents keep their rows",
		)
	}
	// Then the answers land, and they show photos.
	testing.expect(t, settle(&r, "264.0 KiB in 2 items"), "photos is listed")
	testing.expect(t, settle(&r, "arc big.raw"), "and drawn")
}

// age makes path, and what it directly holds, look last touched days ago.
@(private = "file")
age :: proc(t: ^testing.T, path: string, days: int) {
	then := time.time_add(time.now(), -time.Duration(days) * 24 * time.Hour)
	testing.expectf(t, os.change_times(path, then, then) == nil, "could not age %s", path)
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	testing.expect(t, err == nil)
	for e in entries {
		testing.expect(t, os.change_times(e.fullpath, then, then) == nil)
	}
}

/*
A directory of projects, made fresh:

	<root>/web/package.json                 a Node project
	<root>/web/node_modules/lib/index.js    64 KiB, touched a month ago
	<root>/rust/Cargo.toml                  a Rust project
	<root>/rust/target/app                  128 KiB, touched today
	<root>/plain/build/out.o                32 KiB, a build folder of no known project
*/
@(private = "file")
projects :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/sonar_gui_%s", dir, name)
	os.remove_all(root)
	for d in ([]string{"", "web", "web/node_modules", "web/node_modules/lib", "rust", "rust/target", "plain", "plain/build"}) {
		testing.expectf(
			t,
			os.make_directory(fmt.tprintf("%s/%s", root, d)) == nil,
			"could not make %s",
			d,
		)
	}
	write :: proc(t: ^testing.T, path: string, size: int) {
		body := make([]byte, size, context.temp_allocator)
		slice.fill(body, 'x')
		testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
	}
	write(t, fmt.tprintf("%s/web/package.json", root), 2)
	write(t, fmt.tprintf("%s/web/node_modules/lib/index.js", root), 64 * 1024)
	write(t, fmt.tprintf("%s/rust/Cargo.toml", root), 2)
	write(t, fmt.tprintf("%s/rust/target/app", root), 128 * 1024)
	write(t, fmt.tprintf("%s/plain/build/out.o", root), 32 * 1024)
	age(t, fmt.tprintf("%s/web/node_modules", root), 30)
	return root
}

// confirm clicks a button in the window, then the one in the dialog it opens.
@(private = "file")
confirm :: proc(t: ^testing.T, r: ^Rig, button, answer: string) {
	// The list lays itself out over a few frames as its answer lands.
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	testing.expectf(t, ui.probe_click(&r.p, button), "no %s button", button)
	press_and_hand_on(r)
	press_and_hand_on(r)
	testing.expectf(t, ui.probe_click(&r.p, answer), "the dialog has no %s", answer)
	press_and_hand_on(r)
}

@(test)
reclaim_offers_only_what_rebuilds_and_deletes_what_is_chosen :: proc(t: ^testing.T) {
	root := projects(t, "reclaim")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc web"))

	testing.expect(t, ui.probe_click(&r.p, "Reclaim"))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "web/node_modules"), "node_modules beside package.json")
	testing.expect(t, settle(&r, "rust/target"), "target beside Cargo.toml")
	testing.expect(t, !ui.probe_tagged(&r.p, "plain/build"), "a build folder of no project")
	testing.expect(t, !ui.probe_tagged(&r.p, "Sunburst chart"), "the chart is put away")
	// target was touched today, so only node_modules starts chosen.
	testing.expect(t, settle(&r, "64.0 KiB in 1 folder chosen"), "the recent one starts unchosen")

	confirm(t, &r, "Clean up", "Delete")
	testing.expect(t, settle(&r, "Deleted 1 folder and freed 64.0 KiB"), "the notice says so")
	testing.expect(t, settle(&r, "web/node_modules", present = false), "it leaves the list")
	testing.expect(t, !os.exists(fmt.tprintf("%s/web/node_modules", root)), "and the disk")
	testing.expect(t, os.exists(fmt.tprintf("%s/web/package.json", root)), "its project stays")
	testing.expect(t, os.exists(fmt.tprintf("%s/rust/target/app", root)), "the unchosen stays")
	testing.expect(t, os.exists(fmt.tprintf("%s/plain/build/out.o", root)), "the unoffered stays")

	// Choosing target by hand deletes it too.
	testing.expect(t, settle(&r, "0 B in 0 folders chosen"))
	testing.expect(t, ui.probe_click(&r.p, "rust/target"))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "128.0 KiB in 1 folder chosen"))
	confirm(t, &r, "Clean up", "Delete")
	testing.expect(t, settle(&r, "Deleted 1 folder and freed 128.0 KiB"))
	testing.expect(t, !os.exists(fmt.tprintf("%s/rust/target", root)))
	testing.expect(t, settle(&r, "Nothing here is safe to reclaim."))

	// The host deletes only what it offered, whatever it is sent: here the top.
	forged := command.Clean {
		generation = r.m.generation,
		count      = 1,
	}
	stream.port_send(r.h.cmd_port, command.Command(forged))
	testing.expect(t, settle(&r, "Deleted 0 folders and freed 0 B; 1 could not be deleted"))
	testing.expect(t, os.exists(fmt.tprintf("%s/plain/build/out.o", root)), "nothing went")
}

@(test)
reclaim_empties_the_trash_it_found :: proc(t: ^testing.T) {
	// The home, and so its Trash, is the test's own.
	root := projects(t, "reclaim_trash")
	defer os.remove_all(root)
	for d in ([]string{".local", ".local/share", ".local/share/Trash", ".local/share/Trash/files", ".local/share/Trash/info"}) {
		testing.expect(t, os.make_directory(fmt.tprintf("%s/%s", root, d)) == nil)
	}
	old := make([]byte, 16 * 1024, context.temp_allocator)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/.local/share/Trash/files/old.bin", root), old) == nil,
	)
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/.local/share/Trash/info/old.bin.trashinfo", root),
			old[:2],
		) ==
		nil,
	)
	sync.guard(&trash_env)
	home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	testing.expect(t, os.set_env("HOME", root) == nil)
	defer os.set_env("HOME", home)

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc web"))
	testing.expect(t, ui.probe_click(&r.p, "Reclaim"))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "Empty Trash"), "the Trash is offered")
	// Always in view: above the list, never at its end to be scrolled to.
	button, first :=
		ui.probe_bounds(&r.p, "Empty Trash"), ui.probe_bounds(&r.p, "All Installed dependencies")
	testing.expectf(
		t,
		first.h > 0 && button.y + button.h <= first.y,
		"the button is at %v, the list at %v",
		button,
		first,
	)
	testing.expect(t, !ui.probe_tagged(&r.p, ".local/share/Trash"), "as a button, not a row")

	confirm(t, &r, "Empty Trash", "Empty")
	testing.expect(t, settle(&r, "Emptied the Trash and freed 20.0 KiB"), "the notice says so")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.local/share/Trash/files/old.bin", root)))
	testing.expect(t, !os.exists(fmt.tprintf("%s/.local/share/Trash/info", root)))
	testing.expect(t, os.exists(fmt.tprintf("%s/.local/share/Trash", root)), "the Trash stays")
	testing.expect(t, os.exists(fmt.tprintf("%s/web/node_modules", root)), "cleaning is separate")
}
