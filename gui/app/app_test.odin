//review:ignore history-coupled-file the chart tree this tests lives in gui/view/chart_tree.odin; view.odin needs nothing
package leita_app

import "base:runtime"

import "core:crypto"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:debug"
import "jm:http/loopback"
import "jm:i18n"
import "jm:sqlite3"
import "jm:stream"

import "jm:ui"
import bl "jm:ui/blend2d"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../../changes"
import "../../history"
import "../../licence"
import "../../monitor"
import "../../scan"
import "../../schedule"
import "../../settings"
import "../../update"
import "../../version"
import "../command"
import "../msg"
import "../query"
import "../view"

// The whole application, less the window: the view runs in a probe, the probe's
// needs and commands go to the host as the frame loop would send them, and the
// host's answers are drained into the probe before the next frame. Everything
// between is the real pipeline, desk and reader on their real threads, over a
// real directory.

@(private = "file")
Rig :: struct {
	shared:   bool, // holds scan_env shared, as every rig does but the one that set it
	own_data: string, // the data folder rig_open made for a test that gave none
	h:        Host,
	m:        view.Model,
	// The probe, as p, with a renderer and the window's fonts beside it, so a
	// test can look at pixels as well as tags.
	using hl: render.Headless,
	data:     ui.Data_Host,
	needs:    ui.Subscriptions,
}

@(private = "file")
rig_open :: proc(
	r: ^Rig,
	path: string,
	kept := "",
	reports := "",
	licence_key: []byte = nil,
	activate_url := "",
	release_base := "",
	made_up := false,
	scheduler: ^schedule.Host = nil,
	monitor_argv: []string = nil,
) {
	if !made_up {
		env_share()
		r.shared = true
	}
	keep := kept
	if keep == "" {
		r.own_data = rig_data()
		keep = fmt.tprintf("%s/history.db", r.own_data)
	}
	init(
		&r.h,
		path,
		kept = keep,
		reports = reports,
		licence_key = licence_key,
		activate_url = activate_url,
		release_base = release_base,
		scheduler = scheduler,
		monitor_argv = monitor_argv,
	)
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
	await_licence(r)
}

/*
await_licence drains the host's answers into the probe, as settle does, until
the window holds whether the paid features are unlocked. Until it does, the
window takes them as locked (view.unlocked), so a test that reached for Export
or the licence dialog before the answer, on a loaded machine, met the licence
notice instead of what it asked for.
*/
@(private = "file")
await_licence :: proc(r: ^Rig) {
	key := ui.key_of(query.Licence{})
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for time.tick_now()._nsec < deadline {
		if shape, ok := r.p.layout.shapes[key]; ok && shape.status == .Ready {
			return
		}
		if ui.inbox_pending(&r.h.inbox) {
			ui.inbox_drain(&r.h.inbox, &r.p.layout)
			ui.probe_frame(&r.p)
			hand_on(r)
		}
		time.sleep(time.Millisecond)
	}
}

@(private = "file")
rig_close :: proc(r: ^Rig) {
	render.headless_destroy(&r.hl)
	ui.subscriptions_destroy(&r.needs)
	view.model_destroy(&r.m)
	stop(&r.h)
	if r.shared {
		env_unshare()
	}
	if r.own_data != "" {
		os.remove_all(r.own_data)
		delete(r.own_data, runtime.heap_allocator())
	}
}

/*
rig_data is a fresh data folder for a rig its test gives none. Without one the
trial is over (licence.first_use: nowhere to keep when it began), and the
trial-ended notice moves everything under it, so a test measuring the window
would measure the notice. A test of the trial's end gives its own. The folder
is named for this process and a count, not the rig's path, which may be "/" or
not there at all.
*/
@(private = "file")
rig_data :: proc() -> string {
	@(static) made: int
	n := sync.atomic_add(&made, 1)
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.aprintf(
		"%s/leita_gui_rig_%d_%d",
		tmp,
		os.get_pid(),
		n,
		allocator = runtime.heap_allocator(),
	)
	os.remove_all(dir)
	_ = os.make_directory(dir)
	return dir
}

/*
scan_env is held shared by every test whose host scans a real directory, and
held alone by one that points scan.SYNTHETIC_ENV at a made-up disk: the variable
is the process's, and a host resolves its target on a thread of its own, so a
real scan started while it is set would read the made-up disk. A test thread
holds it shared once, however many hosts it opens.
*/
@(private)
scan_env: sync.RW_Mutex

@(private, thread_local)
env_shares: int

@(private)
env_share :: proc() {
	if env_shares == 0 {
		sync.rw_mutex_shared_lock(&scan_env)
	}
	env_shares += 1
}

