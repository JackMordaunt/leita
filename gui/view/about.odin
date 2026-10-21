//review:ignore history-coupled-file this layout-only change wraps the existing caption; checkbox commands and existing About assertions are unchanged
package leita_view

import "core:fmt"

import "jm:ui"
import "jm:ui/primer"
import tok "jm:ui/primer/tokens"

import "../../version"
import "../command"
import mark "../mark"
import "../notices"
import "../query"

/*
About: About in the settings menu opens a dialog that says what this is and
whose: the mark and the name, the version, the business that makes it, what
it is for, the licence it runs under as the licence dialog says it, where to
read more, and a link to the licences of what it is built on, which opens a
dialog of every component's notice in its place. Under the version it offers
to check for updates when asked, and to opt in to one check at startup and
one a day. Neither check installs a release.
*/

// BUSINESS is who makes and sells leita, as LICENSE.md names the Licensor.
BUSINESS :: "Librium LLC"

// HOME_URL is the product's page.
HOME_URL :: "https://mordaunt.dev/leita"

// ABOUT_MARK_SIZE is the mark's size in the About dialog.
ABOUT_MARK_SIZE :: 72


// about_dialog is About, over everything while it is open.
@(private)
about_dialog :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if !m.about_open {
		return
	}
	close := false
	buttons := [1]primer.Dialog_Button{{content = tr(.Close), clicked = &close}}
	if primer.dialog(
		gtx,
		&m.about_open,
		trf(gtx, .About, version.PRODUCT),
		footer = buttons[:],
		width = .Medium,
	) {
		ui.column(gtx, gap = 12, align = .Start)
		if ui.row(gtx, gap = 16, align = .Center) {
			about_mark(gtx)
			if ui.column(gtx, gap = 2) {
				title(gtx, version.PRODUCT)
				primer.text(
					gtx,
					trf(gtx, .Version, version.VERSION),
					.Small,
					color = primer.color(.Fg_Color_Muted),
				)
			}
		}
		update_check(gtx, m)
		primer.text(gtx, tr(.Tagline), weight = .Semibold)
		primer.text(gtx, tr(.Explainer))
		if line := licence_line(gtx); line != "" {
			primer.text(gtx, line, .Small, color = primer.color(.Fg_Color_Muted))
		}
		if primer.link(gtx, "mordaunt.dev/leita") {
			ui.open_url(gtx, HOME_URL)
		}
		if primer.link(gtx, tr(.Notices)) {
			m.about_open = false
			m.notices_open = true
		}
		primer.text(
			gtx,
			fmt.aprintf("© %d %s", version.YEAR, BUSINESS, allocator = gtx.allocator),
			.Small,
			color = primer.color(.Fg_Color_Muted),
		)
	}
	if close {
		m.about_open = false
	}
}

/*
update_check is the Check for updates button and what the host found. The
button sends command.Check_Update. A newer release that this copy may take
is Update; one a package owns, or one outside the paid-through date, is
Download, which opens the release page. The checkbox is the opt-in, off
until the person turns it on.
*/
@(private)
update_check :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, _ := ui.need(gtx, query.Update{}, query.Update_Result)
	s, _ := ui.need(gtx, query.Settings{}, query.Settings_Result)
	if s != nil {
		if want, chosen := m.checks_want.?; chosen && want == s.automatic_checks {
			m.checks_want = nil
		}
	}
	state := r.state if r != nil else query.Update_State.Idle
	busy := state == .Checking || state == .Applying
	offer := r != nil && (state == .Available || (state == .Failed && r.problem == .Ineligible))
	may_apply := offer && r.can_apply && r.coverage != .Later && r.coverage != .Unstamped
	if ui.row(gtx, gap = 8, align = .Center) {
		if primer.button(gtx, tr(.Check_Updates), size = .Small, inactive = busy) && !busy {
			ui.command(gtx, command.Command(command.Check_Update{}))
		}
		if offer {
			if may_apply {
				if primer.button(gtx, tr(.Update_Now), .Primary, .Small) {
					ui.command(gtx, command.Command(command.Apply_Update{}))
				}
			} else if primer.button(
				gtx,
				tr(.Download_Update),
				.Primary,
				.Small,
				trailing = .Link_External,
			) {
				ui.open_url(gtx, r.page)
			}
		}
	}
	if line := update_line(gtx, r); line != "" {
		primer.text(gtx, line, .Small, color = primer.color(.Fg_Color_Muted))
	}
	if line := coverage_line(gtx, r); line != "" {
		primer.text(gtx, line, .Small, color = primer.color(.Fg_Color_Muted))
	}
	if line := guidance_line(gtx, r); line != "" && offer {
		primer.text(gtx, line, .Small, color = primer.color(.Fg_Color_Muted))
	}
	if offer && r.latest != "" && primer.link(gtx, tr(.Update_Notes)) {
		ui.open_url(gtx, r.page)
	}
	primer.text(
		gtx,
		trf(gtx, .Update_Privacy, version.PRODUCT),
		.Small,
		color = primer.color(.Fg_Color_Muted),
	)
	on := m.checks_want.? or_else (s != nil && s.automatic_checks)
	if primer.checkbox(
		gtx,
		&on,
		tr(.Automatic_Checks),
	) {
		m.checks_want = on
		ui.command(gtx, command.Command(command.Automatic_Checks{on = on}))
	}
	primer.text(
		gtx,
		trf(gtx, .Automatic_Checks_Caption, version.PRODUCT),
		.Small,
		color = primer.color(.Fg_Color_Muted),
	)
}

