package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../command"
import "../query"

@(private = "file")
Monitor_Rig :: struct {
	m: Model,
	h: render.Headless,
}

// monitor_open opens the window on a scan with the Monitoring dialog up, the
// host saying scans are not scheduled.
@(private = "file")
monitor_open :: proc(s: ^Monitor_Rig) {
	model_init(&s.m, "/top")
	s.m.settings_read = true
	s.m.monitor_open = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&s.h, view, &s.m, {1000, 700}, fonts)
	ui.probe_deliver(
		&s.h.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Scanning, target = "/top"},
	)
	ui.probe_deliver(&s.h.p, query.Licence{}, query.Licence_Result{unlocked = true})
	monitor_answer(s, {on = false, scheduler = "systemd"})
	// The dialog is taller than the window now that it carries webhooks, so it
	// scrolls; let it settle, so a click lands where the last frame drew.
	ui.probe_advance(&s.h.p, 30, 1.0 / 60)
}

// monitor_answer is the host answering the Monitoring dialog with r, laid out.
@(private = "file")
monitor_answer :: proc(s: ^Monitor_Rig, r: query.Monitor_Result) {
	ui.probe_deliver(&s.h.p, query.Monitor{}, r)
	ui.probe_frame(&s.h.p)
	ui.probe_frame(&s.h.p)
}

@(private = "file")
monitor_close :: proc(s: ^Monitor_Rig) {
	render.headless_destroy(&s.h)
	model_destroy(&s.m)
}

// The switch's status word: what the dialog says scheduled scans are.
@(private = "file")
say_switch :: proc(p: ^ui.Probe) -> string {
	if ui.probe_tagged(p, "On") {
		return "On"
	}
	if ui.probe_tagged(p, "Off") {
		return "Off"
	}
	return ""
}

// A click on Scheduled scans sends the change and shows it at once; the switch
// holds it, taking no second flip, until the host answers, then shows the
// host's value, which is the same when the change was made and the old one
// when it was refused.
@(test)
scheduled_scans_switch_holds_the_click_until_the_host_answers :: proc(t: ^testing.T) {
	s: Monitor_Rig
	monitor_open(&s)
	defer monitor_close(&s)
	p := &s.h.p

	testing.expect_value(t, say_switch(p), "Off")
	testing.expect(t, ui.probe_click_top(p, "Scheduled scans"), "the switch is clicked")
	c, ok := sent(p, command.Monitoring).?
	testing.expect(t, ok, "the click sends Monitoring")
	testing.expect(t, c.on, "turned on")
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect_value(t, say_switch(p), "On")

	// A second click while the host works sends nothing and changes nothing.
	testing.expect(t, ui.probe_click_top(p, "Scheduled scans"))
	_, again := sent(p, command.Monitoring).?
	testing.expect(t, !again, "no second Monitoring while one is in flight")
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect_value(t, say_switch(p), "On")

	// Made: the switch stays as clicked, and takes the next flip.
	monitor_answer(&s, {on = true, scheduler = "systemd", changed = 1})
	testing.expect_value(t, say_switch(p), "On")
	testing.expect(t, ui.probe_click_top(p, "Scheduled scans"))
	c, ok = sent(p, command.Monitoring).?
	testing.expect(t, ok && !c.on, "the next click turns it off")
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect_value(t, say_switch(p), "Off")

	// Refused: the switch goes back to what the host has.
	monitor_answer(&s, {on = true, scheduler = "systemd", changed = 2, problem = "no"})
	testing.expect_value(t, say_switch(p), "On")
	testing.expect(t, ui.probe_tagged(p, "no"), "the refusal is shown")
}

// The recorder's switch shows only where the host offers it (Linux): a click sends
// Recording and holds until the host answers; installed but not running, the
// dialog says so.
@(test)
recorder_switch_shows_where_offered_and_sends_recording :: proc(t: ^testing.T) {
	s: Monitor_Rig
	monitor_open(&s)
	defer monitor_close(&s)
	p := &s.h.p
	testing.expect(
		t,
		!ui.probe_tagged(p, "Record changes as they happen"),
		"shown where not offered",
	)

	monitor_answer(&s, {scheduler = "systemd", recorder_shown = true})
	testing.expect(
		t,
		ui.probe_tagged(p, "Record changes as they happen"),
		"not shown where offered",
	)
	testing.expect(
		t,
		ui.probe_click_top(p, "Record changes as they happen"),
		"the switch is clicked",
	)
	c, ok := sent(p, command.Recording).?
	testing.expect(t, ok && c.on, "the click sends Recording on")
	testing.expect(t, ui.probe_click_top(p, "Record changes as they happen"))
	_, again := sent(p, command.Recording).?
	testing.expect(t, !again, "no second Recording while one is in flight")

	monitor_answer(
		&s,
		{scheduler = "systemd", changed = 1, recorder_shown = true, recorder_on = true},
	)
	stopped :=
		"The recorder is installed but not running: " +
		"systemctl status leita-journal.service says why."
	testing.expect(t, ui.probe_tagged(p, stopped), "a recorder not running is not said")
	monitor_answer(
		&s,
		{
			scheduler = "systemd",
			changed = 1,
			recorder_shown = true,
			recorder_on = true,
			recorder_running = true,
		},
	)
	testing.expect(t, !ui.probe_tagged(p, stopped), "a running recorder is said to have stopped")
}