@(private)
env_unshare :: proc() {
	env_shares -= 1
	if env_shares == 0 {
		sync.rw_mutex_shared_unlock(&scan_env)
	}
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

// await_rescan drains the host's answers, as settle does, until the window holds
// a scan newer than first, and says whether it did in settle's time: what a test
// reads of the desk's scan after that is the new scan's, not one half begun.
@(private = "file")
await_rescan :: proc(r: ^Rig, first: u32) -> bool {
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for time.tick_now()._nsec < deadline {
		if r.m.generation > first {
			return true
		}
		if ui.inbox_pending(&r.h.inbox) {
			ui.inbox_drain(&r.h.inbox, &r.p.layout)
			ui.probe_frame(&r.p)
			hand_on(r)
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
own_trash readies notes.txt in root for a test that trashes it, and says the name
to trash it by and where it will land. The freedesktop.org Trash is pointed at one
beside root through XDG_DATA_HOME, which the caller holds trash_env for and unsets.
The Finder's cannot be pointed anywhere, so there notes.txt is given a name no other
entry has, which the Finder keeps, and the caller deletes what landed. Nor can the
Recycle Bin, whose file is named for it, so on Windows nothing is said to have
landed anywhere: recycled finds it by the record of where it was.
*/
@(private = "file")
own_trash :: proc(t: ^testing.T, root: string) -> (name, landed: string) {
	when ODIN_OS == .Darwin {
		name = fmt.tprintf("notes-%d.txt", time.to_unix_nanoseconds(time.now()))
		from := fmt.tprintf("%s/notes.txt", root)
		testing.expect(t, os.rename(from, fmt.tprintf("%s/%s", root, name)) == nil)
		home := os.get_env("HOME", context.temp_allocator)
		return name, fmt.tprintf("%s/.Trash/%s", home, name)
	} else when ODIN_OS == .Windows {
		return "notes.txt", ""
	} else {
		data := fmt.tprintf("%s-data", root)
		os.remove_all(data)
		testing.expect(t, os.set_env("XDG_DATA_HOME", data) == nil)
		return "notes.txt", fmt.tprintf("%s/Trash/files/notes.txt", data)
	}
}

/*
A directory to scan, made fresh:

	<root>/photos/big.raw    256 KiB
	<root>/photos/small.jpg  8 KiB
	<root>/notes.txt         4 KiB
*/
// scratch is the temp directory as a scan names it: with its links resolved, since
// macOS's is under /var, a link to /private/var, and no trailing separator.
@(private = "file")
scratch :: proc(t: ^testing.T) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	info, stat_err := os.stat(dir, context.temp_allocator)
	testing.expect(t, stat_err == nil, "the temp directory is not there")
	return strings.trim_right(info.fullpath, `/\`)
}

// under is the path of names below dir, as the scan names it: joined with the
// platform's separator, as is a root made by fixture.
@(private = "file")
under :: proc(dir: string, names: ..string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, dir)
	for name in names {
		strings.write_string(&sb, scan.SEPARATOR)
		strings.write_string(&sb, name)
	}
	return strings.to_string(sb)
}

@(private = "file")
fixture :: proc(t: ^testing.T, name: string) -> string {
	root := under(scratch(t), fmt.tprintf("leita_gui_%s", name))
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
	testing.expect(t, settle(&r, "270.3 kB in 2 items"), "the directory's contents are listed")
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
	testing.expect(t, settle(&r, "270.3 kB in 2 items"), "photos is open")
	first := r.m.generation

	// Scanning again renumbers the tree, so the view goes back to the top. The
	// listing can be answered before the scan ends, and Rescan replaces Stop only
	// once it has.
	testing.expect(t, settle(&r, "Done"), "the scan finished")
	testing.expect(t, choose(&r, "Rescan"))
	hand_on(&r)
	testing.expect(t, settle(&r, "274.4 kB in 2 items"), "the top is listed again")
	testing.expect(t, r.m.generation > first, "a new generation")
}

@(test)
a_path_that_is_not_there_fails_with_a_reason :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r, "/nonexistent/leita/path")
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Failed"), "the failure is shown")
	testing.expect(
		t,
		ui.probe_tagged(&r.p, "cannot scan /nonexistent/leita/path: Target_Not_Found"),
		"the reason is shown",
	)
}

// A path longer than a command carries is cut by it, and what is left of this one
// is a directory that exists: scanning it would read the wrong place, so the scan
// fails instead, as a path cut anywhere else would have.
@(test)
a_path_longer_than_a_command_carries_is_refused :: proc(t: ^testing.T) {
	root := fixture(t, "longpath")
	defer os.remove_all(root)
	// Each "/." is the directory it is in, so every prefix of this path names root.
	long := strings.concatenate(
		{root, strings.repeat("/.", command.MAX_PATH / 2, context.temp_allocator)},
		context.temp_allocator,
	)
	defer free_all(context.temp_allocator)
	r: Rig
	rig_open(&r, long)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Failed"), "the failure is shown")
	testing.expect(t, ui.probe_tagged(&r.p, "that path is too long to scan"), "and why")
	testing.expect(t, !r.h.desk.scan.grown, "nothing was read")

	// The same through a command, as the location field sends it.
	scan_command := command.Scan {
		path = command.text_make(long),
	}
	testing.expect(t, scan_command.path.cut, "the command was cut")
	first := r.m.generation
	stream.port_send(r.h.cmd_port, command.Command(scan_command))
	// The first scan's failure is still said, so the second is waited for by its
	// number: until then the desk may be swapping in the scan the test reads.
	testing.expect(t, await_rescan(&r, first), "the command scans again")
	testing.expect(t, settle(&r, "that path is too long to scan"))
	testing.expect(t, r.h.desk.scan.state == .Failed)
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
	testing.expect(t, settle(&r, "270.3 kB in 2 items"), "the listing followed")

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

// open_settings opens the toolbar's settings menu, unless it is open, in the
// window's language. The toolbar settles first: a press lands where the last
// frame drew.
@(private = "file")
open_settings :: proc(r: ^Rig) -> bool {
	if r.m.settings_open {
		return true
	}
	gear := msg.tr(r.m.strings, .Settings) if r.m.strings != nil else "Settings"
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	if !ui.probe_click(&r.p, gear) {
		return false
	}
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	return true
}

// choose chooses item in the settings menu.
@(private = "file")
choose :: proc(r: ^Rig, item: string) -> bool {
	return open_settings(r) && ui.probe_click_top(&r.p, item)
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
a_rename_is_kept_in_the_audit_trail :: proc(t: ^testing.T) {
	root := fixture(t, "audit")
	defer os.remove_all(root)
	kept := fmt.tprintf("%s-kept/history.db", root)
	defer os.remove_all(fmt.tprintf("%s-kept", root))
	r: Rig
	rig_open(&r, root, kept)
	defer rig_close(&r)

	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	ui.probe_click_at(&r.p, ring_point(&r, 0.5), .Right)
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Rename"), "the menu offers Rename")
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	ui.probe_type(&r.p, "pictures")
	ui.probe_key(&r.p, .Enter)
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "Renamed photos to pictures"), "the toast says so")

	// The desk writes the trail before it answers, so the toast means it is there.
	db, err := sqlite3.open(kept, {busy_timeout = 1000}, context.temp_allocator)
	testing.expect(t, err == nil, "the store is there")
	defer sqlite3.close(&db)
	rows, qerr := sqlite3.query(
		db,
		"SELECT kind, path, detail, bytes, failed FROM action",
		allocator = context.temp_allocator,
	)
	testing.expect(t, qerr == nil)
	testing.expect(t, sqlite3.next(&rows), "the rename is in the trail")
	testing.expect_value(t, sqlite3.text(rows, 0), "rename")
	testing.expect_value(t, sqlite3.text(rows, 1), under(root, "photos"))
	testing.expect_value(t, sqlite3.text(rows, 2), "pictures")
	testing.expect(t, sqlite3.integer(rows, 3) >= 264 * 1024, "with what it held")
	testing.expect_value(t, sqlite3.integer(rows, 4), 0)
	testing.expect(t, !sqlite3.next(&rows), "and nothing else")
	testing.expect(t, sqlite3.finish(&rows) == nil)
}

// History in the settings menu opens the record the store holds, newest first,
// with the reason a deletion failed.
@(test)
history_in_the_settings_menu_lists_what_the_store_recorded :: proc(t: ^testing.T) {
	root := fixture(t, "record")
	defer os.remove_all(root)
	kept := fmt.tprintf("%s-kept/history.db", root)
	defer os.remove_all(fmt.tprintf("%s-kept", root))
	st: history.Store
	testing.expect(t, history.open(&st, kept) == nil)
	done := []history.Action {
		{1_800_000_000, .Delete, "/gone/old", "", 5 << 20, false},
		{1_800_000_100, .Delete, "/gone/new", "permission denied", 7 << 20, true},
	}
	testing.expect(t, history.record(&st, done) == nil)
	history.close(&st)

	r: Rig
	rig_open(&r, root, kept)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))

	testing.expect(t, choose(&r, "History"), "the menu has History")
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	hand_on(&r)
	testing.expect(t, settle(&r, "/gone/new"), "the newest is listed")
	testing.expect(t, settle(&r, "/gone/old"), "and the older")
	testing.expect(t, settle(&r, "Failed: permission denied"), "with why it failed")
	newest, oldest := ui.probe_bounds(&r.p, "/gone/new"), ui.probe_bounds(&r.p, "/gone/old")
	testing.expect(t, newest.y < oldest.y, "newest first")
}

@(test)
a_right_click_moves_an_entry_to_the_trash_and_out_of_the_totals :: proc(t: ^testing.T) {
	root := fixture(t, "trash")
	defer os.remove_all(root)
	defer os.remove_all(fmt.tprintf("%s-data", root))
	sync.guard(&trash_env)
	name, landed := own_trash(t, root)
	defer os.unset_env("XDG_DATA_HOME")
	defer os.remove(landed)

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)

	// notes.txt is the smaller entry, the last stretch of the ring before twelve.
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, fmt.tprintf("arc %s", name)))
	ui.probe_click_at(&r.p, ring_point(&r, 0.9925), .Right)
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the menu offers the Trash")
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the dialog asks first")
	press_and_hand_on(&r)

	said := fmt.tprintf("Moved %s to the Trash", name)
	testing.expect(t, settle(&r, said), "the notice says so")
	testing.expect(t, settle(&r, fmt.tprintf("arc %s", name), present = false), "its arc is gone")
	testing.expect(t, settle(&r, "270.3 kB in 1 item"), "the totals dropped")
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", root, name)), "gone from the folder")
	when ODIN_OS == .Windows {
		// recycled finds only a record that names root's notes.txt.
		record, file := recycled(root, name)
		testing.expect(t, os.exists(file), "in the Recycle Bin")
		testing.expect(t, record != "", "with a record of where it was")
		os.remove(record)
		os.remove(file)
	} else {
		testing.expect(t, os.exists(landed), "in the Trash")
	}
	when ODIN_OS != .Darwin && ODIN_OS != .Windows {
		info := fmt.tprintf("%s-data/Trash/info/notes.txt.trashinfo", root)
		testing.expect(t, os.exists(info), "with a record of where it was")
	}
}

@(test)
a_right_click_on_a_contents_row_trashes_it :: proc(t: ^testing.T) {
	root := fixture(t, "rowtrash")
	defer os.remove_all(root)
	defer os.remove_all(fmt.tprintf("%s-data", root))
	sync.guard(&trash_env)
	name, landed := own_trash(t, root)
	defer os.unset_env("XDG_DATA_HOME")
	defer os.remove(landed)

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "274.4 kB in 2 items"))

	open_row(&r, name, .Right)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the row's menu offers Trash")
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the dialog asks first")
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "270.3 kB in 1 item"), "the row is gone from the totals")
	when ODIN_OS == .Windows {
		record, file := recycled(root, name)
		testing.expect(t, os.exists(file), "in the Recycle Bin")
		os.remove(record)
		os.remove(file)
	} else {
		testing.expect(t, os.exists(landed), "in the Trash")
	}
}

// Back and Forward do not enter a directory that went to the Trash: the host
// answers for it as gone, and the window goes to the nearest folder that is not,
// with the forgotten one out of its history.
@(test)
forward_does_not_enter_a_trashed_directory :: proc(t: ^testing.T) {
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		return // their Trash cannot be pointed at a scratch one
	}
	place := fixture(t, "forwardtrash")
	defer os.remove_all(place)
	defer os.remove_all(fmt.tprintf("%s-data", place))
	sync.guard(&trash_env)
	own_trash(t, place)
	defer os.unset_env("XDG_DATA_HOME")

	r: Rig
	rig_open(&r, place)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "274.4 kB in 2 items"))
	top := r.m.dir

	// Into photos and back out, so photos waits in the history.
	open_row(&r, "photos")
	testing.expect(t, settle(&r, "270.3 kB in 2 items"), "photos is open")
	photos := r.m.dir
	ui.probe_key(&r.p, .Left, {.Alt})
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "274.4 kB in 2 items"), "back at the top")
	testing.expect_value(t, len(r.m.forward), 1)

	open_row(&r, "photos", .Right)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the row's menu offers Trash")
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "Trash"), "the dialog asks first")
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "Moved photos to the Trash"), "the notice says so")

	gone := listing(&r.h.desk, query.Listing{generation = r.m.generation, dir = photos})
	testing.expect(t, gone.gone, "the host says photos is gone")
	testing.expect_value(t, len(gone.entries), 0)
	testing.expect_value(t, gone.up, query.ROOT)

	ui.probe_key(&r.p, .Right, {.Alt})
	// The host's answer for photos is what sends the window off it.
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for r.m.dir == photos && time.tick_now()._nsec < deadline {
		ui.inbox_drain(&r.h.inbox, &r.p.layout)
		press_and_hand_on(&r)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, r.m.dir, top)
	testing.expect_value(t, len(r.m.forward), 0)
	testing.expect_value(t, len(r.m.back), 0)
	testing.expect(t, !ui.probe_tagged(&r.p, "small.jpg"), "none of its contents is drawn")
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
	testing.expect(t, settle(&r, "270.3 kB in 2 items"), "photos opened")
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
	// inked counts the pixels other than the background from x0 to x1, in the
	// rows from y0 to y1. It reads only inside the image.
	inked :: proc(data: bl.ImageData, x0, x1, y0, y1: f32) -> (n: int) {
		for y in max(int(y0), 0) ..< min(int(y1), int(data.size.h)) {
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
	// not a frame that drew nothing. The strips are the name's own rows: with
	// macOS's system face its letters start in the row the bar starts in, so a
	// name running on shows in its rows below the bar as well as above. The rows
	// the bar's edges are smoothed into are left out.
	name := ui.probe_bounds(&r.p, long)
	top, bottom := math.floor(bar.y), math.ceil(bar.y + bar.h)
	if !testing.expectf(
		t,
		name.y < top && bottom < name.y + name.h,
		"the name's rows %v do not reach past the bar's %v",
		name,
		bar,
	) {
		return
	}
	testing.expect(
		t,
		inked(data, bar.x - 200, bar.x - 60, name.y, name.y + name.h) > 0,
		"the name is drawn before the bar",
	)
	over :=
		inked(data, bar.x, bar.x + bar.w, name.y, top) +
		inked(data, bar.x, bar.x + bar.w, bottom, name.y + name.h)
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
		block := ui.probe_bounds(&r.p, "274.4 kB").y - title + view.info_height()
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
	testing.expect(t, settle(&r, "leita_gui_bar"), "the scan's top is a step")
	above := filepath.dir(root)
	testing.expect(t, settle(&r, filepath.base(above)), "and so is the directory above it")

	// Into photos and back by its step.
	ui.probe_click_at(&r.p, ring_point(&r, 0.5))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "photos"), "photos is a step now")
	testing.expect(t, settle(&r, "270.3 kB in 2 items"))
	testing.expect(t, ui.probe_click(&r.p, "leita_gui_bar"))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "274.4 kB in 2 items"), "the top's step opened the top")

	// A step above the scan asks for a scan from there.
	testing.expect(t, ui.probe_click(&r.p, filepath.base(above)))
	scanned := ""
	for c in ui.probe_commands(&r.p) {
		if cmd, ok := ui.command_as(c, command.Command); ok {
			if scan, is := cmd.(command.Scan); is {
				scan := scan
				scanned = strings.clone(command.text_of(&scan.path), context.temp_allocator)
			}
		}
	}
	testing.expect_value(t, scanned, fmt.tprintf("%s%s", above, scan.SEPARATOR))
	ui.router_commands_clear(&r.p.router)
}

@(test)
the_location_bar_edits_into_a_field_and_back :: proc(t: ^testing.T) {
	root := fixture(t, "edit")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	// Wide enough that the bar has an empty end past the steps of macOS's long
	// temp folder, /private/var/folders/<two hashed names>/T.
	r.p.size = {1600, 700}
	// Frames at the new size, so the bounds read below are laid out for it: a
	// scan that finishes before the first settle sends nothing to draw one.
	ui.probe_advance(&r.p, 30, 1.0 / 60)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "leita_gui_edit"))

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
	testing.expect(t, settle(&r, "leita_gui_edit"))

	// Enter scans what the field holds.
	ui.probe_click_at(&r.p, {bar.x + bar.w - 20, bar.y + bar.h / 2})
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	first := r.m.generation
	ui.probe_type(&r.p, fmt.tprintf("%s/photos", root))
	ui.probe_key(&r.p, .Enter)
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "270.3 kB in 2 items"), "photos was scanned")
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
	// Frames at the new size before the first click, which aims at a row's bounds
	// from the last frame drawn: a scan that finishes before settle looks sends
	// nothing to draw one, and the row was still where a 1100 wide window put it.
	ui.probe_advance(&r.p, 30, 1.0 / 60)
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
	gear := ui.probe_bounds(&r.p, "Settings")
	testing.expectf(
		t,
		bar.x + bar.w <= gear.x,
		"the bar ends at %v, before the Settings button at %v",
		bar.x + bar.w,
		gear.x,
	)
	deepest := ui.probe_bounds(&r.p, "fourth_level_directory")
	top := ui.probe_bounds(&r.p, filepath.base(filepath.dir(root)))
	testing.expect(t, top.w > 0, "the directory above the scan is a step")
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
		"the top has scrolled off the left: its parent at %v, bar from %v",
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
	// The middle of the box is on a file in it, whose click waits out a double
	// click before it takes the directory holding the file.
	ui.probe_click_at(&r.p, {photos.x + photos.w / 2, photos.y + photos.h / 2})
	ui.probe_advance(&r.p, 40, 1.0 / 60)
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "270.3 kB in 2 items"), "photos opened")
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
	testing.expect(t, settle(&r, "274.4 kB in 2 items"))

	// The info block says what the chart has lit, the same as pointing at it.
	said := "4.1 kB · 1.5% of leita_gui_link"
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
	testing.expect(t, settle(&r, "274.4 kB in 2 items"))
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
	testing.expect(t, settle(&r, "270.3 kB in 2 items"), "photos opened")
	testing.expect(t, settle(&r, "bar big.raw"), "its files are the first row")

	top := ui.probe_bounds(&r.p, "top bar")
	ui.probe_click_at(&r.p, {top.x + top.w / 2, top.y + top.h / 2})
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "274.4 kB in 2 items"), "the top bar went up")
}

@(test)
colouring_by_type_names_the_kind :: proc(t: ^testing.T) {
	root := fixture(t, "kinds")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "274.4 kB in 2 items"))
	testing.expect(t, !ui.probe_tagged(&r.p, "Archive"), "no legend by folder")

	// The kind is read off the rings' answer, which lands apart from the listing.
	testing.expect(t, settle(&r, "arc notes.txt"))
	testing.expect(t, ui.probe_click(&r.p, "Type"))
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_tagged(&r.p, "Archive"), "the legend names the kinds")
	row := ui.probe_bounds(&r.p, "notes.txt")
	ui.probe_move(&r.p, row.x + 24, row.y + row.h / 2)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	said := "4.1 kB · 1.5% of leita_gui_kinds · Text"
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
	testing.expect(t, settle(&r, "274.4 kB in 2 items"))

	// The largest files are an answer of their own, too.
	testing.expect(t, settle(&r, under(root, "photos", "big.raw")))

	// big.raw is in the largest files, and in the second ring, under photos.
	said := "262.1 kB · 95.5% of leita_gui_lfh"
	testing.expect(t, !ui.probe_tagged(&r.p, said))
	row := ui.probe_bounds(&r.p, "big.raw")
	ui.probe_move(&r.p, row.x + 24, row.y + row.h / 2)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, said), "hovering the largest file lights its arc")
}

/*
trial_data is a data folder beside root, and the history store in it, for a
rig that must run in the trial: with nowhere to keep when it began, the trial
is over (licence.first_use). Remove data after.
*/
trial_data :: proc(t: ^testing.T, root: string) -> (data, kept: string) {
	data = fmt.tprintf("%s-data", root)
	os.remove_all(data)
	testing.expect(t, os.make_directory(data) == nil)
	return data, fmt.tprintf("%s/history.db", data)
}

@(test)
every_window_size_lays_out_without_a_clash :: proc(t: ^testing.T) {
	root := fixture(t, "layout")
	defer os.remove_all(root)
	data, kept := trial_data(t, root)
	defer os.remove_all(data)
	r: Rig
	rig_open(&r, root, kept = kept)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	testing.expect(t, settle(&r, "274.4 kB in 2 items"))

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
				tool := []string{"Leita", "Location", "Search", "Settings"}
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
				gear := ui.probe_bounds(&r.p, "Settings")
				testing.expectf(
					t,
					gear.w > 0 && gear.x + gear.w <= width + 0.5,
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
	testing.expect(t, settle(&r, "274.4 kB in 2 items"))

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
			ui.probe_tagged(&r.p, "270.3 kB · 98.5% of leita_gui_steady_open · click to open"),
			"the info block keeps its text",
		)
		testing.expect(
			t,
			ui.probe_tagged(&r.p, "274.4 kB in 2 items"),
			"the contents keep their rows",
		)
	}
	// Then the answers land, and they show photos.
	testing.expect(t, settle(&r, "270.3 kB in 2 items"), "photos is listed")
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
	<root>/rust/target/CACHEDIR.TAG         4 KiB, cargo's word that target is its own
	<root>/plain/build/out.o                32 KiB, a build folder of no known project
*/
@(private = "file")
projects :: proc(t: ^testing.T, name: string) -> string {
	root := under(scratch(t), fmt.tprintf("leita_gui_%s", name))
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
	// 4 KiB, a whole block where blocks are 4 KiB, as the sizes here assume.
	write(t, fmt.tprintf("%s/rust/target/CACHEDIR.TAG", root), 4 * 1024)
	write(t, fmt.tprintf("%s/plain/build/out.o", root), 32 * 1024)
	age(t, fmt.tprintf("%s/web/node_modules", root), 30)
	return root
}

// The candidates projects makes, as the Reclaim list names them: joined on the
// scan's separator.
@(private = "file")
WEB_NODE_MODULES :: "web" + scan.SEPARATOR + "node_modules"
@(private = "file")
RUST_TARGET :: "rust" + scan.SEPARATOR + "target"

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
	testing.expect(t, settle(&r, WEB_NODE_MODULES), "node_modules beside package.json")
	testing.expect(t, settle(&r, RUST_TARGET), "target beside Cargo.toml")
	testing.expect(t, !ui.probe_tagged(&r.p, "plain" + scan.SEPARATOR + "build"), "a build folder of no project")
	testing.expect(t, !ui.probe_tagged(&r.p, "Sunburst chart"), "the chart is put away")
	// target was touched today, so only node_modules starts chosen.
	testing.expect(t, settle(&r, "65.5 kB in 1 folder chosen"), "the recent one starts unchosen")

	confirm(t, &r, "Clean up", "Delete")
	testing.expect(t, settle(&r, "Deleted 1 folder and freed 65.5 kB"), "the notice says so")
	testing.expect(t, settle(&r, WEB_NODE_MODULES, present = false), "it leaves the list")
	testing.expect(t, !os.exists(fmt.tprintf("%s/web/node_modules", root)), "and the disk")
	testing.expect(t, os.exists(fmt.tprintf("%s/web/package.json", root)), "its project stays")
	testing.expect(t, os.exists(fmt.tprintf("%s/rust/target/app", root)), "the unchosen stays")
	testing.expect(t, os.exists(fmt.tprintf("%s/plain/build/out.o", root)), "the unoffered stays")

	// Choosing target by hand deletes it too.
	testing.expect(t, settle(&r, "0 B in 0 folders chosen"))
	testing.expect(t, ui.probe_click(&r.p, RUST_TARGET))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "135.2 kB in 1 folder chosen"))
	confirm(t, &r, "Clean up", "Delete")
	testing.expect(t, settle(&r, "Deleted 1 folder and freed 135.2 kB"))
	testing.expect(t, !os.exists(fmt.tprintf("%s/rust/target", root)))
	testing.expect(t, settle(&r, "Nothing here is safe to reclaim."))

	// The host deletes only what it offered, whatever it is sent: here the top.
	forged := command.Clean {
		generation = r.m.generation,
		count      = 1,
	}
	stream.port_send(r.h.cmd_port, command.Command(forged))
	testing.expect(t, settle(&r, "Deleted 0 folders and freed 0 B; 1 could not be deleted in full"))
	testing.expect(t, os.exists(fmt.tprintf("%s/plain/build/out.o", root)), "nothing went")
}

/*
A directory link is never offered. The scan records a real node_modules; that
directory is then replaced by a link before Reclaim asks. On Windows lstat calls
the junction a directory, so only files.is_link keeps it out of the list. A
second link is already there at the scan: the walker records it as a reparse and
find skips it, and the MFT reader records a directory reparse point as a
directory, which the same check must refuse. Clean up is not clicked. The list
is the proof it was not offered, and the file the link names is still there.
*/
@(test)
reclaim_never_offers_a_directory_link :: proc(t: ^testing.T) {
	// remove_all on Windows can follow a junction (SHFileOperationW). Drop any
	// link a failed run left before projects removes the tree.
	stale := under(scratch(t), "leita_gui_reclaim_link")
	os.remove(under(stale, "web", "node_modules"))
	os.remove(under(stale, "linked", "node_modules"))
	root := projects(t, "reclaim_link")
	outside := under(scratch(t), "leita_gui_reclaim_link_outside")
	os.remove_all(outside)
	testing.expect(t, os.make_directory(outside) == nil, "the link target")
	sentinel := under(outside, "keep")
	testing.expect(t, os.write_entire_file(sentinel, "keep") == nil)
	web_link := under(root, "web", "node_modules")
	prior := under(root, "linked", "node_modules")
	defer {
		os.remove(web_link)
		os.remove(prior)
		os.remove_all(root)
		os.remove_all(outside)
	}
	testing.expect(t, os.make_directory(under(root, "linked")) == nil)
	testing.expect(t, os.write_entire_file(under(root, "linked", "package.json"), "{}\n") == nil)
	testing.expect(t, link_directory(outside, prior), "a directory link before the scan")

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))

	testing.expect(t, os.remove_all(web_link) == nil, "the recorded directory")
	testing.expect(
		t,
		link_directory(outside, web_link),
		"a directory link where the candidate was",
	)
	kept, read_err := os.read_entire_file(sentinel, context.temp_allocator)
	testing.expect(
		t,
		read_err == nil && string(kept) == "keep",
		"the target is intact before Reclaim",
	)

	testing.expect(t, ui.probe_click(&r.p, "Reclaim"))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, RUST_TARGET), "a real directory is still offered")
	testing.expect(
		t,
		!ui.probe_tagged(&r.p, WEB_NODE_MODULES),
		"a link put where a candidate was is not offered",
	)
	testing.expect(
		t,
		!ui.probe_tagged(&r.p, "linked" + scan.SEPARATOR + "node_modules"),
		"a directory link under the scan is not offered",
	)
	kept, read_err = os.read_entire_file(sentinel, context.temp_allocator)
	testing.expect(
		t,
		read_err == nil && string(kept) == "keep",
		"what the link names was not touched",
	)
	testing.expect(t, os.exists(web_link), "the link itself was not deleted")
	testing.expect(t, os.exists(prior), "the earlier link was not deleted")
}

// A folder that cannot all be deleted stays in the list and the chart, and only
// what went is counted freed. Here node_modules is emptied, but its own folder
// stays: web is made read-only after the scan, so nothing in it can be unlinked.
@(test)
reclaim_counts_a_partial_delete_as_what_went :: proc(t: ^testing.T) {
	root := projects(t, "reclaim_partly")
	web := fmt.tprintf("%s/web", root)
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, ui.probe_click(&r.p, "Reclaim"))
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "65.5 kB in 1 folder chosen"))

	testing.expect(t, os.change_mode(web, {.Read_User, .Execute_User}) == nil)
	defer os.change_mode(web, {.Read_User, .Write_User, .Execute_User})
	// Root, or Windows, whose read-only attribute on a folder guards nothing in it,
	// can still delete from it, so nothing would be left over.
	if os.make_directory(fmt.tprintf("%s/probe", web)) == nil {
		log.warn("skipped: a read-only folder does not stop a delete here")
		return
	}
	confirm(t, &r, "Clean up", "Delete")
	testing.expect(
		t,
		settle(&r, "Deleted 0 folders and freed 65.5 kB; 1 could not be deleted in full"),
		"what went is freed, and the folder is not counted deleted",
	)
	testing.expect(t, !os.exists(fmt.tprintf("%s/node_modules/lib", web)), "its insides went")
	testing.expect(t, os.exists(fmt.tprintf("%s/node_modules", web)), "the folder did not")
	testing.expect(t, settle(&r, WEB_NODE_MODULES), "so it stays in the list")
}

@(test)
reclaim_empties_the_trash_it_found :: proc(t: ^testing.T) {
	// The home, and so its Trash, is the test's own.
	root := projects(t, "reclaim_trash")
	defer os.remove_all(root)
	// A trashed file and what records it: the freedesktop.org Trash keeps the file
	// in files and a record in info; the Finder's keeps the file itself, and here
	// a trashed folder stands in for the record. The record is a block long: NTFS
	// keeps a file of a few bytes inside its MFT record, taking no space of its own.
	when ODIN_OS == .Darwin {
		TRASH  :: ".Trash"
		FILE   :: TRASH + "/old.bin"
		RECORD :: TRASH + "/folder"
		DIRS   :: []string{TRASH, RECORD}
	} else {
		TRASH  :: ".local/share/Trash"
		FILE   :: TRASH + "/files/old.bin"
		RECORD :: TRASH + "/info"
		DIRS   :: []string{".local", ".local/share", TRASH, TRASH + "/files", RECORD}
	}
	for d in DIRS {
		testing.expect(t, os.make_directory(fmt.tprintf("%s/%s", root, d)) == nil)
	}
	old := make([]byte, 16 * 1024, context.temp_allocator)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, FILE), old) == nil)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/%s/old.bin.trashinfo", root, RECORD), old[:4096]) ==
		nil,
	)
	sync.guard(&trash_env)
	// What package home reads the home from: Windows names a profile, not HOME.
	HOME :: "USERPROFILE" when ODIN_OS == .Windows else "HOME"
	home := strings.clone(os.get_env(HOME, context.temp_allocator), context.temp_allocator)
	testing.expect(t, os.set_env(HOME, root) == nil)
	defer os.set_env(HOME, home)

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
	testing.expect(t, !ui.probe_tagged(&r.p, "All Trash"), "as a button, not a row")

	confirm(t, &r, "Empty Trash", "Empty")
	testing.expect(t, settle(&r, "Emptied the Trash and freed 20.5 kB"), "the notice says so")
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", root, FILE)))
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", root, RECORD)))
	testing.expect(t, os.exists(fmt.tprintf("%s/%s", root, TRASH)), "the Trash stays")
	testing.expect(t, os.exists(fmt.tprintf("%s/web/node_modules", root)), "cleaning is separate")
}

// tagged_from is the first name tagged that starts with prefix, cloned since the
// frame's names go with it, once a frame has one, as settle waits; or "".
@(private = "file")
tagged_from :: proc(r: ^Rig, prefix: string) -> string {
	find :: proc(r: ^Rig, prefix: string) -> string {
		for t in ui.probe_current(&r.p).tags {
			if strings.has_prefix(t.name, prefix) {
				return strings.clone(t.name, context.temp_allocator)
			}
		}
		return ""
	}
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for time.tick_now()._nsec < deadline {
		if name := find(r, prefix); name != "" {
			return name
		}
		if ui.inbox_pending(&r.h.inbox) {
			ui.inbox_drain(&r.h.inbox, &r.p.layout)
			ui.probe_frame(&r.p)
			hand_on(r)
		}
		time.sleep(time.Millisecond)
	}
	return ""
}

@(test)
a_rescan_is_compared_with_the_scan_before :: proc(t: ^testing.T) {
	dir, _ := os.temp_directory(context.temp_allocator)
	root := fmt.tprintf("%s/leita_gui_compare", dir)
	kept := fmt.tprintf("%s/leita_gui_compare_kept/history.db", dir)
	os.remove_all(root)
	os.remove_all(fmt.tprintf("%s/leita_gui_compare_kept", dir))
	defer os.remove_all(root)
	defer os.remove_all(fmt.tprintf("%s/leita_gui_compare_kept", dir))
	write :: proc(t: ^testing.T, path: string, size: int) {
		body := make([]byte, size, context.temp_allocator)
		slice.fill(body, 'x')
		testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
	}
	for d in ([]string{"", "a", "b", "c"}) {
		testing.expect(t, os.make_directory(fmt.tprintf("%s/%s", root, d)) == nil)
	}
	write(t, fmt.tprintf("%s/a/one.bin", root), 2 << 20)
	write(t, fmt.tprintf("%s/b/two.bin", root), 3 << 20)

	r: Rig
	rig_open(&r, root, kept)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "5.2 MB in 3 items"))
	testing.expect(t, ui.probe_click(&r.p, "Change"))
	press_and_hand_on(&r)
	testing.expect(
		t,
		settle(
			&r,
			"No earlier scan of this folder yet: the next scan will be compared with this one",
		),
		"the first scan has nothing to compare with",
	)

	// a doubles, b empties, and c is new.
	write(t, fmt.tprintf("%s/a/more.bin", root), 2 << 20)
	testing.expect(t, os.remove(fmt.tprintf("%s/b/two.bin", root)) == nil)
	write(t, fmt.tprintf("%s/c/new.bin", root), 3 << 19)
	// Progress is answered apart from history, so Rescan may not have replaced
	// Stop yet; and the legend's new line lays out over a few frames. The click
	// waits for both.
	testing.expect(t, settle(&r, "Done"), "the scan finished")
	first := r.m.generation
	testing.expect(t, choose(&r, "Rescan"))
	hand_on(&r)
	testing.expect(
		t,
		settle(&r, "5.8 MB in 3 items · +524.3 kB since then"),
		"the total says what it grew by",
	)
	testing.expect(t, r.m.generation > first, "from a new scan")
	testing.expect(t, settle(&r, "+2.1 MB"), "a grew")
	testing.expect(t, settle(&r, "−3.1 MB"), "b shrank")
	testing.expect(t, settle(&r, "new"), "c is new")
	since := tagged_from(&r, "Since ")
	testing.expect(t, since != "", "the legend names the scan compared with")

	// Comparing with nothing takes the changes away.
	testing.expect(t, ui.probe_click(&r.p, since))
	press_and_hand_on(&r)
	press_and_hand_on(&r)
	testing.expect(t, ui.probe_click(&r.p, "None"), "the menu offers none")
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, "5.8 MB in 3 items"))
	testing.expect(t, settle(&r, "+2.1 MB", present = false))
	testing.expect(t, settle(&r, "Compare with…"))
}

/*
A directory to scan with a chart near the most a sunburst draws: ten folders of
ten of seven, each of those holding one folder of one 4 KiB file. Every ring's
arcs are equal and wide enough to draw, so it lays out 10 + 100 + 700 + 700 + 700
arcs.
*/
@(private = "file")
big_fixture :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_gui_%s", dir, name)
	os.remove_all(root)
	body := make([]byte, 4096, context.temp_allocator)
	slice.fill(body, 'x')
	ok := os.make_directory(root) == nil
	for a in 0 ..< 10 {
		pa := fmt.tprintf("%s/a%d", root, a)
		ok &&= os.make_directory(pa) == nil
		for b in 0 ..< 10 {
			pb := fmt.tprintf("%s/b%d", pa, b)
			ok &&= os.make_directory(pb) == nil
			for c in 0 ..< 7 {
				pc := fmt.tprintf("%s/c%d", pb, c)
				pd := fmt.tprintf("%s/d", pc)
				ok &&= os.make_directory(pc) == nil
				ok &&= os.make_directory(pd) == nil
				ok &&= os.write_entire_file(fmt.tprintf("%s/e", pd), body) == nil
			}
		}
	}
	testing.expect(t, ok, "could not make the big fixture")
	return root
}

// A big chart says only its top layer to a screen reader, its folders closed,
// and logs what a frame of all it draws costs.
@(test)
a_big_chart_says_only_its_top_layer :: proc(t: ^testing.T) {
	root := big_fixture(t, "big_chart")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc a0"))
	// The rings are an answer of their own, which can land after the one that says
	// Done: the sunburst keeps where it drew each arc, by node, so it is drawn
	// until it has drawn them all.
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for len(r.m.poses) != 2210 && time.tick_now()._nsec < deadline {
		if ui.inbox_pending(&r.h.inbox) {
			ui.inbox_drain(&r.h.inbox, &r.p.layout)
			hand_on(&r)
		}
		ui.probe_advance(&r.p, 1, 1.0 / 60)
		time.sleep(time.Millisecond)
	}
	ui.probe_advance(&r.p, 60, 1.0 / 60)
	arcs := len(r.m.poses)
	testing.expectf(t, arcs == 2210, "the chart draws %d arcs", arcs)

	said := ui.probe_semantics(&r.p, context.temp_allocator)
	items := strings.count(said, `tree item "`)
	testing.expectf(t, items == 10, "%d items are said:\n%s", items, said)
	testing.expectf(
		t,
		said_after(
			said,
			`tree "Sunburst of leita_gui_big_chart, 2.9 MB, 10 items" at`,
			`  tree item "a`,
		),
		"the chart counts its top layer:\n%s",
		said,
	)
	testing.expect(t, !strings.contains(said, "expanded"), "every folder is closed")

	start := time.tick_now()
	ui.probe_advance(&r.p, 30, 1.0 / 60)
	took := time.tick_since(start)
	log.infof("%d arcs: %v a frame over 30 frames", arcs, took / 30)
}

// said_after is whether, in a semantics report, a line starting with each of
// lines comes straight after one starting with the one before: the first an
// entry, the rest what nests under it as indented.
@(private = "file")
said_after :: proc(report: string, lines: ..string) -> bool {
	all := strings.split_lines(report, context.temp_allocator)
	for at in 0 ..= len(all) - len(lines) {
		found := true
		for want, i in lines {
			if !strings.has_prefix(all[at + i], want) {
				found = false
				break
			}
		}
		if found {
			return true
		}
	}
	return false
}

@(test)
each_chart_is_a_tree_a_screen_reader_walks :: proc(t: ^testing.T) {
	root := fixture(t, "said")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	ui.probe_advance(&r.p, 60, 1.0 / 60)

	// Each chart is a tree named for what it shows, its top layer the directory's
	// own entries: photos, closed, so big.raw within it is not said, then notes.txt.
	photos := `  tree item "photos, 270.3 kB, 98.5% of leita_gui_said" level 1 expandable at`
	notes := `  tree item "notes.txt, 4.1 kB, 1.5% of leita_gui_said" level 1 at`
	for chart in ([?]string{"Sunburst", "Treemap", "Icicle"}) {
		if chart != "Sunburst" {
			testing.expect(t, ui.probe_click(&r.p, chart))
			press_and_hand_on(&r)
			ui.probe_advance(&r.p, 60, 1.0 / 60)
		}
		said := ui.probe_semantics(&r.p, context.temp_allocator)
		tree := fmt.tprintf(`tree "%s of leita_gui_said, 274.4 kB, 2 items" at`, chart)
		testing.expectf(
			t,
			said_after(said, tree, photos, notes),
			"the %s says its top layer:\n%s",
			chart,
			said,
		)
	}

	// Coloured by type, each entry says its kind too.
	testing.expect(t, ui.probe_click(&r.p, "Type"))
	press_and_hand_on(&r)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	kind := `  tree item "notes.txt, 4.1 kB, 1.5% of leita_gui_said, Text" level 1 at`
	said := ui.probe_semantics(&r.p, context.temp_allocator)
	testing.expectf(t, said_after(said, kind), "notes.txt says its kind:\n%s", said)

	// The entry a hovered row lights is selected, as it is lit.
	row := ui.probe_bounds(&r.p, "notes.txt")
	ui.probe_move(&r.p, row.x + 24, row.y + row.h / 2)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	lit := `  tree item "notes.txt, 4.1 kB, 1.5% of leita_gui_said, Text" level 1 selected at`
	said = ui.probe_semantics(&r.p, context.temp_allocator)
	testing.expectf(t, said_after(said, lit), "the lit entry is selected:\n%s", said)

	// big.raw lies in photos, which is closed: photos is selected for it. The
	// largest files are an answer of their own, so it is awaited.
	testing.expect(t, settle(&r, under(root, "photos", "big.raw")))
	row = ui.probe_bounds(&r.p, "big.raw")
	ui.probe_move(&r.p, row.x + 24, row.y + row.h / 2)
	ui.probe_advance(&r.p, 3, 1.0 / 60)
	hidden := `  tree item "photos, 270.3 kB, 98.5% of leita_gui_said, Folder" level 1 selected expandable at`
	said = ui.probe_semantics(&r.p, context.temp_allocator)
	testing.expectf(t, said_after(said, hidden), "the folder it is in is selected:\n%s", said)
}

// labelled_node is the id of the semantic node in the current frame whose label
// starts with prefix, or 0.
@(private = "file")
labelled_node :: proc(r: ^Rig, prefix: string) -> ops.Area_Id {
	for n in ui.probe_current(&r.p).nodes {
		if strings.has_prefix(n.semantics.label, prefix) {
			return n.id
		}
	}
	return 0
}

// A reader opens a folder of the chart's tree with its expand action, which
// says the folder's own entries under it, and closes it with collapse.
@(test)
a_reader_opens_and_closes_a_folder_of_the_chart :: proc(t: ^testing.T) {
	root := fixture(t, "said_open")
	defer os.remove_all(root)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"))
	ui.probe_advance(&r.p, 60, 1.0 / 60)

	photos := labelled_node(&r, "photos, ")
	testing.expect(t, photos != 0, "photos is an item of the tree")
	testing.expect_value(t, labelled_node(&r, "big.raw, "), ops.Area_Id(0))

	// As the platform's bridge pushes a reader's expand.
	ui.router_push(&r.p.router, {kind = .Expand, area = photos})
	ui.probe_frame(&r.p)
	ui.probe_frame(&r.p)
	said := ui.probe_semantics(&r.p, context.temp_allocator)
	testing.expectf(
		t,
		strings.contains(said, `level 1 expandable expanded at`),
		"photos says it is open:\n%s",
		said,
	)
	testing.expectf(
		t,
		strings.contains(said, `    tree item "big.raw, 262.1 kB`),
		"and its files under it:\n%s",
		said,
	)

	ui.router_push(&r.p.router, {kind = .Collapse, area = photos})
	ui.probe_frame(&r.p)
	ui.probe_frame(&r.p)
	testing.expect_value(t, labelled_node(&r, "big.raw, "), ops.Area_Id(0))
}

// A made-up disk's paths can name real files, so no request about one reaches
// the disk: it is refused before anything is tried, and nothing is audited.
@(test)
a_made_up_disk_changes_nothing_on_disk :: proc(t: ^testing.T) {
	s: Scan
	s.engine = .Synthetic
	words := new(msg.Strings)
	defer free(words)
	msg.init(words, .English)
	d := Desk {
		scan  = &s,
		words = words,
	}
	defer delete(d.notice.text)
	requests := []command.Command {
		command.Trash{entry = {node = 1}},
		command.Rename{entry = {node = 1}},
		command.Clean{},
		command.Empty_Trash{},
		command.Locate{entry = {node = 1}},
	}
	for &c in requests {
		act(&d, &c)
		testing.expectf(t, d.notice.failed, "%v is refused", c)
		testing.expect_value(
			t,
			d.notice.text,
			"Nothing was changed: this disk is made up, so its files are not on disk",
		)
	}
}

// saved_as is the path of a report a notice says was saved as a file ending
// in ext, the latest shown, once a frame shows one; "" if none does in time.
@(private = "file")
saved_as :: proc(r: ^Rig, ext: string) -> string {
	PREFIX :: "Saved report to "
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for time.tick_now()._nsec < deadline {
		#reverse for t in ui.probe_current(&r.p).tags {
			if strings.has_prefix(t.name, PREFIX) && strings.has_suffix(t.name, ext) {
				return strings.clone(t.name[len(PREFIX):], context.temp_allocator)
			}
		}
		if ui.inbox_pending(&r.h.inbox) {
			ui.inbox_drain(&r.h.inbox, &r.p.layout)
			ui.probe_frame(&r.p)
			hand_on(r)
		}
		time.sleep(time.Millisecond)
	}
	return ""
}

// An Export writes a report of the finished scan in each format into the
// folder reports go to, named for the target, and a second of the same kind
// beside the first rather than over it. It runs under jm's debug allocator,
// which the desk thread inherits: the test runner's tracking allocator does
// not see a block freed at the wrong size, as each notice and report path was.
@(test)
export_writes_a_report_of_each_format :: proc(t: ^testing.T) {
	da: debug.Allocator
	debug.init(&da, context.allocator)
	defer debug.destroy(&da)
	context.allocator = debug.allocator(&da)
	defer testing.expect_value(t, debug.issue_count(&da), 0)
	root := fixture(t, "export")
	defer os.remove_all(root)
	// A project's installed dependencies, for Reclaim to find.
	testing.expect(t, os.make_directory(fmt.tprintf("%s/app", root)) == nil)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/app/node_modules", root)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/app/package.json", root), "{}") == nil)
	module := make([]byte, 64 << 10, context.temp_allocator)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/app/node_modules/x.js", root), module) == nil,
	)
	reports := fmt.tprintf("%s-reports", root)
	os.remove_all(reports)
	testing.expect(t, os.make_directory(reports) == nil)
	defer os.remove_all(reports)
	data, kept := trial_data(t, root)
	defer os.remove_all(data)
	r: Rig
	rig_open(&r, root, kept = kept, reports = reports)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))

	exts := [command.Export_Format]string {
		.Csv  = ".csv",
		.Json = ".json",
		.Html = ".html",
		.Pdf  = ".pdf",
	}
	for format in command.Export_Format {
		stream.port_send(
			r.h.cmd_port,
			command.Command(
				command.Export{generation = r.m.generation, format = format, reclaim = true},
			),
		)
		path := saved_as(&r, exts[format])
		if !testing.expectf(t, path != "", "a %v report was saved", format) {
			continue
		}
		testing.expectf(
			t,
			strings.has_prefix(path, under(reports, "leita-report-leita_gui_export-")),
			"%s is in the folder, named for the target",
			path,
		)
		data, err := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, err == nil, "the report is there")
		text := string(data)
		switch format {
		case .Csv:
			testing.expect(t, strings.has_prefix(text, "\xef\xbb\xbfsection,"), "a CSV")
			testing.expect(t, strings.contains(text, "big.raw"), "it names the files")
		case .Json:
			v, jerr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
			testing.expect_value(t, jerr, json.Error.None)
			top := v.(json.Object)
			testing.expect_value(t, top["schema"].(json.String), "leita.report/1")
			// Reclaim was asked for, and found the dependencies.
			groups := top["reclaim"].(json.Object)["groups"].(json.Array)
			if testing.expect_value(t, len(groups), 1) {
				group := groups[0].(json.Object)
				testing.expect_value(t, group["category"].(json.String), "dependencies")
				item := group["items"].(json.Array)[0].(json.Object)
				testing.expect_value(
					t,
					item["path"].(json.String),
					under(root, "app", "node_modules"),
				)
			}
		case .Html:
			testing.expect(t, strings.has_prefix(text, "<!doctype html>"), "an HTML page")
		case .Pdf:
			testing.expect(t, strings.has_prefix(text, "%PDF-1.7"), "a PDF")
			testing.expect(t, strings.has_suffix(text, "%%EOF\n"), "written whole")
		}
	}

	// Another PDF: in the same minute it is named -2, in the next one a name of
	// its own; either way one more file, none replaced.
	before, _ := os.read_all_directory_by_path(reports, context.temp_allocator)
	stream.port_send(
		r.h.cmd_port,
		command.Command(command.Export{generation = r.m.generation, format = .Pdf}),
	)
	ui.probe_advance(&r.p, 400, 1.0 / 60) // the earlier toasts time out
	testing.expect(t, saved_as(&r, ".pdf") != "", "the second PDF was saved")
	after, _ := os.read_all_directory_by_path(reports, context.temp_allocator)
	testing.expect_value(t, len(after), len(before) + 1)
}

