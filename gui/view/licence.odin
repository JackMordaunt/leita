package leita_view


import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../../version"
import "../command"
import "../msg"
import "../query"

/*
The licence. Licence in the settings menu opens a dialog that says whose licence leita
runs under, or that scanning and cleanup are free, with a link to buy Pro. The
key from the shop's receipt is pasted into its field, or a licence itself, or a
licence is opened from a file; the host exchanges a key for its licence, checks
the licence, and the dialog shows the licence it now runs under, or why it would
not take it. The key is the one thing leita sends, once, and the dialog says so.
*/

// BUY_URL is where Buy a licence goes, unless LEITA_BUY_URL names another, as
// for the shop's sandbox.
BUY_URL :: "https://mordaunt.dev/leita/buy"

// licence_item is the settings menu's Licence, named for the licence leita runs
// under. Returns true on the frame it is chosen.
@(private)
licence_item :: proc(gtx: ^ui.Ctx, menu: ^primer.Action_Menu) -> bool {
	r, _ := ui.need(gtx, query.Licence{}, query.Licence_Result)
	licensed := r != nil && r.licensed
	return primer.action_menu_item(menu, tr(.Licence), leading = .Verified if licensed else .Key)
}

// licence_show opens the licence dialog, saying why first when a paid feature
// sent the person there.
@(private)
licence_show :: proc(m: ^Model, why: Maybe(msg.Msg) = nil) {
	m.licence_open = true
	m.licence_why = why
	m.licence_waiting = nil
	m.licence_answered = false
}

/*
unlocked is whether Pro works, as the host last said: this build's
paid-through grant, or the 30-day evaluation. On the first frame, before the
host can have said,
they do, so the window does not open on a lock it then takes away. After it, no
answer means locked: a host that never answers must not leave them open.
*/
@(private)
unlocked :: proc(gtx: ^ui.Ctx, m: ^Model) -> bool {
	r, _ := ui.need(gtx, query.Licence{}, query.Licence_Result)
	if r == nil {
		return !m.drawn
	}
	return r.unlocked
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
		{content = tr(.Close), clicked = &close},
		{
			content = tr(.Adding) if r.activating else tr(.Add_Licence),
			type = .Primary,
			clicked = &add,
			loading = r.activating,
			disabled = pasted == "" || r.activating,
		},
	}
	if primer.dialog(gtx, &m.licence_open, tr(.Licence), footer = buttons[:], width = .Medium) {
		ui.column(gtx, gap = 16, align = .Fill)
		if why, ok := m.licence_why.?; ok && !r.unlocked {
			primer.inline_message(gtx, locked_text(gtx, why), .Warning)
		}
		if r.licensed {
			primer.heading(gtx, licensed_to(gtx, r), level = 2, variant = .Small)
			primer.text(
				gtx,
				trf(gtx, .Licence_Details, r.tier, r.order, r.issued),
				.Small,
				color = primer.color(.Fg_Color_Muted),
			)
		} else {
			primer.text(gtx, tr(.Licence_Terms))
			if r.trial_left > 0 {
				primer.text(gtx, trial_left(gtx, r), .Small, color = primer.color(.Fg_Color_Muted))
			}
			if ui.row(gtx) {
				if primer.button(gtx, tr(.Buy_Licence), .Primary, trailing = .Link_External) {
					ui.open_url(gtx, m.buy_url if m.buy_url != "" else BUY_URL)
				}
			}
		}
		problem := r.problem if m.licence_answered else ""
		if primer.form_control(
			gtx,
			tr(.Replace_Licence) if r.licensed else tr(.Add_A_Licence),
			caption = tr(.Licence_Caption),
			validation = problem,
		) {
			primer.text_input(
				gtx,
				&m.licence_text,
				placeholder = tr(.Licence_Key),
				block = true,
				validation = .Error if problem != "" else .None,
				name = tr(.Licence_To_Add),
			)
		}
		primer.text(
			gtx,
			trf(gtx, .Licence_Privacy, version.PRODUCT),
			.Small,
			color = primer.color(.Fg_Color_Muted),
		)
		if ui.row(gtx) {
			if primer.button(gtx, tr(.Open_Licence_File), leading = .File) {
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

// licensed_to says whose licence leita runs under.
@(private)
licensed_to :: proc(gtx: ^ui.Ctx, r: ^query.Licence_Result) -> string {
	return trf(gtx, .Licensed_To, r.licensee)
}

// trial_left says how long the trial of the paid features has left.
@(private)
trial_left :: proc(gtx: ^ui.Ctx, r: ^query.Licence_Result) -> string {
	return trf(gtx, .Trial_Left, r.trial_left)
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
trial_banner says, once the trial is over and leita runs under no licence, who
may keep using it, in the same words as the licence dialog. Dismissed, it stays
away until leita next starts.
*/
@(private)
trial_banner :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, _ := ui.need(gtx, query.Licence{}, query.Licence_Result)
	if r == nil || r.unlocked || m.trial_seen {
		return
	}
	switch primer.banner(
		gtx,
		tr(.Trial_Ended_Title),
		tr(.Trial_Ended_Body),
		.Upsell,
		primary = tr(.Buy_Licence),
		secondary = tr(.Add_A_Licence),
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

// locked_text says why a paid feature opened the licence dialog once the trial
// is over: .Reports_Locked for Export, .Change_Locked for colouring by change.
@(private)
locked_text :: proc(gtx: ^ui.Ctx, why: msg.Msg) -> string {
	return trf(gtx, why, version.PRODUCT)
}

// LICENCE_PICK is the area the file dialog answers, as EXPORT_PICK is.
@(private)
LICENCE_PICK :: ops.Area_Id(0x6c65_6974_616c_6963) // "leitalic"
