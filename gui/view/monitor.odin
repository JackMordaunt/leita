package leita_view

import "core:fmt"
import "core:strconv"
import "core:strings"

import "jm:ui"
import "jm:ui/primer"

import "../../human"
import "../../version"
import "../command"
import "../msg"
import "../query"

/*
Monitoring, a paid feature. The toolbar's pulse opens a dialog with one switch,
Scheduled scans, that hands the monitor to the system's scheduler or takes it
back, then the places watched, each with how often it is scanned and how its
last scan went, and a field to watch another, which opens holding the place
scanned now. Once the trial is over without a licence, the dialog says so and
only lets monitoring be turned off and places removed.
*/

// monitor_button is the toolbar's pulse, which opens the Monitoring dialog.
@(private)
monitor_button :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	if primer.icon_button(gtx, .Pulse, tr(.Monitoring), .Invisible) {
		m.monitor_open = true
		m.monitor_answered = false
		if ui.text_string(&m.watch_text) == "" && prog != nil {
			ui.text_set(&m.watch_text, prog.target)
		}
	}
}

// EVERY_WORDS name each schedule, in query.Frequency's order, which is the select's.
@(private, rodata)
EVERY_WORDS := [query.Frequency]msg.Msg {
	.Hourly = .Every_Hourly,
	.Daily  = .Every_Daily,
	.Weekly = .Every_Weekly,
}

// monitor_dialog is the Monitoring dialog, while it is open.
@(private)
monitor_dialog :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if !m.monitor_open {
		return
	}
	r, _ := ui.need(gtx, query.Monitor{}, query.Monitor_Result)
	if r == nil {
		return
	}
	if sent, ok := m.monitor_sent.?; ok && r.changed != sent {
		m.monitor_sent = nil
		m.monitor_answered = true
		if r.problem == "" {
			ui.text_set(&m.watch_text, "")
			ui.text_set(&m.hook_text, "")
			m.hook_paths = false
		}
	}
	locked := !unlocked(gtx)
	waiting := m.monitor_sent != nil
	close := false
	buttons := [1]primer.Dialog_Button{{content = tr(.Close), clicked = &close}}
	if primer.dialog(
		gtx,
		&m.monitor_open,
		tr(.Monitoring),
		footer = buttons[:],
		width = .XLarge,
		height = .Large,
	) {
		ui.column(gtx, gap = 16, align = .Fill)
		if locked {
			primer.inline_message(gtx, tr(.Monitoring_Locked), .Warning)
		}
		if ui.row(gtx, gap = 12, align = .Center) {
			ui.flexible(gtx, 1)
			if ui.column(gtx, gap = 4) {
				primer.text(gtx, tr(.Scheduled_Scans), weight = .Semibold)
				primer.text(
					gtx,
					trf(gtx, .Monitoring_Explain, version.NAME),
					.Small,
					color = primer.color(.Fg_Color_Muted),
				)
			}
			on := r.on
			if primer.toggle_switch(
				gtx,
				&on,
				name = tr(.Scheduled_Scans),
				label_on = tr(.On),
				label_off = tr(.Off),
				state = .Disabled if waiting || (locked && !r.on) else .Live,
			) {
				send_monitor(gtx, m, r, command.Monitoring{on = on}, .Switch)
			}
		}
		if r.on {
			primer.text(
				gtx,
				trf(gtx, .Monitoring_Through, r.scheduler),
				.Small,
				color = primer.color(.Fg_Color_Muted),
			)
		}
		problem_here(gtx, m, r, .Switch)
		if r.note != "" {
			primer.inline_message(gtx, r.note, .Warning)
		}
		primer.heading(gtx, tr(.Watched_Places), level = 2, variant = .Small)
		if len(r.watched) == 0 {
			primer.text(gtx, tr(.Watched_None), color = primer.color(.Fg_Color_Muted))
		}
		for w, i in r.watched {
			watched_row(gtx, m, r, w, i)
			if m.limits_open && m.limits_place == w.place {
				limits_editor(gtx, m, r, w)
			}
		}
		watch_field(gtx, m, r, locked)
		problem_here(gtx, m, r, .Places)
		recent_alerts(gtx, r)
		webhooks(gtx, m, r, locked)
	}
	if close {
		m.monitor_open = false
	}
}