// The settings menu's Export opens a dialog for the format, then the save dialog in
// the reports folder with a name for the target, filtered to the format; the
// report goes where the person chose, over what was there, which the save
// dialog asked them about, and the notice of the file saved offers Locate.
@(test)
the_export_dialog_saves_a_report_where_chosen_and_offers_locate :: proc(t: ^testing.T) {
	root := fixture(t, "export_dialog")
	defer os.remove_all(root)
	reports := fmt.tprintf("%s-reports", root)
	os.remove_all(reports)
	testing.expect(t, os.make_directory(reports) == nil)
	defer os.remove_all(reports)
	chosen := fmt.tprintf("%s/mine.html", reports)
	testing.expect(t, os.write_entire_file(chosen, "an older report") == nil)
	trial, kept := trial_data(t, root)
	defer os.remove_all(trial)
	r: Rig
	rig_open(&r, root, kept = kept, reports = reports)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))

	testing.expect(t, choose(&r, "Export"), "the menu offers Export")
	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, "Export report"), "the dialog opened")
	testing.expect(t, ui.probe_tagged(&r.p, "Pages to print or attach to a ticket"), "PDF first")
	testing.expect(t, ui.probe_click(&r.p, "HTML"))
	ui.probe_frame(&r.p)
	testing.expect(t, ui.probe_tagged(&r.p, "One page that opens in any browser"))
	testing.expect(t, ui.probe_click_top(&r.p, "Export"), "the dialog's Export")
	q, asked := ui.probe_picking(&r.p)
	testing.expect(t, asked, "the save dialog opened")
	testing.expect_value(t, q.kind, ui.Pick_Kind.Save)
	testing.expect_value(t, q.start, reports)
	testing.expectf(
		t,
		strings.has_prefix(q.name, "leita-report-leita_gui_export_dialog-") &&
		strings.has_suffix(q.name, ".html"),
		"%s is named for the target and the format",
		q.name,
	)
	testing.expect_value(t, len(q.filters), 1)
	if len(q.filters) == 1 {
		testing.expect_value(t, q.filters[0], ui.Pick_Filter{"Web page", "html;htm"})
	}
	testing.expect(t, open_settings(&r))
	testing.expect(t, ui.probe_tagged(&r.p, "Exporting…"), "busy while it asks where")
	r.m.settings_open = false

	testing.expect(t, ui.probe_pick(&r.p, chosen))
	ui.probe_frame(&r.p)
	hand_on(&r)
	path := saved_as(&r, ".html")
	testing.expect_value(t, path, chosen)
	data, err := os.read_entire_file(chosen, context.temp_allocator)
	testing.expect(
		t,
		err == nil && strings.has_prefix(string(data), "<!doctype html>"),
		"the report replaced the older one",
	)
	listed, _ := os.read_all_directory_by_path(reports, context.temp_allocator)
	testing.expect_value(t, len(listed), 1)
	testing.expect(t, !r.m.export_open, "the dialog closed")
	testing.expect(t, ui.probe_tagged(&r.p, "Locate"), "the notice offers Locate")
}

