/*
Package view is sonar's window, drawn in Primer: a frame of plain data that needs
what it shows and sends what the user asks for. It imports the contract (query,
command) and jm:ui, and nothing of the scan, so a test drives it with a ui.Probe
and shapes of its own making.

Nothing here waits. Every need is answered as soon as the host has anything, and
again each time the scan moves on, so a directory's listing appears, grows and
reorders while the reader is still inside it.
*/
package sonar_view

import "core:fmt"
import "core:strings"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../../human"
import "../command"
import "../query"

// SIDE_WIDTH is the side column's width: the open directory's contents and the
// largest files. The sunburst takes the rest.
SIDE_WIDTH :: 400

// PAD is the window's margin. On the right it stops short of the side column's
// scroll boxes, so their bars sit flush with the window's edge, and the rows
// inside carry it instead, clear of the bar.
PAD :: f32(16)

// SIZE_WIDTH is the size column's width in a listing row.
SIZE_WIDTH :: 84

// Font ids main registers: Primer's three weights and a monospace face.
FONTS :: primer.Fonts {
	normal   = 0,
	medium   = 1,
	semibold = 2,
	mono     = 3,
}

Model :: struct {
	path:       ui.Text_State,
	dark:       bool,
	scheme:     primer.Scheme,
	// The directory shown, as an index into the tree of that generation. Each scan
	// fills a tree of its own, so on a new one the view returns to its top.
	generation: u32,
	dir:        u32,
	scroll:     ui.Scroll_Offset,
	side:       ui.Scroll_Offset,
	// The pointer over the sunburst, and the size it was last drawn at, so a frame
	// can say what is under the pointer before it draws the disc.
	pointer:    ops.Point,
	inside:     bool,
	burst:      f32,
}

model_init :: proc(m: ^Model, path: string) {
	ui.text_set(&m.path, path)
	m.dir = query.ROOT
}

model_destroy :: proc(m: ^Model) {
	ui.text_destroy(&m.path)
}

// open makes dir the one shown, in the sunburst and the listing both.
open :: proc(m: ^Model, dir: u32) {
	m.dir = dir
	m.scroll = {}
}

view :: proc(gtx: ^ui.Ctx, user: rawptr) {
	m := (^Model)(user)
	theme: primer.Theme = m.dark ? .Dark : .Light
	m.scheme = primer.theme_scheme(theme)
	primer.use(&m.scheme, theme)
	primer.use_fonts(FONTS)
	ops.fill(
		gtx.scene,
		ops.Rect{0, 0, gtx.constraints.max.x, gtx.constraints.max.y},
		primer.color(.Bg_Color_Default),
	)

	prog, _ := ui.need(gtx, query.Progress{}, query.Progress_Result)
	if prog != nil && prog.generation != m.generation {
		m.generation = prog.generation
		m.dir = query.ROOT
		m.scroll = {}
		m.side = {}
	}

	ui.inset(gtx, {left = PAD, top = PAD, bottom = PAD})
	ui.column(gtx, gap = 12, align = .Fill)
	if ui.inset(gtx, {right = PAD}) {
		if ui.column(gtx, gap = 12, align = .Fill) {
			toolbar(gtx, m, prog)
			status(gtx, prog)
		}
	}
	if prog == nil || prog.generation == 0 {
		return
	}
	ui.flexible(gtx, 1)
	if ui.row(gtx, gap = 24, align = .Fill) {
		ui.flexible(gtx, 1)
		rings_panel(gtx, m)
		if ui.sized(gtx, {min = {SIDE_WIDTH, 0}, max = {SIDE_WIDTH, ui.INF}}) {
			if ui.column(gtx, gap = 24, align = .Fill) {
				ui.flexible(gtx, 3)
				listing(gtx, m)
				ui.flexible(gtx, 2)
				largest(gtx, m)
			}
		}
	}
}

// --- the bar along the top -----------------------------------------------------