// watched_row is one place watched: its path, how often it is scanned, a button
// to stop watching it, and how its last scan went.
@(private)
watched_row :: proc(
	gtx: ^ui.Ctx,
	m: ^Model,
	r: ^query.Monitor_Result,
	w: query.Watched_Place,
	i: int,
) {
	s := ui.scope_open(gtx, u64(i + 1))
	defer ui.scope_close(&s)
	ui.column(gtx, gap = 4, align = .Fill)
	if ui.row(gtx, gap = 8, align = .Center) {
		ui.flexible(gtx, 1)
		primer.truncate(gtx, w.place, title = w.place, max_width = ui.INF, weight = .Semibold)
		if w.alerting {
			primer.label(gtx, tr(.Alerting), .Danger)
		}
		options := make([]primer.Select_Option, len(query.Frequency), gtx.allocator)
		for e in query.Frequency {
			options[int(e)] = {
				label = tr(EVERY_WORDS[e]),
			}
		}
		at := int(w.every)
		if primer.select(
			gtx,
			options,
			&at,
			size = .Small,
			name = trf(gtx, .Schedule_Of, w.place),
		) {
			c := watch_of(w)
			c.every = u8(at)
			send_monitor(gtx, m, r, c)
		}
		if primer.icon_button(
			gtx,
			.Bell,
			trf(gtx, .Limits_Of, w.place),
			.Invisible,
			size = .Small,
		) {
			limits_show(m, w)
		}
		if primer.icon_button(
			gtx,
			.Trash,
			trf(gtx, .Stop_Watching, w.place),
			.Invisible,
			size = .Small,
		) {
			send_monitor(gtx, m, r, command.Unwatch{path = command.text_make(w.place)})
		}
	}
	primer.text(gtx, last_run_text(gtx, w), .Small, color = primer.color(.Fg_Color_Muted))
}

// last_run_text says how a place's last scan went.
@(private)
last_run_text :: proc(gtx: ^ui.Ctx, w: query.Watched_Place) -> string {
	switch {
	case !w.scanned:
		return tr(.Not_Scanned_Yet)
	case w.problem != "":
		return trf(gtx, .Last_Scan_Failed, taken_text(w.started, gtx.allocator), w.problem)
	}
	return trf(
		gtx,
		.Last_Scanned,
		taken_text(w.started, gtx.allocator),
		human.bytes(w.bytes),
		fmt.aprintf("%.1f", w.seconds, allocator = gtx.allocator),
	)
}

// watch_field is the field that names another place to watch, daily.
@(private)
watch_field :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Monitor_Result, locked: bool) {
	ui.row(gtx, gap = 8, align = .Center)
	ui.flexible(gtx, 1)
	typed := ui.text_string(&m.watch_text)
	edit := primer.text_input(
		gtx,
		&m.watch_text,
		placeholder = tr(.Watch_Placeholder),
		block = true,
		name = tr(.Watch_Place),
		state = .Disabled if locked else .Live,
	)
	add := primer.button(
		gtx,
		tr(.Watch),
		leading = .Plus,
		state = .Disabled if locked || typed == "" else .Live,
	)
	if (add || edit.submitted) && !locked && typed != "" && len(typed) <= command.MAX_PATH {
		send_monitor(
			gtx,
			m,
			r,
			command.Watch{path = command.text_make(typed), every = u8(query.Frequency.Daily)},
		)
	}
}

// Monitor_Part is a part of the dialog a change was asked from, where the host's
// answer, should it refuse, is shown.
Monitor_Part :: enum u8 {
	Places,
	Switch,
	Webhooks,
}

// send_monitor sends a change to monitoring, asked from part, and waits for the
// host to say how it went.
@(private)
send_monitor :: proc(
	gtx: ^ui.Ctx,
	m: ^Model,
	r: ^query.Monitor_Result,
	c: command.Command,
	part := Monitor_Part.Places,
) {
	m.monitor_sent = r.changed
	m.monitor_part = part
	ui.command(gtx, c)
}

// watch_of is the Watch that leaves w as it is, for a change to one part.
@(private)
watch_of :: proc(w: query.Watched_Place) -> command.Watch {
	return {
		path = command.text_make(w.place),
		every = u8(w.every),
		warn_used = w.warn_used,
		fail_used = w.fail_used,
		min_free = w.min_free,
		full_within = w.full_within,
		growth = w.growth,
	}
}

