package leita_view

import "core:fmt"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../command"
import "../query"

/*
The licence. The toolbar's key opens a dialog that says whose licence leita
runs under, or that it runs free for personal use with a link to buy one. The
key from the shop's receipt is pasted into its field, or a licence itself, or a
licence is opened from a file; the host exchanges a key for its licence, checks
the licence, and the dialog shows the licence it now runs under, or why it would
not take it. The key is the one thing leita sends, once, and the dialog says so.
*/

// BUY_URL is where Buy a licence goes, unless LEITA_BUY_URL names another, as
// for the shop's sandbox.
BUY_URL :: "https://mordaunt.dev/leita/buy"

// licence_button is the toolbar's key, which opens the licence dialog.
@(private)
licence_button :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, _ := ui.need(gtx, query.Licence{}, query.Licence_Result)
	licensed := r != nil && r.licensed
	if primer.icon_button(
		gtx,
		.Verified if licensed else .Key,
		"Licence" if licensed else "Licence: free for personal use",
		.Invisible,
	) {
		licence_show(m)
	}
}

// licence_show opens the licence dialog, saying why first when a paid feature
// sent the person there.
@(private)
licence_show :: proc(m: ^Model, why := "") {
	m.licence_open = true
	m.licence_why = why
	m.licence_waiting = nil
	m.licence_answered = false
}

// unlocked is whether the paid features work, as the host last said: under a
// licence, or in the trial. Before it says, they do.
@(private)
unlocked :: proc(gtx: ^ui.Ctx) -> bool {
	r, _ := ui.need(gtx, query.Licence{}, query.Licence_Result)
	return r == nil || r.unlocked
}

// licence_dialog is the licence: whose it is, and a field to give leita another.
@(private)
licence_dialog :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, _ := ui.need(gtx, query.Licence{}, query.Licence_Result)
	for e in ui.events(gtx, LICENCE_PICK) {
		if e.kind == .Picked && e.text != "" && r != nil && len(e.text) <= command.MAX_PATH {
			send_licence(gtx, m, r, e.text, file = true)
		}
	}
	if r != nil {
		if waiting, ok := m.licence_waiting.?; ok && r.offered != waiting {
			m.licence_waiting = nil
			m.licence_answered = true
			if r.problem == "" {
				ui.text_set(&m.licence_text, "")
			}
		}
	}
	if !m.licence_open || r == nil {
		return
	}
	pasted := ui.text_string(&m.licence_text)
	close, add := false, false
	buttons := [2]primer.Dialog_Button {
		{content = "Close", clicked = &close},
		{
			content = "Adding…" if r.activating else "Add licence",
			type = .Primary,
			clicked = &add,
			loading = r.activating,
			disabled = pasted == "" || r.activating,
		},
	}
	if primer.dialog(gtx, &m.licence_open, "Licence", footer = buttons[:], width = .Medium) {
		ui.column(gtx, gap = 16, align = .Fill)
		if m.licence_why != "" && !r.unlocked {
			primer.inline_message(gtx, m.licence_why, .Warning)
		}
		if r.licensed {
			primer.heading(
				gtx,
				fmt.aprintf("Licensed to %s", r.licensee, allocator = gtx.allocator),
				level = 2,
				variant = .Small,
			)
			primer.text(
				gtx,
				fmt.aprintf(
					"%s · order %s · issued %s",
					r.tier,
					r.order,
					r.issued,
					allocator = gtx.allocator,
				),
				.Small,
				color = primer.color(.Fg_Color_Muted),
			)
		} else {
			primer.text(
				gtx,
				"Scanning, the charts and Reclaim are free for personal use. Reports and change tracking need a licence. An organisation needs one for any use once its 30-day evaluation ends.",
			)
			if r.trial_left > 0 {
				primer.text(
					gtx,
					fmt.aprintf(
						"You can try reports and change tracking for %d more %s.",
						r.trial_left,
						"day" if r.trial_left == 1 else "days",
						allocator = gtx.allocator,
					),
					.Small,
					color = primer.color(.Fg_Color_Muted),
				)
			}
			if ui.row(gtx) {
				if primer.button(gtx, "Buy a licence", .Primary, trailing = .Link_External) {
					ui.open_url(gtx, m.buy_url if m.buy_url != "" else BUY_URL)
				}
			}
		}
		problem := r.problem if m.licence_answered else ""
		if primer.form_control(
			gtx,
			"Replace the licence" if r.licensed else "Add a licence",
			caption = "The licence key from your receipt, or a licence beginning leita1.",
			validation = problem,
		) {
			primer.text_input(
				gtx,
				&m.licence_text,
				placeholder = "Licence key",
				block = true,
				validation = .Error if problem != "" else .None,
				name = "Licence to add",
			)
		}
		primer.text(
			gtx,
			"leita sends the key once, to mordaunt.dev, to fetch your licence. It sends nothing else, then or later.",
			.Small,
			color = primer.color(.Fg_Color_Muted),
		)
		if ui.row(gtx) {
			if primer.button(gtx, "Open licence file…", leading = .File) {
				ui.pick_file(gtx, LICENCE_PICK)
			}
		}
	}
	if close {
		m.licence_open = false
	}
	if add && pasted != "" && !r.activating && len(pasted) <= command.MAX_PATH {
		send_licence(gtx, m, r, pasted, file = false)
	}
}

// send_licence offers text: a licence key, a licence, or the path of a file
// holding one.
@(private)
send_licence :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Licence_Result, text: string, file: bool) {
	m.licence_waiting = r.offered
	ui.command(
		gtx,
		command.Command(command.Add_Licence{text = command.text_make(text), file = file}),
	)
}

/*
trial_banner says, once the trial is over and leita runs under no licence, that
reports and change tracking now need one, and that the rest stays free.
Dismissed, it stays away until leita next starts.
*/
@(private)
trial_banner :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, _ := ui.need(gtx, query.Licence{}, query.Licence_Result)
	if r == nil || r.unlocked || m.trial_seen {
		return
	}
	switch primer.banner(
		gtx,
		"Your 30-day trial of reports and change tracking has ended",
		"Scanning, the charts and Reclaim stay free. A licence brings back reports and what changed since the last scan.",
		.Upsell,
		primary = "Buy a licence",
		secondary = "Add a licence",
		dismissible = true,
	) {
	case .Primary:
		ui.open_url(gtx, m.buy_url if m.buy_url != "" else BUY_URL)
	case .Secondary:
		licence_show(m)
	case .Dismiss:
		m.trial_seen = true
	case .None:
	}
}

// REPORTS_LOCKED and CHANGE_LOCKED say why Export and colouring by change open
// the licence dialog once the trial is over.
REPORTS_LOCKED :: "Exporting reports needs a licence now the 30-day trial has ended."
CHANGE_LOCKED  :: "Seeing what changed since the last scan needs a licence now the 30-day trial has ended. leita still keeps every scan, so it is all there once you add one."

// LICENCE_PICK is the area the file dialog answers, as EXPORT_PICK is.
@(private)
LICENCE_PICK :: ops.Area_Id(0x6c65_6974_616c_6963) // "leitalic"