@(private)
toolbar :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	ui.row(gtx, gap = 8, align = .Center)
	primer.heading(gtx, "sonar", level = 1, variant = .Medium)
	ui.spacer(gtx, 8)
	ui.flexible(gtx, 1)
	field := primer.text_input(
		gtx,
		&m.path,
		placeholder = "A directory, drive or image",
		leading = .File_Directory,
		block = true,
		name = "What to scan",
	)
	scanning := prog != nil && prog.state == .Scanning
	if scanning {
		if primer.button(gtx, "Stop", .Danger, leading = .Square_Fill) {
			ui.command(gtx, command.Command(command.Stop{}))
		}
	}
	if primer.button(
		   gtx,
		   scanning ? "Rescan" : "Scan",
		   scanning ? .Default : .Primary,
		   leading = .Search,
	   ) ||
	   field.submitted {
		path := strings.trim_space(ui.text_string(&m.path))
		if path != "" {
			ui.command(gtx, command.Command(command.Scan{path = command.text_make(path)}))
		}
	}
	if primer.icon_button(
		gtx,
		m.dark ? .Sun : .Moon,
		m.dark ? "Light theme" : "Dark theme",
		.Invisible,
	) {
		m.dark = !m.dark
	}
}

// --- how the scan is going -----------------------------------------------------

@(private)
status :: proc(gtx: ^ui.Ctx, prog: ^query.Progress_Result) {
	if prog == nil || prog.generation == 0 {
		primer.text(
			gtx,
			"Name a directory to see what is using the disk.",
			color = primer.color(.Fg_Color_Muted),
		)
		return
	}
	if ui.row(gtx, gap = 8, align = .Center) {
		switch prog.state {
		case .Scanning:
			primer.spinner(gtx, .Small, label = "Scanning")
		case .Done:
			primer.label(gtx, "Done", .Success)
		case .Stopped:
			primer.label(gtx, "Stopped", .Attention)
		case .Failed:
			primer.label(gtx, "Failed", .Danger)
		case .Idle:
		}
		primer.text(gtx, prog.target, weight = .Semibold)
		primer.text(gtx, counters(gtx, prog), color = primer.color(.Fg_Color_Muted))
	}
	if prog.state == .Failed && prog.problem != "" {
		primer.banner(gtx, "The scan failed", prog.problem, .Critical)
	}
	if prog.slow {
		primer.inline_message(
			gtx,
			"Reading this volume's own table would be far faster, given permission to open the device.",
			.Warning,
			.Small,
		)
	}
}

// counters is what the scan has found, in one line.
@(private)
counters :: proc(gtx: ^ui.Ctx, prog: ^query.Progress_Result) -> string {
	sb := strings.builder_make(gtx.allocator)
	fmt.sbprintf(
		&sb,
		"%s items · %s · %.1f s",
		human.count(prog.nodes),
		human.bytes(prog.bytes),
		prog.seconds,
	)
	if prog.engine != "" {
		fmt.sbprintf(&sb, " · %s", prog.engine)
	}
	if prog.pending > 0 {
		fmt.sbprintf(&sb, " · %s waiting on a parent", human.count(u64(prog.pending)))
	}
	return strings.to_string(sb)
}

// --- the directory shown -------------------------------------------------------

@(private)
listing :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ui.column(gtx, gap = 8, align = .Fill)
	if ui.inset(gtx, {right = PAD}) {
		primer.heading(gtx, "Contents", level = 2, variant = .Small)
	}
	r, _ := ui.need(
		gtx,
		query.Listing{generation = m.generation, dir = m.dir},
		query.Listing_Result,
	)
	if r == nil || r.generation != m.generation || len(r.crumbs) == 0 {
		for i in 0 ..< 6 {
			primer.skeleton_box(gtx, height = 28, delay = .Short, key = u64(i + 1))
		}
		return
	}

	if ui.inset(gtx, {right = PAD}) {
		primer.text(
			gtx,
			fmt.aprintf(
				"%s in %s items",
				human.bytes(r.bytes),
				human.count(u64(len(r.entries) + r.more)),
				allocator = gtx.allocator,
			),
			.Small,
			color = primer.color(.Fg_Color_Muted),
		)
	}

	ui.flexible(gtx, 1)
	if ui.scroll_box(gtx, offset = &m.scroll) {
		ui.inset(gtx, {right = PAD})
		if ui.column(gtx, gap = 2, align = .Fill) {
			if len(r.entries) == 0 {
				primer.text(gtx, "Nothing found here yet.", color = primer.color(.Fg_Color_Muted))
			}
			for e in r.entries {
				if entry(gtx, e, r.bytes) {
					open(m, e.node)
				}
			}
			if r.more > 0 {
				primer.text(
					gtx,
					fmt.aprintf(
						"and %s smaller items, %s between them",
						human.count(u64(r.more)),
						human.bytes(r.more_bytes),
						allocator = gtx.allocator,
					),
					.Small,
					color = primer.color(.Fg_Color_Muted),
				)
			}
		}
	}
}