// limits_show opens the alerts editor under w, or closes it when it is open
// there, its fields holding what w is checked against.
@(private)
limits_show :: proc(m: ^Model, w: query.Watched_Place) {
	if m.limits_open && m.limits_place == w.place {
		m.limits_open = false
		return
	}
	m.limits_open = true
	m.limits_bad = false
	delete(m.limits_place)
	m.limits_place = strings.clone(w.place)
	number :: proc(n: int) -> string {
		return fmt.tprint(n) if n > 0 else ""
	}
	ui.text_set(&m.limit_warn, number(w.warn_used))
	ui.text_set(&m.limit_fail, number(w.fail_used))
	ui.text_set(&m.limit_free, human.bytes(w.min_free) if w.min_free > 0 else "")
	ui.text_set(&m.limit_days, number(w.full_within))
	m.limit_growth = w.growth
}

// LIMIT_FIELD is how wide an alert's field is drawn.
@(private)
LIMIT_FIELD :: f32(120)

// limits_editor is what w's scans are checked against, as fields to change:
// each empty for none, saved together.
@(private)
limits_editor :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Monitor_Result, w: query.Watched_Place) {
	ui.inset(gtx, {left = 16})
	ui.column(gtx, gap = 12, align = .Fill)
	primer.text(gtx, trf(gtx, .Limits_Of, w.place), weight = .Semibold)
	field :: proc(gtx: ^ui.Ctx, s: ^ui.Text_State, label: string, bad: bool) {
		if ui.row(gtx, gap = 12, align = .Center) {
			ui.flexible(gtx, 1)
			primer.text(gtx, label, .Small)
			primer.text_input(
				gtx,
				s,
				size = .Small,
				width = LIMIT_FIELD,
				name = label,
				validation = .Error if bad else .None,
			)
		}
	}
	field(gtx, &m.limit_warn, tr(.Warn_Used_Label), m.limits_bad)
	field(gtx, &m.limit_fail, tr(.Fail_Used_Label), m.limits_bad)
	field(gtx, &m.limit_free, tr(.Min_Free_Label), m.limits_bad)
	field(gtx, &m.limit_days, tr(.Full_Within_Label), m.limits_bad)
	primer.checkbox(gtx, &m.limit_growth, tr(.Growth_Label))
	if m.limits_bad {
		primer.inline_message(gtx, tr(.Limits_Invalid), .Critical, .Small)
	} else {
		primer.text(gtx, tr(.Limits_Caption), .Small, color = primer.color(.Fg_Color_Muted))
	}
	if ui.row(gtx, gap = 8) {
		ui.flexible(gtx, 1)
		ui.spacer(gtx, 0)
		if primer.button(gtx, tr(.Cancel), size = .Small) {
			m.limits_open = false
		}
		if primer.button(gtx, tr(.Save), .Primary, size = .Small) {
			c, ok := limits_read(m, w)
			m.limits_bad = !ok
			if ok {
				m.limits_open = false
				send_monitor(gtx, m, r, c)
			}
		}
	}
}

/*
limits_read is the Watch the editor's fields make of w, and whether they all
read: a percent is a whole number from 1 to 100, a size one human.parse_bytes
reads, days a whole number; each empty for none.
*/
@(private)
limits_read :: proc(m: ^Model, w: query.Watched_Place) -> (c: command.Watch, ok: bool) {
	c = watch_of(w)
	whole :: proc(s: ^ui.Text_State, most: int) -> (int, bool) {
		text := strings.trim_space(ui.text_string(s))
		if text == "" {
			return 0, true
		}
		n, read := strconv.parse_int(text, 10)
		return n, read && n >= 1 && n <= most
	}
	c.warn_used = whole(&m.limit_warn, 100) or_return
	c.fail_used = whole(&m.limit_fail, 100) or_return
	c.full_within = whole(&m.limit_days, 36500) or_return
	c.min_free = 0
	if free := strings.trim_space(ui.text_string(&m.limit_free)); free != "" {
		c.min_free = human.parse_bytes(free) or_return
	}
	c.growth = m.limit_growth
	return c, true
}

// recent_alerts is the newest alerts the monitor raised, each when and what.
@(private)
recent_alerts :: proc(gtx: ^ui.Ctx, r: ^query.Monitor_Result) {
	primer.heading(gtx, tr(.Recent_Alerts), level = 2, variant = .Small)
	if len(r.alerts) == 0 {
		primer.text(gtx, tr(.Alerts_None), color = primer.color(.Fg_Color_Muted))
		return
	}
	for a, i in r.alerts {
		s := ui.scope_open(gtx, u64(i + 1))
		defer ui.scope_close(&s)
		if ui.row(gtx, gap = 8, align = .Start) {
			primer.text(
				gtx,
				taken_text(a.raised, gtx.allocator),
				.Small,
				color = primer.color(.Fg_Color_Muted),
			)
			ui.flexible(gtx, 1)
			primer.text(gtx, a.text, .Small)
		}
	}
}