// A cancelled save dialog ends the export: nothing is written, nothing is said,
// and the menu reads Export again.
@(test)
a_cancelled_save_dialog_exports_nothing :: proc(t: ^testing.T) {
	root := fixture(t, "export_cancel")
	defer os.remove_all(root)
	reports := fmt.tprintf("%s-reports", root)
	os.remove_all(reports)
	testing.expect(t, os.make_directory(reports) == nil)
	defer os.remove_all(reports)
	data, kept := trial_data(t, root)
	defer os.remove_all(data)
	r: Rig
	rig_open(&r, root, kept = kept, reports = reports)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))

	testing.expect(t, choose(&r, "Export"), "the menu offers Export")
	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_click_top(&r.p, "Export"), "the dialog's Export")
	testing.expect(t, open_settings(&r))
	testing.expect(t, ui.probe_tagged(&r.p, "Exporting…"), "busy while it asks where")
	testing.expect(t, ui.probe_pick(&r.p, ""), "the save dialog was open")
	// The answer lands in one frame, which asks for the next to show it.
	ui.probe_advance(&r.p, 2, 1.0 / 60)
	hand_on(&r)
	testing.expect(t, settle(&r, "Exporting…", present = false), "no longer busy")
	testing.expect(t, ui.probe_tagged(&r.p, "Export"), "Export again")
	r.m.settings_open = false
	ui.probe_advance(&r.p, 60, 1.0 / 60)
	hand_on(&r)
	testing.expect(t, !shows_notice(&r, "Saved report", 0.5), "no notice")
	testing.expect(t, !shows_notice(&r, "Could not", 0.5), "no failure either")
	listed, _ := os.read_all_directory_by_path(reports, context.temp_allocator)
	testing.expect_value(t, len(listed), 0)
}

