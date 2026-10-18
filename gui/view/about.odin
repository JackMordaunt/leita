package leita_view

import "core:fmt"

import "jm:ui"
import "jm:ui/primer"
import tok "jm:ui/primer/tokens"

import "../../version"
import mark "../mark"
import "../notices"
import "../query"

/*
About: About in the settings menu opens a dialog that says what this is and
whose: the mark and the name, the version, the business that makes it, what
it is for, the licence it runs under as the licence dialog says it, where to
read more, and a link to the licences of what it is built on, which opens a
dialog of every component's notice in its place.
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
// dialog says it: whose, or free for personal use and how long the trial has
// left; "" until the host says.
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