// update_notice is the quiet banner for a release the person has not
// dismissed. Download and Update are explicit. Dismiss hides this version.
@(private)
update_notice :: proc(gtx: ^ui.Ctx) {
	r, _ := ui.need(gtx, query.Update{}, query.Update_Result)
	if r == nil || !r.notice || r.latest == "" {
		return
	}
	desc := coverage_line(gtx, r)
	if desc == "" {
		desc = guidance_line(gtx, r)
	}
	may_apply := r.can_apply && r.coverage != .Later && r.coverage != .Unstamped
	primary := tr(.Update_Now) if may_apply else tr(.Download_Update)
	switch primer.banner(
		gtx,
		trf(gtx, .Update_Available, version.PRODUCT, r.latest),
		desc,
		.Info,
		primary = primary,
		secondary = tr(.Update_Notes),
		dismissible = true,
	) {
	case .None:
	case .Primary:
		if may_apply {
			ui.command(gtx, command.Command(command.Apply_Update{}))
		} else if r.page != "" {
			ui.open_url(gtx, r.page)
		}
	case .Secondary:
		if r.page != "" {
			ui.open_url(gtx, r.page)
		}
	case .Dismiss:
		ui.command(
			gtx,
			command.Command(command.Dismiss_Update{version = command.text_make(r.latest)}),
		)
	}
}

// update_line says where the check stands, "" until one is asked for.
@(private)
update_line :: proc(gtx: ^ui.Ctx, r: ^query.Update_Result) -> string {
	if r == nil {
		return ""
	}
	switch r.state {
	case .Idle:
		return ""
	case .Checking:
		return tr(.Checking_Updates)
	case .Current:
		return trf(gtx, .Update_Current, version.PRODUCT)
	case .Available:
		if r.latest == "" {
			return trf(gtx, .Update_Available_Unknown, version.PRODUCT)
		}
		return trf(gtx, .Update_Available, version.PRODUCT, r.latest)
	case .Applying:
		return tr(.Updating)
	case .Applied:
		return trf(gtx, .Update_Applied, version.PRODUCT)
	case .Failed:
		switch r.problem {
		case .No_Library:
			return trf(gtx, .Update_No_Curl, version.PRODUCT)
		case .Unreachable:
			return trf(gtx, .Update_Unreachable, version.PRODUCT)
		case .Not_Published:
			return trf(gtx, .Update_Not_Published, version.PRODUCT)
		case .Ineligible:
			return ""
		case .None, .Other:
			return trf(gtx, .Update_Failed, r.detail)
		}
	}
	return ""
}