// shows_notice is whether a frame shows a notice starting with prefix within
// seconds.
@(private = "file")
shows_notice :: proc(r: ^Rig, prefix: string, seconds := 30.0) -> bool {
	deadline := time.tick_now()._nsec + i64(seconds * f64(time.Second))
	for time.tick_now()._nsec < deadline {
		for t in ui.probe_current(&r.p).tags {
			if strings.has_prefix(t.name, prefix) {
				return true
			}
		}
		if ui.inbox_pending(&r.h.inbox) {
			ui.inbox_drain(&r.h.inbox, &r.p.layout)
			ui.probe_frame(&r.p)
			hand_on(r)
		}
		time.sleep(time.Millisecond)
	}
	return false
}

// The settings menu's Export reads Exporting… from the dialog's Export until the
// host's notice says how it went, saved or not, then reads Export again. Where
// no save dialog can open, the report goes to the reports folder under a name
// of its own, or fails to when the folder is not there.
@(test)
export_is_busy_until_it_is_saved_or_fails :: proc(t: ^testing.T) {
	root := fixture(t, "export_busy")
	defer os.remove_all(root)
	reports := fmt.tprintf("%s-reports", root)
	os.remove_all(reports)
	testing.expect(t, os.make_directory(reports) == nil)
	defer os.remove_all(reports)

	export_once :: proc(t: ^testing.T, r: ^Rig, notice: string) {
		testing.expect(t, settle(r, "Done"))
		testing.expect(t, choose(r, "Export"), "the menu offers Export")
		ui.probe_advance(&r.p, 20, 1.0 / 60)
		testing.expect(t, ui.probe_click_top(&r.p, "Export"), "the dialog's Export")
		testing.expect(t, ui.probe_pick_fail(&r.p), "the save dialog was asked for")
		// The command goes with the frame the failure reached; the next is
		// busy before the host has answered.
		ui.probe_frame(&r.p)
		hand_on(r)
		testing.expect(t, open_settings(r))
		testing.expect(t, ui.probe_tagged(&r.p, "Exporting…"), "busy once asked")
		testing.expectf(t, shows_notice(r, notice), "a notice starting %q", notice)
		testing.expect(t, settle(r, "Exporting…", present = false), "no longer busy")
		testing.expect(t, ui.probe_tagged(&r.p, "Export"), "Export again")
		r.m.settings_open = false
	}

	data, kept := trial_data(t, root)
	defer os.remove_all(data)
	saves: Rig
	rig_open(&saves, root, kept = kept, reports = reports)
	export_once(t, &saves, "Saved report to ")
	rig_close(&saves)
	listed, _ := os.read_all_directory_by_path(reports, context.temp_allocator)
	if testing.expect_value(t, len(listed), 1) {
		testing.expectf(
			t,
			strings.has_prefix(listed[0].name, "leita-report-leita_gui_export_busy-"),
			"%s is named for the target in the reports folder",
			listed[0].name,
		)
	}

	// A folder that is not there: the report cannot be saved.
	fails: Rig
	rig_open(&fails, root, kept = kept, reports = fmt.tprintf("%s/missing", reports))
	defer rig_close(&fails)
	export_once(t, &fails, "Could not save the report in ")
}

// A report of a rescan is compared with the scan before, as the window is.
@(test)
an_export_compares_with_the_scan_before :: proc(t: ^testing.T) {
	root := fixture(t, "export_compare")
	defer os.remove_all(root)
	reports := fmt.tprintf("%s-reports", root)
	kept := fmt.tprintf("%s-kept", root)
	for dir in ([]string{reports, kept}) {
		os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil)
	}
	defer os.remove_all(reports)
	defer os.remove_all(kept)
	r: Rig
	rig_open(&r, root, fmt.tprintf("%s/history.db", kept), reports)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(
		t,
		settle(&r, "Read whole: no earlier scan of this place was kept whole"),
		"the status does not say how the first scan read the place",
	)
	first := r.m.generation
	cursor, has_events := changes.now(root)
	added := make([]byte, 2 << 20, context.temp_allocator)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/added.bin", root), added) == nil)
	// The rescan updates from the first scan's tree, and this test asserts that it
	// holds added.bin. fseventsd puts a change in the history 10 ms to 1.2 s after
	// the file is closed (macOS 15.7, 2026-10-13), and a rescan sent sooner reads it
	// only on the next update (changes_darwin.odin), so the rescan waits until a
	// replay names the change.
	if has_events {
		testing.expect(t, named_within(root, cursor, 5 * time.Second), "no replay named root")
	}

	stream.port_send(r.h.cmd_port, command.Command(command.Scan{path = command.text_make(root)}))
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for r.m.generation == first && time.tick_now()._nsec < deadline {
		if ui.inbox_pending(&r.h.inbox) {
			ui.inbox_drain(&r.h.inbox, &r.p.layout)
			ui.probe_frame(&r.p)
			hand_on(&r)
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, settle(&r, "Done"), "the rescan finished")
	stream.port_send(
		r.h.cmd_port,
		command.Command(command.Export{generation = r.m.generation, format = .Json}),
	)
	path := saved_as(&r, ".json")
	data, err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, err == nil, "the report was saved") {
		return
	}
	v, _ := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	top := v.(json.Object)
	compared, ok := top["compared"].(json.Object)
	if !testing.expect(t, ok, "it is compared with the first scan") {
		return
	}
	taken, _ := compared["taken"].(json.String)
	testing.expect(t, strings.has_prefix(taken, "20"), "it says when the first was taken")
	// The first held all but the file added since, which it never saw.
	totals := top["totals"].(json.Object)
	testing.expect_value(
		t,
		compared["bytes"].(json.Integer),
		totals["bytes"].(json.Integer) - (2 << 20),
	)
	grown := top["largest_files"].(json.Array)[0].(json.Object)
	testing.expect_value(t, grown["path"].(json.String), under(root, "added.bin"))
	testing.expect(t, grown["bytes_before"].(json.Null) == nil, "the added file is new")
}

/*
named_within asks what changed in place since cursor every 100 ms until the answer
names place itself or cannot name directories, a probe or a rescan, which read what
changed without waiting; false when within passes first.
*/
@(private = "file")
named_within :: proc(place: string, cursor: changes.Cursor, within: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < within {
		set, _, err := changes.since(place, cursor)
		named :=
			err == nil &&
			(set.probe ||
					set.rescan ||
					slice.contains(set.shallow[:], place) ||
					slice.contains(set.deep[:], place))
		changes.change_set_destroy(&set)
		if named {
			return true
		}
		time.sleep(100 * time.Millisecond)
	}
	return false
}