// entry is one row of a listing: its name, its share of the directory as a bar,
// and its size. A directory's name opens it, and reports so.
@(private)
entry :: proc(gtx: ^ui.Ctx, e: query.Entry, total: u64) -> (opened: bool) {
	s := ui.scope_open(gtx, e.node)
	defer ui.scope_close(&s)
	ui.row(gtx, gap = 12, align = .Center)
	ui.flexible(gtx, 3)
	if e.directory {
		opened = primer.button(
			gtx,
			e.name,
			.Invisible,
			.Small,
			leading = .File_Directory_Fill,
			align = .Start,
			block = true,
		)
	} else if ui.row(gtx, gap = 8, align = .Center) {
		ui.spacer(gtx, 8)
		glyph(gtx, .File, primer.color(.Fg_Color_Muted))
		ui.flexible(gtx, 1)
		primer.truncate(gtx, e.name, max_width = ui.INF, size = .Small)
	}
	share := total > 0 ? 100 * f32(f64(e.bytes) / f64(total)) : 0
	ui.flexible(gtx, 2)
	primer.progress_bar(
		gtx,
		share,
		bg = e.directory ? .Bg_Color_Accent_Emphasis : .Bg_Color_Neutral_Emphasis,
		label = fmt.aprintf("%s share", e.name, allocator = gtx.allocator),
	)
	if ui.sized(gtx, {min = {SIZE_WIDTH, 0}, max = {SIZE_WIDTH, ui.INF}}) {
		if ui.column(gtx, align = .End) {
			primer.text(gtx, human.bytes(e.bytes), .Small)
		}
	}
	return
}

// --- the largest files anywhere ------------------------------------------------

@(private)
largest :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ui.column(gtx, gap = 8, align = .Fill)
	if ui.inset(gtx, {right = PAD}) {
		primer.heading(gtx, "Largest files", level = 2, variant = .Small)
	}
	r, _ := ui.need(gtx, query.Largest{generation = m.generation}, query.Largest_Result)
	if r == nil {
		return
	}
	if len(r.files) == 0 {
		if ui.inset(gtx, {right = PAD}) {
			primer.text(gtx, "None found yet.", .Small, color = primer.color(.Fg_Color_Muted))
		}
		return
	}
	ui.flexible(gtx, 1)
	if ui.scroll_box(gtx, offset = &m.side) {
		ui.inset(gtx, {right = PAD})
		if ui.column(gtx, gap = 10, align = .Fill) {
			for f in r.files {
				s := ui.scope_open(gtx, f.node)
				defer ui.scope_close(&s)
				if ui.column(gtx, gap = 2, align = .Fill) {
					primer.truncate(
						gtx,
						base_name(f.path),
						max_width = ui.INF,
						weight = .Semibold,
						size = .Small,
					)
					if ui.row(gtx, gap = 8, align = .Center) {
						ui.flexible(gtx, 1)
						primer.truncate(
							gtx,
							f.path,
							title = f.path,
							max_width = ui.INF,
							size = .Small,
							color = primer.color(.Fg_Color_Muted),
						)
						primer.text(gtx, human.bytes(f.bytes), .Small)
					}
				}
			}
		}
	}
}

// --- small parts ---------------------------------------------------------------

// glyph is a 16px octicon as a widget of its own.
@(private)
glyph :: proc(gtx: ^ui.Ctx, ic: primer.Icon, c: ops.Color, loc := #caller_location) {
	p := ui.widget_open(gtx, loc = loc)
	primer.icon(gtx, ic, {0, 0}, 16, c)
	ui.widget_close(gtx, &p, {size = {16, 16}})
}

@(private)
base_name :: proc(path: string) -> string {
	i := strings.last_index_any(path, `/\`)
	return path[i + 1:] if i >= 0 && i < len(path) - 1 else path
}