// coverage_line says whether a retained Pro installation may take the
// candidate. None says nothing: the date does not apply.
@(private)
coverage_line :: proc(gtx: ^ui.Ctx, r: ^query.Update_Result) -> string {
	if r == nil {
		return ""
	}
	switch r.coverage {
	case .None:
		return ""
	case .Covered:
		return trf(gtx, .Update_Covered, r.paid_through)
	case .Later:
		return trf(gtx, .Update_Later, version.PRODUCT, r.paid_through, r.latest, r.released)
	case .Unstamped:
		return trf(gtx, .Update_Unstamped, version.PRODUCT, r.paid_through)
	}
	return ""
}

// guidance_line says which installer owns this copy, when one does.
@(private)
guidance_line :: proc(gtx: ^ui.Ctx, r: ^query.Update_Result) -> string {
	if r == nil {
		return ""
	}
	switch r.guidance {
	case .None:
		return ""
	case .Package:
		return tr(.Update_Package)
	case .Scoop:
		return tr(.Update_Scoop)
	case .App_Image:
		return tr(.Update_App_Image)
	case .Installer:
		return tr(.Update_Installer)
	case .Bundle:
		return tr(.Update_Bundle)
	case .Journal:
		return tr(.Update_Journal)
	case .Link:
		return tr(.Update_Link)
	case .Dev:
		return tr(.Update_Dev)
	}
	return ""
}

// notices_dialog is the licences of what leita is built on: each component's
// name, licence and page, and its notice as its licence words it, the window's
// own copy of gui/notices.
@(private)
notices_dialog :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if !m.notices_open {
		return
	}
	close := false
	buttons := [1]primer.Dialog_Button{{content = tr(.Close), clicked = &close}}
	if primer.dialog(
		gtx,
		&m.notices_open,
		tr(.Notices),
		footer = buttons[:],
		width = .XLarge,
		height = .Large,
	) {
		ui.column(gtx, gap = 24, align = .Start)
		primer.text(gtx, trf(gtx, .Notices_Intro, version.PRODUCT))
		for n, i in notices.ALL {
			component(gtx, n, u64(i + 1))
		}
		// WINDOWS is compiled on every OS so THIRD_PARTY.md can name what a
		// Windows build links. The dialog lists it only on Windows, where
		// those libraries are actually linked.
		when ODIN_OS == .Windows {
			for n, i in notices.WINDOWS {
				component(gtx, n, u64(len(notices.ALL) + i + 1))
			}
		}
	}
	if close {
		m.notices_open = false
	}
}

// component is one component in the licences dialog: its name, its licence and a
// link to its page, then its notice, the lines kept as they were written.
@(private)
component :: proc(gtx: ^ui.Ctx, n: notices.Notice, key: u64, loc := #caller_location) {
	ui.column(gtx, gap = 4, align = .Start, key = key, loc = loc)
	primer.heading(gtx, n.name, level = 3, variant = .Small)
	primer.text(gtx, n.licence, .Small, color = primer.color(.Fg_Color_Muted))
	if primer.link(gtx, n.url, size = tok.TEXT_BODY_SIZE_SMALL) {
		ui.open_url(gtx, n.url)
	}
	primer.text(gtx, n.text, .Small, white_space = .Pre_Wrap)
}

// about_mark is the mark at ABOUT_MARK_SIZE, in the scheme's ink, its find in sea.
@(private)
about_mark :: proc(gtx: ^ui.Ctx, loc := #caller_location) {
	p := ui.widget_open(gtx, loc = loc)
	mark.draw(gtx, {0, 0}, ABOUT_MARK_SIZE, primer.color(.Fg_Color_Default), mark.SEA)
	ui.widget_close(gtx, &p, {size = {ABOUT_MARK_SIZE, ABOUT_MARK_SIZE}})
}

// licence_line is the licence leita runs under, in a line, as the licence
// dialog says it: whose, or that scanning and cleanup are free and how long
// the Pro evaluation has left; "" until the host says.
@(private)
licence_line :: proc(gtx: ^ui.Ctx) -> string {
	r, _ := ui.need(gtx, query.Licence{}, query.Licence_Result)
	switch {
	case r == nil:
		return ""
	case r.licensed:
		return licensed_to(gtx, r)
	case r.trial_left > 0:
		return trf(gtx, .Free_Personal_Trial, trial_left(gtx, r))
	}
	return tr(.Free_Personal)
}