/*
Signer stands in for Librium: a key pair made for the test, and the licence it
signs for the terms TERMS give, as the server mints one.
*/
@(private = "file")
Signer :: struct {
	priv: ed25519.Private_Key,
	pub:  [ed25519.PUBLIC_KEY_SIZE]byte,
	line: string, // in the heap allocator, for the server's threads
}

@(private = "file")
TERMS :: `{"licensee": "Acme Ltd", "tier": "team", "order": "ord_7", "issued": "2026-10-11"}`

@(private = "file")
signer_make :: proc(t: ^testing.T) -> (s: Signer) {
	context.random_generator = crypto.random_generator()
	testing.expect(t, ed25519.private_key_generate(&s.priv))
	ed25519.private_key_public_bytes(&s.priv, s.pub[:])
	signed := strings.concatenate(
		{
			licence.PREFIX,
			base64.encode(transmute([]byte)string(TERMS), allocator = context.temp_allocator),
		},
		context.temp_allocator,
	)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&s.priv, transmute([]byte)signed, sig[:])
	s.line = fmt.aprintf(
		"%s.%s",
		signed,
		base64.encode(sig[:], allocator = context.temp_allocator),
		allocator = runtime.heap_allocator(),
	)
	return
}

// open_licence opens the licence dialog from the settings menu's item. The item
// asks the host for the licence once the menu opens, so the click waits for its
// answer.
@(private = "file")
open_licence :: proc(t: ^testing.T, r: ^Rig, name := "Licence") {
	testing.expect(t, open_settings(r) && settle(r, name), "the menu offers the licence")
	testing.expect(t, ui.probe_click_top(&r.p, name))
	ui.probe_advance(&r.p, 20, 1.0 / 60)
}

// offer pastes text into the licence dialog's field and adds it.
@(private = "file")
offer :: proc(t: ^testing.T, r: ^Rig, text: string) {
	ui.text_set(&r.m.licence_text, "")
	testing.expect(t, ui.probe_click(&r.p, "Licence to add"))
	ui.probe_type(&r.p, text)
	ui.probe_frame(&r.p)
	testing.expect(t, ui.probe_click_top(&r.p, "Add licence"))
	hand_on(r)
}

// The key opens the licence dialog: free for personal use, with Buy. What is
// neither a key nor a licence is refused and says why; a licence opened from a
// file signed with the key leita checks against is taken, kept beside the
// history store, and read back when leita next starts.
@(test)
a_licence_is_checked_kept_and_read_back :: proc(t: ^testing.T) {
	root := fixture(t, "licence")
	defer os.remove_all(root)
	data := fmt.tprintf("%s-data", root)
	os.remove_all(data)
	defer os.remove_all(data)
	kept := fmt.tprintf("%s/history.db", data)
	s := signer_make(t)
	defer delete(s.line, runtime.heap_allocator())
	file := fmt.tprintf("%s.licence", root)
	defer os.remove(file)
	testing.expect(t, os.write_entire_file(file, fmt.tprintf("%s\n", s.line)) == nil)

	{
		r: Rig
		rig_open(&r, root, kept = kept, licence_key = s.pub[:])
		defer rig_close(&r)
		testing.expect(t, settle(&r, "Done"))
		open_licence(t, &r)
		testing.expect(t, ui.probe_click(&r.p, "Buy a licence"))
		ui.probe_frame(&r.p)
		testing.expect_value(t, ui.probe_opened_url(&r.p), view.BUY_URL)

		offer(t, &r, "not a licence")
		testing.expect(
			t,
			settle(
				&r,
				"That is not a licence key: paste the key from your receipt, or a licence beginning leita1.",
			),
			"what is neither a key nor a licence says why",
		)
		offer(t, &r, "leita1.e30=.AAAA")
		testing.expect(
			t,
			settle(
				&r,
				"The licence is not a Leita licence; paste the whole line, from leita1. to its end.",
			),
			"a broken licence says why",
		)

		testing.expect(t, ui.probe_click(&r.p, "Open licence file…"))
		ui.probe_frame(&r.p)
		testing.expect(t, ui.probe_pick(&r.p, file))
		ui.probe_frame(&r.p)
		hand_on(&r)
		testing.expect(t, settle(&r, "Licensed to Acme Ltd"), "the licence from the file is taken")
		testing.expect(t, settle(&r, "Team, up to 50 people · order ord_7 · issued 2026-10-11"))
		testing.expect(t, os.exists(fmt.tprintf("%s/licence", data)), "and kept")
	}

	// leita starts again and runs under the licence kept.
	r: Rig
	rig_open(&r, root, kept = kept, licence_key = s.pub[:])
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	open_licence(t, &r, "Licence")
	testing.expect(t, settle(&r, "Licensed to Acme Ltd"), "the licence kept is read back")
}

// answer_activate answers /activate as the licence server does: the licence for the one
// key it sold, and a refusal for any other.
@(private = "file")
answer_activate :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	s := (^Signer)(conn.server.user)
	switch {
	case req.method == "POST" &&
	     req.path == "/activate" &&
	     strings.contains(req.body, `"key":"LEITA-SOLD"`):
		loopback.send(
			conn,
			fmt.tprintf(
				"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s\n",
				len(s.line) + 1,
				s.line,
			),
		)
	case req.path == "/activate":
		refusal := "This licence key is not one the shop sold.\nmore detail"
		loopback.send(
			conn,
			fmt.tprintf(
				"HTTP/1.1 404 Not Found\r\nContent-Length: %d\r\n\r\n%s",
				len(refusal),
				refusal,
			),
		)
	case:
		loopback.send(conn, "HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n")
	}
}

// A licence key is exchanged once for its licence: one the shop did not sell
// is refused with the shop's reason, a server that fails or cannot be reached
// says so, and the key it sold brings back the licence, which is taken.
@(test)
a_licence_key_is_exchanged_for_its_licence :: proc(t: ^testing.T) {
	root := fixture(t, "licence_key")
	defer os.remove_all(root)
	data := fmt.tprintf("%s-data", root)
	os.remove_all(data)
	defer os.remove_all(data)
	s := signer_make(t)
	defer delete(s.line, runtime.heap_allocator())
	srv, up := loopback.start(answer_activate, &s, runtime.heap_allocator())
	if !testing.expect(t, up, "the shop's server started") {
		return
	}
	defer loopback.stop(srv)

	{
		// Assumes nothing listens on port 9, discard, of the loopback, as on a
		// machine running no discard service.
		r: Rig
		rig_open(
			&r,
			root,
			kept = fmt.tprintf("%s/history.db", data),
			licence_key = s.pub[:],
			activate_url = "http://127.0.0.1:9/activate",
		)
		defer rig_close(&r)
		testing.expect(t, settle(&r, "Done"))
		open_licence(t, &r)
		offer(t, &r, "LEITA-SOLD")
		testing.expect(
			t,
			settle(
				&r,
				"Leita could not reach the licence server. Check the connection, or open the licence file from your receipt instead.",
			),
			"an unreachable server says so",
		)
	}

	r: Rig
	rig_open(
		&r,
		root,
		kept = fmt.tprintf("%s/history.db", data),
		licence_key = s.pub[:],
		activate_url = loopback.url(srv, "/activate"),
	)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	open_licence(t, &r)
	offer(t, &r, "LEITA-UNSOLD")
	testing.expect(
		t,
		settle(&r, "This licence key is not one the shop sold."),
		"the shop's reason, its first line",
	)
	testing.expect(t, !r.h.desk.licensed)

	offer(t, &r, "LEITA-SOLD")
	testing.expect(t, settle(&r, "Licensed to Acme Ltd"), "the key brings back its licence")
	kept, read_err := os.read_entire_file(fmt.tprintf("%s/licence", data), context.temp_allocator)
	testing.expect(t, read_err == nil, "which is kept")
	testing.expect_value(t, strings.trim_space(string(kept)), s.line)
	testing.expect_value(t, ui.text_string(&r.m.licence_text), "")
}

// For thirty days from when leita first ran here, reports and change tracking
// work without a licence. After that an unlicensed copy says the trial is over;
// Export and colouring by change open the licence dialog saying why, and the
// host writes no report; under a licence both work again.
@(test)
reports_and_change_tracking_need_a_licence_after_the_trial :: proc(t: ^testing.T) {
	root := fixture(t, "trial")
	defer os.remove_all(root)
	data := fmt.tprintf("%s-data", root)
	os.remove_all(data)
	defer os.remove_all(data)
	testing.expect(t, os.make_directory(data) == nil)
	kept := fmt.tprintf("%s/history.db", data)
	s := signer_make(t)
	defer delete(s.line, runtime.heap_allocator())
	ENDED :: "Your 30-day trial of reports and change tracking has ended"

	{
		// The first run starts the trial: both work, and nothing is said.
		r: Rig
		rig_open(&r, root, kept = kept, licence_key = s.pub[:])
		defer rig_close(&r)
		testing.expect(t, settle(&r, "Done"))
		ui.probe_advance(&r.p, 10, 1.0 / 60)
		testing.expect(t, !ui.probe_tagged(&r.p, ENDED))
		testing.expect(t, os.exists(fmt.tprintf("%s/first-use", data)))
		testing.expect(t, ui.probe_click(&r.p, "Change"))
		ui.probe_advance(&r.p, 10, 1.0 / 60)
		testing.expect_value(t, r.m.colour, view.Colouring.Change)
		testing.expect(t, choose(&r, "Export"))
		ui.probe_advance(&r.p, 20, 1.0 / 60)
		testing.expect(t, ui.probe_tagged(&r.p, "Export report"), "the export dialog opens")
	}

	month := time.to_unix_seconds(time.now()) - 31 * 24 * 60 * 60
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/first-use", data), fmt.tprintf("%d\n", month)) == nil,
	)
	{
		r: Rig
		rig_open(&r, root, kept = kept, licence_key = s.pub[:])
		defer rig_close(&r)
		testing.expect(t, settle(&r, "Done"))
		testing.expect(t, settle(&r, ENDED), "a month on, it says the trial is over")
		testing.expect(t, ui.probe_click(&r.p, "Dismiss banner"))
		ui.probe_advance(&r.p, 10, 1.0 / 60)
		testing.expect(t, !ui.probe_tagged(&r.p, ENDED), "dismissed, it goes")

		testing.expect(t, choose(&r, "Export"))
		ui.probe_advance(&r.p, 20, 1.0 / 60)
		testing.expect(
			t,
			ui.probe_tagged(
				&r.p,
				"Exporting reports needs a licence now the 30-day trial has ended.",
			),
			"Export says why",
		)
		testing.expect(t, !ui.probe_tagged(&r.p, "Export report"))
		r.m.licence_open = false
		ui.probe_advance(&r.p, 20, 1.0 / 60)

		testing.expect(t, ui.probe_click(&r.p, "Change"))
		ui.probe_advance(&r.p, 20, 1.0 / 60)
		testing.expect(
			t,
			ui.probe_tagged(
				&r.p,
				"Seeing what changed since the last scan needs a licence now the 30-day trial has ended. Leita still keeps every scan, so it is all there once you add one.",
			),
			"colouring by change says why",
		)
		testing.expect_value(t, r.m.colour, view.Colouring.Folder)

		// Whatever the window sends, the host writes no report.
		reports := fmt.tprintf("%s-reports", root)
		defer os.remove_all(reports)
		stream.port_send(
			r.h.cmd_port,
			command.Command(
				command.Export {
					generation = r.m.generation,
					format = .Json,
					path = command.text_make(fmt.tprintf("%s.json", reports)),
				},
			),
		)
		testing.expect(
			t,
			settle(&r, "Exporting reports needs a licence now the 30-day trial has ended."),
		)
		testing.expect(t, !os.exists(fmt.tprintf("%s.json", reports)))
	}

	testing.expect(t, licence.save(fmt.tprintf("%s/licence", data), s.line) == .None)
	r: Rig
	rig_open(&r, root, kept = kept, licence_key = s.pub[:])
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	testing.expect(t, !ui.probe_tagged(&r.p, ENDED), "a licensed copy says nothing")
	testing.expect(t, ui.probe_click(&r.p, "Change"))
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	testing.expect_value(t, r.m.colour, view.Colouring.Change)
	testing.expect(t, choose(&r, "Export"))
	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, "Export report"), "under a licence, Export works")
}

// The settings menu's Language lists the languages by their own names; choosing one switches
// the window from the next frame, and the host words what it says next in it,
// here why a licence key was refused.
@(test)
the_language_menu_switches_the_window_and_the_host :: proc(t: ^testing.T) {
	root := fixture(t, "language")
	defer os.remove_all(root)
	de := new(msg.Strings)
	defer free(de)
	msg.init(de, .German)
	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))

	testing.expect(t, choose(&r, "Language"))
	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, "日本語"), "each language by its own name")
	testing.expect(t, ui.probe_click_top(&r.p, "Deutsch"))
	// The frame after the choice tells the host.
	press_and_hand_on(&r)
	testing.expect(t, settle(&r, msg.tr(de, .Done)), "the window speaks German")
	testing.expect(t, !ui.probe_tagged(&r.p, "Done"))

	open_licence(t, &r, msg.tr(de, .Licence))
	testing.expect(t, ui.probe_click(&r.p, msg.tr(de, .Licence_To_Add)))
	ui.probe_type(&r.p, "not a key")
	ui.probe_frame(&r.p)
	testing.expect(t, ui.probe_click_top(&r.p, msg.tr(de, .Add_Licence)))
	hand_on(&r)
	testing.expect(t, settle(&r, msg.tr(de, .Not_A_Key)), "and so does the host")
}