/*
webhooks is the person's own servers each new alert goes to: each with whether
it may carry folder paths, a test, its secret to copy, a button to remove it,
and how its last delivery went; then a field to add another. It says what is
sent, where, and how a server checks it, so the person knows what leaves the
machine before they add one.
*/
@(private)
webhooks :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Monitor_Result, locked: bool) {
	primer.heading(gtx, tr(.Webhooks), level = 2, variant = .Small)
	primer.text(
		gtx,
		trf(gtx, .Webhooks_Explain, version.NAME),
		.Small,
		color = primer.color(.Fg_Color_Muted),
	)
	if len(r.webhooks) == 0 {
		primer.text(gtx, tr(.Webhooks_None), color = primer.color(.Fg_Color_Muted))
	}
	for h, i in r.webhooks {
		s := ui.scope_open(gtx, u64(i + 1))
		defer ui.scope_close(&s)
		if ui.column(gtx, gap = 4, align = .Fill) {
			if ui.row(gtx, gap = 8, align = .Center) {
				ui.flexible(gtx, 1)
				primer.truncate(gtx, h.url, title = h.url, max_width = ui.INF, weight = .Semibold)
				if h.paths {
					primer.label(gtx, tr(.Webhook_Sends_Paths), .Attention)
				}
				if primer.button(
					gtx,
					tr(.Webhook_Testing) if r.testing else tr(.Send_Test),
					size = .Small,
					leading = .Paper_Airplane,
					loading = r.testing,
					state = .Disabled if locked || r.testing else .Live,
					name = trf(gtx, .Send_Test_To, h.url),
				) {
					ui.command(
						gtx,
						command.Command(command.Test_Webhook{url = command.text_make(h.url)}),
					)
				}
				if primer.icon_button(
					gtx,
					.Copy,
					trf(gtx, .Copy_Secret_Of, h.url),
					.Invisible,
					size = .Small,
				) {
					ui.clipboard_write(gtx, h.secret)
				}
				if primer.icon_button(
					gtx,
					.Trash,
					trf(gtx, .Remove_Webhook, h.url),
					.Invisible,
					size = .Small,
				) {
					send_monitor(
						gtx,
						m,
						r,
						command.Remove_Webhook{url = command.text_make(h.url)},
						.Webhooks,
					)
				}
			}
			primer.text(gtx, hook_status(gtx, h), .Small, color = primer.color(.Fg_Color_Muted))
		}
	}
	if ui.row(gtx, gap = 8, align = .Center) {
		ui.flexible(gtx, 1)
		typed := strings.trim_space(ui.text_string(&m.hook_text))
		edit := primer.text_input(
			gtx,
			&m.hook_text,
			placeholder = tr(.Webhook_Url_Placeholder),
			block = true,
			name = tr(.Webhook_Url),
			state = .Disabled if locked else .Live,
		)
		primer.checkbox(gtx, &m.hook_paths, tr(.Webhook_Paths))
		add := primer.button(
			gtx,
			tr(.Add_Webhook),
			leading = .Webhook,
			state = .Disabled if locked || typed == "" else .Live,
		)
		if (add || edit.submitted) && !locked && typed != "" && len(typed) <= command.MAX_PATH {
			send_monitor(
				gtx,
				m,
				r,
				command.Add_Webhook{url = command.text_make(typed), paths = m.hook_paths},
				.Webhooks,
			)
		}
	}
	problem_here(gtx, m, r, .Webhooks)
}

// hook_status says how a webhook's last delivery went, and what waits for it.
@(private)
hook_status :: proc(gtx: ^ui.Ctx, h: query.Hook) -> string {
	said: string
	switch {
	case h.problem != "":
		said = trf(gtx, .Webhook_Failed, h.problem)
	case h.last_sent > 0:
		said = trf(gtx, .Webhook_Last_Sent, taken_text(h.last_sent, gtx.allocator))
	case:
		said = tr(.Webhook_Never)
	}
	if h.waiting > 0 {
		said = strings.concatenate(
			{said, " · ", trf(gtx, .Webhook_Waiting, h.waiting)},
			gtx.allocator,
		)
	}
	return said
}

// problem_here shows why the host refused the last change, under the part of
// the dialog it was asked from.
@(private)
problem_here :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Monitor_Result, part: Monitor_Part) {
	if m.monitor_answered && r.problem != "" && m.monitor_part == part {
		primer.inline_message(gtx, r.problem, .Critical)
	}
}