// The field's folder button opens the folder dialog where the field points; the
// folder chosen fills the field, and a cancel or a platform with no dialog
// leaves what was typed.
@(test)
watch_field_folder_button_fills_the_field_from_the_folder_dialog :: proc(t: ^testing.T) {
	s: Monitor_Rig
	monitor_open(&s)
	defer monitor_close(&s)
	p := &s.h.p
	ui.text_set(&s.m.watch_text, "/top")
	// The dialog settles where it opens, so the small button is where it is drawn.
	ui.probe_advance(p, 30, 1.0 / 60)

	testing.expect(t, ui.probe_click_top(p, "Choose a folder to watch"), "the folder button")
	q, asked := ui.probe_picking(p)
	testing.expect(t, asked, "the folder dialog opened")
	testing.expect_value(t, q.kind, ui.Pick_Kind.Folder)
	testing.expect_value(t, q.start, "/top")
	testing.expect(t, ui.probe_pick(p, "/some/dir"))
	ui.probe_frame(p)
	testing.expect_value(t, ui.text_string(&s.m.watch_text), "/some/dir")
	_, watched := sent(p, command.Watch).?
	testing.expect(t, !watched, "choosing a folder only fills the field")

	// A cancel leaves the field as it was.
	testing.expect(t, ui.probe_click_top(p, "Choose a folder to watch"))
	q, asked = ui.probe_picking(p)
	testing.expect(t, asked, "the folder dialog opened again")
	testing.expect_value(t, q.start, "/some/dir")
	testing.expect(t, ui.probe_pick(p, ""))
	ui.probe_frame(p)
	testing.expect_value(t, ui.text_string(&s.m.watch_text), "/some/dir")

	// No dialog: the field is still there to type in.
	testing.expect(t, ui.probe_click_top(p, "Choose a folder to watch"))
	testing.expect(t, ui.probe_pick_fail(p))
	ui.probe_frame(p)
	testing.expect_value(t, ui.text_string(&s.m.watch_text), "/some/dir")
}

// The note of how scans will run sits above the switch, so turning scans on,
// which adds the line of where they run, moves nothing above that line.
@(test)
monitoring_note_holds_still_as_scans_turn_on :: proc(t: ^testing.T) {
	s: Monitor_Rig
	monitor_open(&s)
	defer monitor_close(&s)
	p := &s.h.p
	note := "Scans run only while ann is logged in."

	monitor_answer(&s, {on = false, scheduler = "systemd", note = note})
	ui.probe_advance(p, 30, 1.0 / 60)
	before := ui.probe_bounds(p, note)
	switch_before := ui.probe_bounds(p, "Scheduled scans")
	monitor_answer(&s, {on = true, scheduler = "systemd", note = note})
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect(
		t,
		ui.probe_tagged(p, "Run every hour by the systemd."),
		"where scans run shows",
	)
	testing.expect_value(t, ui.probe_bounds(p, note), before)
	testing.expect_value(t, ui.probe_bounds(p, "Scheduled scans"), switch_before)
}

// What sits under the switch comes and goes, where scans run, the refusal of a
// change, a recorder that stopped, each in a slot that holds its height: the
// places and the dialog's buttons stay where they were through every state.
@(test)
places_and_buttons_hold_still_through_every_state_of_the_switch :: proc(t: ^testing.T) {
	s: Monitor_Rig
	monitor_open(&s)
	defer monitor_close(&s)
	p := &s.h.p

	monitor_answer(&s, {on = false, scheduler = "systemd", recorder_shown = true})
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(p, "Would run every hour by the systemd."), "off says where")
	// The footer's Close shares its tag with the title's, so the dialog's own
	// rect stands for the footer: it is as tall as the content above the buttons.
	places := ui.probe_bounds(p, "Watched places")
	alerts := ui.probe_bounds(p, "Recent alerts")
	dialog := ui.probe_bounds(p, "Monitoring")
	testing.expect(t, places.h > 0 && alerts.y > places.y, "the dialog is measured")
	still :: proc(t: ^testing.T, p: ^ui.Probe, places, alerts, dialog: ops.Rect, loc := #caller_location) {
		testing.expect_value(t, ui.probe_bounds(p, "Watched places"), places, loc = loc)
		testing.expect_value(t, ui.probe_bounds(p, "Recent alerts"), alerts, loc = loc)
		testing.expect_value(t, ui.probe_bounds(p, "Monitoring"), dialog, loc = loc)
	}

	// On: the line changes its words, not its height.
	testing.expect(t, ui.probe_click_top(p, "Scheduled scans"))
	monitor_answer(&s, {on = true, scheduler = "systemd", changed = 1, recorder_shown = true})
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(p, "Run every hour by the systemd."), "on says where")
	still(t, p, places, alerts, dialog)

	// Refused: the problem shows in its slot.
	testing.expect(t, ui.probe_click_top(p, "Scheduled scans"))
	monitor_answer(
		&s,
		{on = true, scheduler = "systemd", changed = 2, problem = "no", recorder_shown = true},
	)
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect(t, ui.probe_tagged(p, "no"), "the refusal is shown")
	still(t, p, places, alerts, dialog)

	// A recorder installed but not running: its warning shows in its slot.
	monitor_answer(
		&s,
		{
			on = true,
			scheduler = "systemd",
			changed = 2,
			recorder_shown = true,
			recorder_on = true,
		},
	)
	ui.probe_advance(p, 30, 1.0 / 60)
	stopped :=
		"The recorder is installed but not running: " +
		"systemctl status leita-journal.service says why."
	testing.expect(t, ui.probe_tagged(p, stopped), "the stopped recorder is said")
	still(t, p, places, alerts, dialog)
}