@(test)
the_language_and_theme_chosen_are_there_the_next_run :: proc(t: ^testing.T) {
	root := fixture(t, "settings")
	defer os.remove_all(root)
	kept := fmt.tprintf("%s-kept/history.db", root)
	defer os.remove_all(fmt.tprintf("%s-kept", root))
	de := new(msg.Strings)
	defer free(de)
	msg.init(de, .German)

	{
		r: Rig
		rig_open(&r, root, kept)
		defer rig_close(&r)
		testing.expect(t, settle(&r, "Done"))
		testing.expect(t, !r.m.dark, "light until chosen")
		testing.expect(t, choose(&r, "Language"))
		ui.probe_advance(&r.p, 20, 1.0 / 60)
		testing.expect(t, ui.probe_click_top(&r.p, "Deutsch"))
		press_and_hand_on(&r)
		testing.expect(t, settle(&r, msg.tr(de, .Done)))
		testing.expect(t, choose(&r, msg.tr(de, .Theme_Dark)))
		press_and_hand_on(&r)
		testing.expect(t, r.m.dark)
		testing.expect(
			t,
			settings_hold(kept, settings.THEME, "dark"),
			"the host writes the choice at once",
		)
	}

	r: Rig
	rig_open(&r, root, kept)
	defer rig_close(&r)
	testing.expect(t, settle(&r, msg.tr(de, .Done)), "the next run opens in German")
	testing.expect(t, r.m.dark, "and dark")
	testing.expect_value(t, r.m.locale, i18n.Locale.German)
}

// settings_hold waits for the settings beside kept to hold value under key, as
// another connection sees them.
@(private = "file")
settings_hold :: proc(kept, key, value: string) -> bool {
	st: settings.Store
	if settings.open(&st, licence.path_beside(kept, context.temp_allocator, settings.FILE)) !=
	   nil {
		return false
	}
	defer settings.close(&st)
	deadline := time.tick_now()._nsec + i64(10 * time.Second)
	for time.tick_now()._nsec < deadline {
		if v, ok := settings.get(&st, key, context.temp_allocator); ok && v == value {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// A term typed while the made-up disk is read is answered while it is read,
// ranked, and answered again, complete, once the scan is done.
@(test)
a_search_typed_during_a_scan_refines_until_it_is_done :: proc(t: ^testing.T) {
	sync.rw_mutex_lock(&scan_env)
	defer sync.rw_mutex_unlock(&scan_env)
	testing.expect(t, os.set_env(scan.SYNTHETIC_ENV, "12") == nil)
	defer os.unset_env(scan.SYNTHETIC_ENV)
	r: Rig
	rig_open(&r, "/", made_up = true)
	defer rig_close(&r)

	testing.expect(t, open_settings(&r))
	testing.expect(t, settle(&r, "Stop"), "the scan is running")
	r.m.settings_open = false
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	testing.expect(t, ui.probe_click(&r.p, "Search"), "the magnifier")
	ui.probe_advance(&r.p, 2, 1.0 / 60)
	ui.probe_type(&r.p, "cache")
	ui.probe_frame(&r.p)
	hand_on(&r)
	testing.expect(t, settle(&r, "cache"), "hits arrive")
	said := ui.probe_semantics(&r.p, context.temp_allocator)
	testing.expectf(t, strings.contains(said, `"Scanning"`), "while the scan runs:\n%s", said)
	during := summary_of(&r)
	testing.expectf(t, strings.has_prefix(during, "The best 500 of "), "a total: %q", during)
	// The hits come best first: a folder that is the term heads the list.
	testing.expect_value(t, first_hit(&r), "cache")
	// The summary changes width every tick; the layout switch stays inside.
	layout := ui.probe_bounds(&r.p, "Layout")
	testing.expectf(t, layout.x + layout.w <= r.p.size.x, "the switch fits: %v", layout)

	testing.expect(t, settle(&r, "Done"), "the scan finished")
	// Once complete, the total is what the whole disk holds: more than during.
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for summary_of(&r) == during && time.tick_now()._nsec < deadline {
		settle(&r, "never there")
	}
	after := summary_of(&r)
	testing.expectf(t, after != during, "the total grew from %q", during)
	testing.expect_value(t, first_hit(&r), "cache")

	// Return opens the best as the system would; a made-up disk's are not
	// there to open, and the window says so.
	ui.probe_key(&r.p, .Enter)
	hand_on(&r)
	testing.expect(
		t,
		settle(&r, "Could not open it: this disk is made up, so its files are not on disk"),
		"the made-up disk's files are not opened",
	)
}

// summary_of is the search's summary as the frame shows it, "" for none.
@(private = "file")
summary_of :: proc(r: ^Rig) -> string {
	for tag in ui.probe_current(&r.p).tags {
		if strings.has_prefix(tag.name, "The best ") {
			return strings.clone(tag.name, context.temp_allocator)
		}
	}
	return ""
}

// first_hit is the topmost hit's name: of the names the frame tags, the one
// placed nearest the top below the search's summary.
@(private = "file")
first_hit :: proc(r: ^Rig) -> string {
	under := ui.probe_bounds(&r.p, "Layout")
	top, name := f32(1e9), ""
	for tag in ui.probe_current(&r.p).tags {
		b := ui.probe_bounds(&r.p, tag.name)
		if b.h > 0 && b.y > under.y + under.h && b.y < top {
			top, name = b.y, tag.name
		}
	}
	return strings.clone(name, context.temp_allocator)
}

// A hit double-clicked, and one picked and given Return, are opened as the
// system opens them, by their paths; one the system would not open is said in
// a notice. A stand-in gio, first on PATH, writes down what it was given and
// exits as told.
@(test)
a_search_hit_opens_as_the_system_would :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		return
	}
	dir, _ := os.temp_directory(context.temp_allocator)
	info, _ := os.stat(dir, context.temp_allocator)
	root := fmt.tprintf("%s/leita_open_hit", info.fullpath)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil)
	defer os.remove_all(root)
	notes := fmt.tprintf("%s/notes.txt", root)
	testing.expect(
		t,
		os.write_entire_file(notes, make([]byte, 4096, context.temp_allocator)) == nil,
	)

	bin := fmt.tprintf("%s-bin", root)
	os.remove_all(bin)
	testing.expect(t, os.make_directory(bin) == nil)
	defer os.remove_all(bin)
	given := fmt.tprintf("%s/given", bin)
	exit := fmt.tprintf("%s/exit", bin)
	stand_in := fmt.tprintf("%s/gio", bin)
	script := fmt.tprintf(
		"#!/bin/sh\nprintf '%%s' \"$2\" > '%s'\nread code < '%s'\nexit \"$code\"\n",
		given,
		exit,
	)
	testing.expect(t, os.write_entire_file(stand_in, script) == nil)
	testing.expect(t, os.chmod(stand_in, {.Read_User, .Write_User, .Execute_User}) == nil)
	testing.expect(t, os.write_entire_file(exit, "0") == nil)
	path := os.get_env("PATH", context.temp_allocator)
	testing.expect(t, os.set_env("PATH", fmt.tprintf("%s:%s", bin, path)) == nil)
	defer os.set_env("PATH", path)

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"), "the scan finished")
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	testing.expect(t, ui.probe_click(&r.p, "Search"), "the magnifier")
	ui.probe_advance(&r.p, 2, 1.0 / 60)
	ui.probe_type(&r.p, "notes")
	ui.probe_frame(&r.p)
	hand_on(&r)
	testing.expect(t, settle(&r, "1 match"), "the search is answered")

	// opened is what the stand-in was given, once it has been.
	opened := proc(given: string) -> string {
		deadline := time.tick_now()._nsec + i64(10 * time.Second)
		for time.tick_now()._nsec < deadline {
			got, err := os.read_entire_file(given, context.temp_allocator)
			if err == nil && len(got) > 0 {
				os.remove(given)
				return string(got)
			}
			time.sleep(5 * time.Millisecond)
		}
		return ""
	}

	// A double click, its commands handed on after each frame, as
	// jm:ui/shell's frame loop hands them on (ui.data_after_frame).
	at := ui.probe_bounds(&r.p, "notes.txt")
	centre := ops.Point{at.x + at.w / 2, at.y + at.h / 2}
	for clicks in u8(1) ..= 2 {
		ui.router_push(&r.p.router, {kind = .Press, pos = centre, button = .Left, clicks = clicks})
		ui.probe_frame(&r.p)
		hand_on(&r)
		ui.router_push(&r.p.router, {kind = .Release, pos = centre, button = .Left})
		ui.probe_frame(&r.p)
		hand_on(&r)
	}
	testing.expect_value(t, opened(given), notes)

	// Return on the picked hit.
	ui.probe_key(&r.p, .Enter)
	hand_on(&r)
	testing.expect_value(t, opened(given), notes)

	testing.expect(t, os.write_entire_file(exit, "2") == nil)
	ui.probe_key(&r.p, .Enter)
	hand_on(&r)
	testing.expect(t, settle(&r, "Could not open notes.txt"), "a failure is said")
}

// Schedule_Calls are what the system's scheduler was asked, as a test's scheduler
// records it on the desk's thread.
@(private = "file")
Schedule_Calls :: struct {
	mutex:    sync.Mutex,
	commands: [dynamic]string,
}

@(private = "file")
schedule_record :: proc(argv: []string, user: rawptr) -> schedule.Outcome {
	s := (^Schedule_Calls)(user)
	sync.guard(&s.mutex)
	append(&s.commands, strings.join(argv, " ", runtime.heap_allocator()))
	return {ok = true}
}

// The pulse opens Monitoring, whose field holds the place scanned. Watch watches
// it daily, the switch hands the monitor to the scheduler, as this binary, and
// says where; Stop watching and the switch take each back. The dialog is drawn
// light and dark to build/test.
@(test)
monitoring_watches_a_place_and_hands_it_to_the_scheduler :: proc(t: ^testing.T) {
	root := fixture(t, "monitor")
	defer os.remove_all(root)
	data := fmt.tprintf("%s-data", root)
	os.remove_all(data)
	defer os.remove_all(data)
	kept := fmt.tprintf("%s/history.db", data)
	rec: Schedule_Calls
	defer {
		for c in rec.commands {
			delete(c, runtime.heap_allocator())
		}
		delete(rec.commands)
	}
	rec.commands = make([dynamic]string, runtime.heap_allocator())
	host := schedule.Host {
		run    = schedule_record,
		user   = &rec,
		system = .Systemd,
		units  = fmt.tprintf("%s/units", data),
	}
	timer := fmt.tprintf("%s/leita-monitor.timer", host.units)

	r: Rig
	rig_open(&r, root, kept = kept, scheduler = &host, monitor_argv = {"/usr/bin/leita"})
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, choose(&r, "Monitoring"), "the menu offers monitoring")
	ui.probe_frame(&r.p)
	hand_on(&r)
	testing.expect(t, settle(&r, "No place is watched yet."))
	testing.expect_value(t, ui.text_string(&r.m.watch_text), root)

	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_click_top(&r.p, "Watch"))
	hand_on(&r)
	testing.expect(t, settle(&r, "Not scanned yet"), "the place scanned is watched")
	testing.expect(t, settle(&r, fmt.tprintf("Stop watching %s", root)))
	testing.expect_value(t, ui.text_string(&r.m.watch_text), "")

	testing.expect(t, ui.probe_click(&r.p, "Off"), "the switch is off")
	hand_on(&r)
	testing.expect(t, settle(&r, "Run every hour by the systemd user timer leita-monitor.timer."))
	timer_text, _ := os.read_entire_file(timer, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(string(timer_text), "OnCalendar=hourly\n"),
		"the timer is written",
	)
	service, _ := os.read_entire_file(
		fmt.tprintf("%s/leita-monitor.service", host.units),
		context.temp_allocator,
	)
	testing.expect(
		t,
		strings.contains(string(service), "ExecStart=/usr/bin/leita monitor run\n"),
		string(service),
	)
	{
		sync.guard(&rec.mutex)
		testing.expect(
			t,
			slice.contains(rec.commands[:], "systemctl --user enable --now leita-monitor.timer"),
		)
	}

	// The bell opens the place's alerts; one set and saved is checked by the
	// next run, whose alert the dialog shows within a few seconds.
	testing.expect(t, ui.probe_click(&r.p, fmt.tprintf("Alerts for %s", root)))
	ui.probe_advance(&r.p, 5, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(&r.p, "Warn at percent used"))
	ui.text_set(&r.m.limit_warn, "1")
	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, render.headless_png(&r.hl, "build/test/monitoring_alerts_editor.png"))
	// Where the recorder's switch is offered, the editor's Save opens below
	// the dialog's fold at this window's height, and a click where Save is
	// laid out but not drawn lands on nothing: the body is scrolled to it
	// first, as a person would.
	testing.expect(t, ui.probe_scroll(&r.p, "Warn at percent used", 10))
	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_click_top(&r.p, "Save"))
	hand_on(&r)
	testing.expect(t, settle(&r, "Warn at percent used", false), "the editor closes")
	out := strings.builder_make(context.temp_allocator)
	code := monitor.run(
		{paths = monitor.paths_beside(kept, context.temp_allocator), now = time.now(), all = true},
		strings.to_writer(&out),
	)
	testing.expectf(t, code == 0, "the run: %s", strings.to_string(out))
	testing.expect(t, strings.contains(strings.to_string(out), "alert:"), strings.to_string(out))
	testing.expect(t, settle(&r, "Alert"), "the place is marked")
	testing.expect(t, settle(&r, "Recent alerts"))

	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, render.headless_png(&r.hl, "build/test/monitoring_light.png"))
	r.m.dark = true
	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, render.headless_png(&r.hl, "build/test/monitoring_dark.png"))
	r.m.dark = false

	testing.expect(t, ui.probe_click(&r.p, fmt.tprintf("Stop watching %s", root)))
	hand_on(&r)
	testing.expect(t, settle(&r, "No place is watched yet."))
	testing.expect(t, ui.probe_click(&r.p, "On"), "the switch is on")
	hand_on(&r)
	testing.expect(
		t,
		settle(&r, "Run every hour by the systemd user timer leita-monitor.timer.", false),
	)
	testing.expect(t, !os.exists(timer), "turning it off takes the timer away")
}

// refuse_linger runs a scheduler whose person does not linger, so their user
// timers run only while they are logged in; it does whatever else is asked.
@(private = "file")
refuse_linger :: proc(argv: []string, user: rawptr) -> schedule.Outcome {
	if len(argv) > 0 && argv[0] == "loginctl" {
		return {ok = true, out = "Linger=no\n"}
	}
	return {ok = true}
}

// Where scheduled scans run only while the person is logged in, Monitoring
// says so from the first frame it draws, and goes on saying so as the switch
// is turned and places are watched: the warning neither arrives after the
// dialog nor leaves with the next change, either of which moved everything
// beneath it.
@(test)
monitoring_warns_of_running_only_while_logged_in_from_the_start :: proc(t: ^testing.T) {
	root := fixture(t, "linger")
	defer os.remove_all(root)
	data := fmt.tprintf("%s-data", root)
	os.remove_all(data)
	defer os.remove_all(data)
	host := schedule.Host {
		run    = refuse_linger,
		system = .Systemd,
		units  = fmt.tprintf("%s/units", data),
		login  = "ann",
	}
	note := "Scheduled scans run only while ann is logged in. To run them always: loginctl enable-linger ann"

	r: Rig
	rig_open(
		&r,
		root,
		kept = fmt.tprintf("%s/history.db", data),
		scheduler = &host,
		monitor_argv = {"/usr/bin/leita"},
	)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, choose(&r, "Monitoring"), "the menu offers monitoring")
	ui.probe_frame(&r.p)
	hand_on(&r)
	testing.expect(t, settle(&r, "Watched places"))
	testing.expect(t, ui.probe_tagged(&r.p, note), "the warning is there with the dialog")

	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_click(&r.p, "Off"), "the switch is off")
	hand_on(&r)
	testing.expect(t, settle(&r, "Run every hour by the systemd user timer leita-monitor.timer."))
	testing.expect(t, ui.probe_tagged(&r.p, note), "the warning stays as the switch turns on")

	ui.text_set(&r.m.watch_text, root)
	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_click_top(&r.p, "Watch"))
	hand_on(&r)
	testing.expect(t, settle(&r, "Not scanned yet"), "the place scanned is watched")
	testing.expect(t, ui.probe_tagged(&r.p, note), "the warning stays as a place is watched")
}

// publish_release writes a release as release.yml does for update.asset(.Window):
// the build, its sha256 and the version, in dir.
@(private = "file")
publish_release :: proc(t: ^testing.T, dir, build, version: string) {
	name := update.asset(.Window)
	testing.expect(t, name != "", "a release is built for this platform")
	testing.expect(t, os.make_directory(dir) == nil, "could not make the release")
	digest := hash.hash_string(.SHA256, build, context.temp_allocator)
	sums := fmt.tprintf("%s  %s\n", string(hex.encode(digest, context.temp_allocator)), name)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", dir, name), build) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/sha256sums.txt", dir), sums) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/version.txt", dir), version) == nil)
}

// About asks the release nothing until Check for updates is clicked, then reads
// it where the host was told and says what it holds. A newer release is
// offered as Update when this build can be replaced, or Download otherwise.
// A release that cannot be reached says so.
@(test)
about_checks_the_release_on_request_only :: proc(t: ^testing.T) {
	root := fixture(t, "update")
	defer os.remove_all(root)
	release := fmt.tprintf("%s-release", root)
	defer os.remove_all(release)
	publish_release(t, release, "a newer window", "v9.9.9\n")

	r: Rig
	rig_open(&r, root, release_base = release)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, choose(&r, "About Leita"))
	ui.probe_advance(&r.p, 10, 1.0 / 60)
	hand_on(&r)
	testing.expect(t, settle(&r, "Check for updates"), "About offers the check")
	// Given time to have asked, it has not.
	for _ in 0 ..< 20 {
		ui.probe_advance(&r.p, 5, 1.0 / 60)
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, !ui.probe_tagged(&r.p, "Version v9.9.9 of Leita is available."), "nothing checked on its own")
	testing.expect(t, !ui.probe_tagged(&r.p, "Checking for updates…"))

	testing.expect(t, ui.probe_click_top(&r.p, "Check for updates"))
	hand_on(&r)
	testing.expect(t, settle(&r, "Version v9.9.9 of Leita is available."), "the newer release is named")
	if update.why_not(update.default_config(.Window, version.VERSION)) == .None {
		testing.expect(t, settle(&r, "Update"), "a replaceable build is offered an update in place")
		testing.expect(t, !ui.probe_tagged(&r.p, "Download the update"))
	} else {
		testing.expect(t, settle(&r, "Download the update"), "a build that cannot be replaced is sent to the release page")
		testing.expect(t, !ui.probe_tagged(&r.p, "Update"))
	}

	// The same release when this window's own build is the release's: current.
	exe, exe_err := os.get_executable_path(context.temp_allocator)
	testing.expect(t, exe_err == nil)
	body, read_err := os.read_entire_file(exe, context.temp_allocator)
	testing.expect(t, read_err == nil)
	os.remove_all(release)
	publish_release(t, release, string(body), "v1.0.0\n")
	testing.expect(t, ui.probe_click_top(&r.p, "Check for updates"))
	hand_on(&r)
	testing.expect(t, settle(&r, "This is the latest version of Leita."), "this build is the release's")

	// No release at that base: the failure is said, not a crash or a hang.
	os.remove_all(release)
	testing.expect(t, ui.probe_click_top(&r.p, "Check for updates"))
	hand_on(&r)
	testing.expect(t, settle(&r, "The latest release has no build of Leita for this system."))
}

@(private = "file")
Update_Close_Fixture :: struct {
	host:              ^Host,
	started:           bool, // atomic
	desk_was_stopping: bool, // atomic
}

@(private = "file")
answer_update_on_close :: proc(conn: ^loopback.Conn, _: loopback.Request) {
	f := (^Update_Close_Fixture)(conn.server.user)
	sync.atomic_store(&f.started, true)
	deadline := time.tick_now()._nsec + i64(5 * time.Second)
	for !sync.atomic_load(&f.host.stopping) && time.tick_now()._nsec < deadline {
		if !loopback.pause(conn, time.Millisecond) {
			return
		}
	}
	sync.atomic_store(&f.desk_was_stopping, sync.atomic_load(&f.host.stopping))
	loopback.send(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
}

// Closing during a request first retires the desk, which normally reaps an
// update when its answer arrives. The closing thread then waits for that
// request itself, so two threads cannot reap the same update job.
@(test)
closing_during_an_update_waits_without_racing_the_desk :: proc(t: ^testing.T) {
	root := fixture(t, "update_close")
	defer os.remove_all(root)
	r: Rig
	f := Update_Close_Fixture{host = &r.h}
	srv, up := loopback.start(answer_update_on_close, &f, runtime.heap_allocator())
	if !testing.expect(t, up, "the update server started") {
		return
	}
	defer loopback.stop(srv)
	rig_open(&r, root, release_base = loopback.url(srv, ""))
	stream.port_send(r.h.cmd_port, command.Command(command.Check_Update{}))
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for !sync.atomic_load(&f.started) && time.tick_now()._nsec < deadline {
		time.sleep(time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&f.started), "the check began before closing")
	rig_close(&r)
	testing.expect(t, sync.atomic_load(&f.desk_was_stopping), "the desk stopped accepting answers before the closing thread waited for the request")
	testing.expect(t, r.h.desk.update_thread == nil, "the outstanding update was joined and destroyed")
}

// A folder the walk could not open holds nothing to draw, so the folders above
// it are outlined instead: their totals are short of what is there. The one read
// in full is not.
@(test)
the_folders_above_one_the_walk_could_not_open_are_outlined_on_the_chart :: proc(t: ^testing.T) {
	if ODIN_OS == .Windows {
		return // a folder is not shut by its mode there
	}
	root := fixture(t, "locked")
	locked := fmt.tprintf("%s/locked", root)
	testing.expect(t, os.make_directory(locked) == nil, "could not make locked")
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/secret.dat", locked), []byte{1, 2, 3}) == nil,
	)
	testing.expect(t, os.chmod(locked, {}) == nil, "could not shut locked")
	defer os.remove_all(root)
	defer os.chmod(locked, {.Read_User, .Write_User, .Execute_User})
	if dir, err := os.open(locked); err == nil {
		os.close(dir)
		return // the user it runs as is let in whatever the mode says
	}

	r: Rig
	rig_open(&r, root)
	defer rig_close(&r)
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, settle(&r, "arc photos"), "photos, which the fixture holds, is drawn")
	testing.expect(
		t,
		settle(&r, fmt.tprintf("incomplete %s", filepath.base(root))),
		"the chart is marked short",
	)
	testing.expect(
		t,
		!ui.probe_tagged(&r.p, "incomplete photos"),
		"the folder read in full is not",
	)
}

// While pkexec is out for the recorder the desk keeps answering: a scan asked
// for meanwhile runs, and the change settles when pkexec returns. The stand-in
// for pkexec waits two seconds, then says the request was dismissed.
@(test)
the_recorder_toggle_does_not_hold_the_desk_while_pkexec_asks :: proc(t: ^testing.T) {
	if ODIN_OS != .Linux {
		return // the recorder is Linux's
	}
	root := fixture(t, "recorder")
	defer os.remove_all(root)
	data := fmt.tprintf("%s-data", root)
	os.remove_all(data)
	testing.expect(t, os.make_directory(data) == nil, "could not make the data folder")
	defer os.remove_all(data)
	pkexec := fmt.tprintf("%s/pkexec", data)
	testing.expect(
		t,
		os.write_entire_file(pkexec, transmute([]byte)string("#!/bin/sh\nsleep 2\nexit 126\n")) ==
		nil,
	)
	testing.expect(t, os.chmod(pkexec, {.Read_User, .Write_User, .Execute_User}) == nil)

	r: Rig
	rig_open(
		&r,
		root,
		kept = fmt.tprintf("%s/history.db", data),
		monitor_argv = {"/usr/bin/leita"},
	)
	defer rig_close(&r)
	r.h.desk.monitoring.elevate = pkexec
	testing.expect(t, settle(&r, "Done"))
	testing.expect(t, choose(&r, "Monitoring"), "the menu offers monitoring")
	ui.probe_frame(&r.p)
	hand_on(&r)
	testing.expect(
		t,
		settle(&r, "Record changes as they happen"),
		"the dialog offers the recorder",
	)

	ui.probe_advance(&r.p, 20, 1.0 / 60) // the dialog settles; a press lands where the last frame drew
	began := time.tick_now()
	testing.expect(t, ui.probe_click_top(&r.p, "Record changes as they happen"), "the switch")
	hand_on(&r)
	first := r.m.generation
	stream.port_send(r.h.cmd_port, command.Command(command.Scan{path = command.text_make(root)}))
	testing.expect(t, await_rescan(&r, first), "the desk starts a scan while pkexec asks")
	asked := time.tick_since(began)
	testing.expectf(
		t,
		asked < 1500 * time.Millisecond,
		"the scan began after %v, with pkexec held",
		asked,
	)
	testing.expect(t, settle(&r, "Done"), "and finishes")

	testing.expect(
		t,
		settle(
			&r,
			"Could not change the recorder: the request for administrator rights was dismissed",
		),
		"the change settles when pkexec returns",
	)
	testing.expect(t, time.tick_since(began) >= 2 * time.Second, "not before it did")
}
