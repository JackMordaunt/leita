/*
Package view is leita's window, drawn in Primer: a frame of plain data that needs
what it shows and sends what the user asks for. It imports the contract (query,
command) and jm:ui, and nothing of the scan, so a test drives it with a ui.Probe
and shapes of its own making.

Nothing here waits. Every need is answered as soon as the host has anything, and
again each time the scan moves on, so a directory's listing appears, grows and
reorders while the reader is still inside it.
*/
package leita_view

import "core:fmt"
import "core:os"
import "core:strings"

import "jm:i18n"
import "jm:ui"
import "jm:ui/design"
import "jm:ui/ops"
import "jm:ui/primer"
import tok "jm:ui/primer/tokens"

import "../../human"
import "../../version"
import "../command"
import mark "../mark"
import "../msg"
import "../query"

// SIDE_WIDTH is the side column's width until it is dragged: the open directory's
// contents and the largest files. The sunburst takes the rest.
SIDE_WIDTH :: 400

// PAD is the window's margin. On the right it stops short of the side column's
// scroll boxes, so their bars sit flush with the window's edge, and the rows
// inside carry it instead, clear of the bar.
PAD :: f32(16)

// SIZE_WIDTH is the size column's width in a listing row.
SIZE_WIDTH :: 84

// fonts are the faces FONTS names, for whatever opens the window: jm:ui's default
// font at Primer's three weights, and again as the monospace face; then a face
// for each script it lacks that the system has (SCRIPT_FONTS), which fallbacks
// names. The caller deletes the slice.
fonts :: proc(allocator := context.allocator) -> []ops.Font_Ref {
	path := ui.default_font()
	out := make([dynamic]ops.Font_Ref, 0, 4 + len(SCRIPT_FONTS), allocator)
	weights := [3]f32{400, 500, 600}
	for w, i in weights {
		append(&out, ops.Font_Ref{id = ops.Font_Id(i), path = path, weight = w})
	}
	append(&out, ops.Font_Ref{id = 3, path = path, weight = 400})
	for candidates in SCRIPT_FONTS {
		for file in candidates {
			if os.exists(file) {
				append(&out, ops.Font_Ref{id = ops.Font_Id(len(out)), path = file, weight = 400})
				break
			}
		}
	}
	return out[:]
}

// fallbacks are the ids of the script faces in faces, as fonts made them, for
// the shaper to try in order for a character the asked-for face lacks. The
// caller deletes the slice.
fallbacks :: proc(faces: []ops.Font_Ref, allocator := context.allocator) -> []ops.Font_Id {
	ids := make([]ops.Font_Id, max(len(faces) - 4, 0), allocator)
	for &id, i in ids {
		id = faces[4 + i].id
	}
	return ids
}

/*
SCRIPT_FONTS are faces for the scripts the default font lacks that the window's
languages need, each a list of where it may be, the first found used: Chinese
and Japanese, then Korean where the first has no Hangul. Cyrillic needs none:
Liberation Sans, SF and Arial, the default fonts, have it. A collection's first
face is the one read, so Noto Sans CJK draws Han in its Japanese forms.
*/
SCRIPT_FONTS := [?][]string {
	{
		"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc", // Arch
		"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", // Debian, Ubuntu
		"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc", // Fedora
		"/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
		"/System/Library/Fonts/Hiragino Sans GB.ttc",
		"C:/Windows/Fonts/msyh.ttc",
	},
	{"/System/Library/Fonts/AppleSDGothicNeo.ttc", "C:/Windows/Fonts/malgun.ttf"},
}

// Font ids main registers: Primer's three weights and a monospace face.
FONTS :: primer.Fonts {
	normal   = 0,
	medium   = 1,
	semibold = 2,
	mono     = 3,
}

Model :: struct {
	path:             ui.Text_State,
	// The location bar (location.odin): whether it is the field, whether the field
	// is still to take focus, how far its steps are scrolled, whether they follow
	// the deepest, and the trail it shows.
	editing:          bool,
	edit_focus:       bool,
	location_offset:  f32,
	location_follow:  bool,
	trail:            [dynamic]query.Crumb, // the way to the directory shown, names owned
	trail_generation: u32,
	// Searching (search.odin): whether the location bar is the search field,
	// what it holds, whether it is still to take focus, whether what was found
	// is laid out as a grid, how far it is scrolled, and the last term answered
	// in which scan, shown until the one typed is. Then the hit picked, by
	// node (0, the top, is never one), whether the keys are in the hits rather
	// than the field, whether to open the pick, whether to scroll it into
	// view, and how tall the hits' viewport was last frame.
	searching:        bool,
	search:           ui.Text_State,
	search_focus:     bool,
	search_grid:      bool,
	search_list:      ui.List_State,
	search_held:      string,
	search_scan:      u32,
	search_pick:      u32,
	search_keys:      bool,
	search_go:        bool,
	search_move:      bool,
	search_view:      f32,
	dark:             bool,
	scheme:           primer.Scheme,
	// The directory shown, as an index into the tree of that generation. Each scan
	// fills a tree of its own, so on a new one the view returns to its top.
	generation:       u32,
	dir:              u32,
	scroll:           ui.Scroll_Offset,
	side:             ui.Scroll_Offset,
	// The pointer over the sunburst, and the size it was last drawn at, so a frame
	// can say what is under the pointer before it draws the disc.
	pointer:          ops.Point,
	inside:           bool,
	burst:            f32,
	// The way back and forth through the directories opened (actions.odin).
	back:             [dynamic]u32,
	forward:          [dynamic]u32,
	// The right-click menu, what it is about, and the questions it can ask.
	target:           Target,
	menu_open:        bool,
	menu_at:          ops.Point, // in the sunburst's space
	menu_from:        Menu_From,
	trash_open:       bool,
	rename_open:      bool,
	rename:           ui.Text_State,
	rename_focus:     bool, // the rename field takes focus when next drawn
	notice_seen:      u32, // the notice last made a toast
	toasts:           primer.Toasts, // the notices floating over the window
	// The side column: its width as dragged (0 for SIDE_WIDTH), whether a drag has
	// folded it away, and the share of its height the contents list takes (0 for
	// SPLIT). The *_from fields are where a drag began.
	side_width:       f32,
	side_closed:      bool,
	side_from:        f32,
	split:            f32,
	split_from:       f32,
	// The sunburst's arcs as drawn last frame, by node, and the centre they were
	// drawn around (sunburst.odin ease); poses_next is the frame being drawn.
	poses:            map[u32]Pose,
	poses_next:       map[u32]Pose,
	poses_dir:        u32,
	poses_generation: u32,
	// How the directory shown is drawn, and the treemap's boxes as drawn last
	// frame by node, around which centre, in what room (treemap.odin).
	mode:             Mode,
	colour:           Colouring,
	// The type chips: those turned on, and the one under the pointer this frame.
	kinds_on:         bit_set[Kind],
	kind_hover:       Maybe(Kind),
	// The last rings and listing asked for that were answered, shown until the
	// directory just opened is (need_held).
	rings_held:       query.Rings,
	listing_held:     query.Listing,
	boxes:            map[u32]ops.Rect,
	boxes_next:       map[u32]ops.Rect,
	boxes_dir:        u32,
	boxes_generation: u32,
	tree_room:        ops.Size,
	// The folders opened in the chart's tree for a screen reader, by node, and the
	// centre and scan they were opened in (chart_tree.odin).
	said_open:        map[u32]bool,
	said_dir:         u32,
	said_generation:  u32,
	// The row hovered, in the contents or the largest files: the frame's rows say so
	// as they are drawn, after the chart, so the chart reads the last frame's.
	row_hover:        Hover,
	row_hover_next:   Hover,
	// Reclaim mode (reclaim.odin): what the person chose and unchose, its list's
	// scroll, and its two questions, the second about the Trash it names.
	reclaim_pick:     map[u32]bool,
	reclaim_scroll:   ui.List_State,
	clean_open:       bool,
	empty_open:       bool,
	trash_node:       u32,
	trash_bytes:      u64,
	// Colouring by change (change.odin): whether the menu of snapshots is open.
	since_open:       bool,
	// Exporting a report (export.odin): the dialog and what it was last set to,
	// whether the save dialog it opens is still asking where, the notice id
	// when Export was sent until the host takes it up, and the notice of each
	// file saved, by the toast that shows it.
	export_open:      bool,
	export_format:    command.Export_Format,
	export_reclaim:   bool,
	export_picking:   bool,
	export_sent:      Maybe(u32),
	saved_toasts:     map[int]u32,
	// The licence dialog (licence.odin): whether it is open, the licence pasted,
	// the offer count when one was sent until the host answers, whether it has
	// answered since the dialog opened, and where Buy goes ("" for BUY_URL).
	licence_open:     bool,
	licence_text:     ui.Text_State,
	licence_waiting:  Maybe(u32),
	licence_answered: bool,
	licence_why:      Maybe(msg.Msg), // why a paid feature opened it, nil for none
	trial_seen:       bool, // the trial banner was dismissed, until leita next starts
	buy_url:          string,
	about_open:       bool, // the About dialog (about.odin)
	// The language in use and its text, whether the menu of languages is open,
	// and the language the host was last told (language.odin).
	locale:           i18n.Locale,
	strings:          ^msg.Strings,
	language_open:    bool,
	locale_told:      Maybe(i18n.Locale),
	// What the person chose in an earlier run has been put in use (settings.odin).
	settings_read:    bool,
	// The Monitoring dialog (monitor.odin): whether it is open, the place typed
	// to watch, the change count when one was sent until the host answers, and
	// whether it has answered since the dialog opened.
	monitor_open:     bool,
	watch_text:       ui.Text_State,
	monitor_sent:     Maybe(u32),
	monitor_answered: bool,
	monitor_part:     Monitor_Part, // where the last change was asked from
	// The alerts editor (monitor.odin): whether it is open, under which place,
	// its fields, and whether they last failed to read.
	limits_open:      bool,
	limits_place:     string,
	limit_warn:       ui.Text_State,
	limit_fail:       ui.Text_State,
	limit_free:       ui.Text_State,
	limit_days:       ui.Text_State,
	limit_growth:     bool,
	limits_bad:       bool,
	// The webhook field and whether the one typed may carry folder paths.
	hook_text:        ui.Text_State,
	hook_paths:       bool,
}

// model_init readies m to show path in locale, English unless the caller says.
model_init :: proc(m: ^Model, path: string, locale := i18n.Locale.English) {
	ui.text_set(&m.path, path)
	m.strings = new(msg.Strings)
	msg.init(m.strings, locale)
	m.locale = msg.locale(m.strings)
	m.dir = query.ROOT
	m.toasts.allocator = context.allocator
	m.export_format = .Pdf
	// The shop's sandbox, for a build that is tried against it.
	m.buy_url = os.get_env("LEITA_BUY_URL", context.allocator)
}

model_destroy :: proc(m: ^Model) {
	ui.text_destroy(&m.path)
	ui.text_destroy(&m.rename)
	ui.text_destroy(&m.licence_text)
	ui.text_destroy(&m.search)
	ui.text_destroy(&m.watch_text)
	ui.text_destroy(&m.limit_warn)
	ui.text_destroy(&m.limit_fail)
	ui.text_destroy(&m.limit_free)
	ui.text_destroy(&m.limit_days)
	ui.text_destroy(&m.hook_text)
	delete(m.limits_place)
	delete(m.search_held)
	delete(m.buy_url)
	free(m.strings)
	delete(m.back)
	delete(m.forward)
	delete(m.target.name)
	delete(m.poses)
	delete(m.poses_next)
	delete(m.boxes)
	delete(m.boxes_next)
	delete(m.said_open)
	delete(m.reclaim_pick)
	delete(m.saved_toasts)
	primer.toasts_destroy(&m.toasts)
	forget_trail(m)
	delete(m.trail)
}

view :: proc(gtx: ^ui.Ctx, user: rawptr) {
	m := (^Model)(user)
	recall_settings(gtx, m)
	theme: primer.Theme = m.dark ? .Dark : .Light
	m.scheme = primer.theme_scheme(theme)
	primer.use(&m.scheme, theme)
	primer.use_fonts(FONTS)
	words = m.strings
	tell_language(gtx, m)
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
		m.menu_open, m.trash_open, m.rename_open = false, false, false
		m.export_open = false
		clear(&m.reclaim_pick)
		forget_history(m)
	}
	walk_history(gtx, m)
	// Last frame's hovered row is this frame's to show; a change needs the frame
	// that shows it.
	if m.row_hover != m.row_hover_next {
		ui.request_frame(gtx)
	}
	m.row_hover, m.row_hover_next = m.row_hover_next, {}

	ui.inset(gtx, {left = PAD, top = PAD, bottom = PAD})
	ui.column(gtx, gap = 12, align = .Fill)
	if ui.inset(gtx, {right = PAD}) {
		if ui.column(gtx, gap = 12, align = .Fill) {
			toolbar(gtx, m, prog)
			status(gtx, m, prog)
		}
	}
	if prog == nil || prog.generation == 0 {
		return
	}
	ui.flexible(gtx, 1)
	if term := search_term(m); term != "" {
		search_results(gtx, m, term)
		dialogs(gtx, m)
		monitor_dialog(gtx, m)
		return
	}
	if ui.row(gtx, align = .Fill) {
		ui.flexible(gtx, 1)
		rings_panel(gtx, m)
		side_grip(gtx, m)
		if width, shown := side_shown(gtx, m); shown {
			if ui.sized(gtx, {min = {width, 0}, max = {width, ui.INF}}) {
				side(gtx, m)
			}
		}
	}
	dialogs(gtx, m)
	reclaim_dialogs(gtx, m)
	export_dialog(gtx, m, prog)
	licence_dialog(gtx, m)
	about_dialog(gtx, m)
	monitor_dialog(gtx, m)
}

// --- the side column ----------------------------------------------------------

// SIDE_MIN is the narrowest the side column is dragged to, and SIDE_FOLD the width
// below which a drag folds it away. SUNBURST_MIN is what the side column always
// leaves the sunburst. SPLIT is the share of the column's height the contents list
// takes until the grip between the lists is dragged, and LIST_MIN the least
// either list is given.
SIDE_MIN     :: f32(240)
SIDE_FOLD    :: f32(160)
SUNBURST_MIN :: f32(320)
SPLIT        :: f32(0.6)
LIST_MIN     :: f32(120)

// side_width is the width the side column is dragged to, or its default.
side_width :: proc(m: ^Model) -> f32 {
	return m.side_width if m.side_width > 0 else SIDE_WIDTH
}

/*
side_shown is the width the side column is drawn at in this window, and whether it
is drawn at all. It never takes so much the chart is left less than SUNBURST_MIN;
where that leaves it less than SIDE_MIN, it folds away until the window is wide
enough again, as a drag below SIDE_FOLD folds it, without forgetting its width.
*/
@(private)
side_shown :: proc(gtx: ^ui.Ctx, m: ^Model) -> (width: f32, shown: bool) {
	room := gtx.viewport.x - PAD - GRIP - SUNBURST_MIN
	width = min(side_width(m), room)
	return width, !m.side_closed && width >= SIDE_MIN
}

/*
side_grip is the grip between the sunburst and the side column. Dragged left
it widens the column, up to what leaves the sunburst SUNBURST_MIN; dragged right
it narrows it to SIDE_MIN, and past SIDE_FOLD the column folds away, live, so the
drag shows where it will end. Folded, the grip stays at the window's edge, and a
drag out of it brings the column back. A double click folds or unfolds it.
*/
@(private)
side_grip :: proc(gtx: ^ui.Ctx, m: ^Model) {
	value := tr(.Folded_Away) if m.side_closed else trf(gtx, .Points_Wide, int(side_width(m)))
	g := grip(gtx, .Horizontal, tr(.Resize_Panels), value)
	most := max(gtx.viewport.x - SUNBURST_MIN - GRIP - PAD, SIDE_MIN)
	switch {
	case g.double:
		m.side_closed = !m.side_closed
	case g.started:
		m.side_from = 0 if m.side_closed else side_width(m)
	case g.dragging:
		wanted := m.side_from - g.pull
		m.side_closed = wanted < SIDE_FOLD
		if !m.side_closed {
			m.side_width = clamp(wanted, SIDE_MIN, most)
		}
	case g.step != 0 && !m.side_closed:
		m.side_width = clamp(side_width(m) - g.step, SIDE_MIN, most)
	}
}

// side is the side column: the contents list above the largest files, the
// grip between them sharing its height.
@(private)
side :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ui.inset(gtx, {left = 8})
	ui.column(gtx, align = .Fill)
	height := gtx.constraints.max.y
	if !ui.is_finite(height) {
		listing(gtx, m)
		largest(gtx, m)
		return
	}
	room := max(height - GRIP, 2 * LIST_MIN)
	share := m.split if m.split > 0 else SPLIT
	top := clamp(share * room, LIST_MIN, room - LIST_MIN)
	if ui.sized(gtx, {min = {0, top}, max = {ui.INF, top}}) {
		listing(gtx, m)
	}
	g := grip(gtx, .Vertical, tr(.Resize_Lists), trf(gtx, .Split_Contents, int(100 * top / room)))
	switch {
	case g.double:
		m.split = 0
	case g.started:
		m.split_from = top
	case g.dragging:
		m.split = clamp(m.split_from + g.pull, LIST_MIN, room - LIST_MIN) / room
	case g.step != 0:
		m.split = clamp(top + g.step, LIST_MIN, room - LIST_MIN) / room
	}
	ui.flexible(gtx, 1)
	largest(gtx, m)
}

// --- the bar along the top -----------------------------------------------------

@(private)
toolbar :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	ui.row(gtx, gap = 8, align = .Center)
	logo(gtx)
	title(gtx, version.NAME)
	ui.spacer(gtx, 8)
	ui.flexible(gtx, 1)
	if m.searching {
		search_field(gtx, m)
	} else {
		location(gtx, m, prog)
		if prog != nil && prog.generation != 0 {
			search_button(gtx, m)
		}
	}
	export_button(gtx, m, prog)
	switch {
	case prog != nil && prog.state == .Scanning:
		if primer.button(gtx, tr(.Stop), .Danger, leading = .Square_Fill) {
			ui.command(gtx, command.Command(command.Stop{}))
		}
	case prog != nil && prog.target != "":
		// Scanning the same place again picks up what changed on disk since.
		if primer.icon_button(gtx, .Sync, tr(.Rescan), .Invisible) {
			ui.command(gtx, command.Command(command.Scan{path = command.text_make(prog.target)}))
		}
	}
	monitor_button(gtx, m, prog)
	licence_button(gtx, m)
	language_button(gtx, m)
	about_button(gtx, m)
	if primer.icon_button(
		gtx,
		m.dark ? .Sun : .Moon,
		tr(.Theme_Light) if m.dark else tr(.Theme_Dark),
		.Invisible,
	) {
		m.dark = !m.dark
		ui.command(gtx, command.Command(command.Theme{dark = m.dark}))
	}
}

// --- how the scan is going -----------------------------------------------------

@(private)
status :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	if prog == nil || prog.generation == 0 {
		primer.text(gtx, tr(.Status_Empty), color = primer.color(.Fg_Color_Muted))
		return
	}
	if ui.row(gtx, gap = 8, align = .Center) {
		switch prog.state {
		case .Scanning:
			primer.spinner(gtx, .Small, label = tr(.Scanning))
		case .Done:
			primer.label(gtx, tr(.Done), .Success)
		case .Stopped:
			primer.label(gtx, tr(.Stopped), .Attention)
		case .Failed:
			primer.label(gtx, tr(.Failed), .Danger)
		case .Idle:
		}
		primer.text(gtx, counters(gtx, prog), color = primer.color(.Fg_Color_Muted))
	}
	notice(gtx, m, prog.notice)
	trial_banner(gtx, m)
	if prog.state == .Failed && prog.problem != "" {
		primer.banner(gtx, tr(.Scan_Failed), prog.problem, .Critical)
	}
	if prog.slow {
		primer.inline_message(gtx, tr(.Slow_Hint), .Warning, .Small)
	}
}

// counters is what the scan has found, in one line.
@(private)
counters :: proc(gtx: ^ui.Ctx, prog: ^query.Progress_Result) -> string {
	parts := make([dynamic]string, gtx.allocator)
	append(&parts, trf(gtx, .Count_Items, int(prog.nodes)), human.bytes(prog.bytes))
	// The disk beside what the scan found, so the two can be read together.
	if prog.disk_total > 0 {
		append(
			&parts,
			trf(gtx, .Count_Free, human.bytes(prog.disk_free), human.bytes(prog.disk_total)),
		)
	}
	append(&parts, trf(gtx, .Count_Seconds, fmt.tprintf("%.1f", prog.seconds)))
	if prog.engine != "" {
		append(&parts, prog.engine)
	}
	if prog.pending > 0 {
		append(&parts, trf(gtx, .Count_Pending, prog.pending))
	}
	return strings.join(parts[:], " · ", gtx.allocator)
}

// --- the directory shown -------------------------------------------------------

@(private)
listing :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ui.column(gtx, gap = 8, align = .Fill)
	if ui.inset(gtx, {right = PAD}) {
		primer.heading(gtx, tr(.Contents), level = 2, variant = .Small)
	}
	r := need_held(
		gtx,
		query.Listing{generation = m.generation, dir = m.dir},
		&m.listing_held,
		query.Listing_Result,
	)
	if r == nil {
		for i in 0 ..< 6 {
			primer.skeleton_box(gtx, height = 28, delay = .Short, key = u64(i + 1))
		}
		return
	}

	if ui.inset(gtx, {right = PAD}) {
		primer.text(
			gtx,
			strings.concatenate(
				{
					trf(gtx, .Listing_Summary, len(r.entries) + r.more, human.bytes(r.bytes)),
					change_note(gtx, r.bytes, r.was, r.compared) if m.colour == .Change else "",
				},
				gtx.allocator,
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
				primer.text(gtx, tr(.Listing_Empty), color = primer.color(.Fg_Color_Muted))
			}
			for e in r.entries {
				if entry(gtx, m, e, r.bytes, r.compared) {
					open(m, e.node)
				}
			}
			if r.more > 0 {
				primer.text(
					gtx,
					trf(gtx, .Listing_More, r.more, human.bytes(r.more_bytes)),
					.Small,
					color = primer.color(.Fg_Color_Muted),
				)
			}
		}
	}
}

// entry is one row of a listing: its name, its share of the directory as a bar,
// and its size. A directory's name opens it, and reports so; a right click on
// any name opens the entry's menu.
@(private)
entry :: proc(
	gtx: ^ui.Ctx,
	m: ^Model,
	e: query.Entry,
	total: u64,
	compared: bool,
) -> (
	opened: bool,
) {
	s := ui.scope_open(gtx, e.node)
	defer ui.scope_close(&s)
	ui.row(gtx, gap = 12, align = .Center)
	ui.flexible(gtx, 3)
	clicked, name := name_button(gtx, e.name, e.directory ? .File_Directory_Fill : .File)
	opened = clicked && e.directory
	row_menu(gtx, m, .Contents, name, {node = e.node, name = e.name, directory = e.directory})
	if ui.widget_state(gtx, name.id).hovered {
		m.row_hover_next = hover_of(e.node)
	}
	share := total > 0 ? 100 * f32(f64(e.bytes) / f64(total)) : 0
	ui.flexible(gtx, 2)
	primer.progress_bar(
		gtx,
		share,
		bg = e.directory ? .Bg_Color_Accent_Emphasis : .Bg_Color_Neutral_Emphasis,
		label = trf(gtx, .Share_Of, e.name),
	)
	if ui.sized(gtx, {min = {SIZE_WIDTH, 0}, max = {SIZE_WIDTH, ui.INF}}) {
		if ui.column(gtx, align = .End) {
			primer.text(gtx, human.bytes(e.bytes), .Small)
			if m.colour == .Change {
				if d := delta_text(e.bytes, e.was, compared, gtx.allocator); d != "" {
					primer.text(gtx, d, .Small, color = primer.color(.Fg_Color_Muted))
				}
			}
		}
	}
	return
}

// --- the largest files anywhere ------------------------------------------------

@(private)
largest :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ui.column(gtx, gap = 8, align = .Fill)
	if ui.inset(gtx, {right = PAD}) {
		primer.heading(gtx, tr(.Largest_Files), level = 2, variant = .Small)
	}
	r, _ := ui.need(gtx, query.Largest{generation = m.generation}, query.Largest_Result)
	if r == nil {
		return
	}
	if len(r.files) == 0 {
		if ui.inset(gtx, {right = PAD}) {
			primer.text(gtx, tr(.Largest_None), .Small, color = primer.color(.Fg_Color_Muted))
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
					// The name opens the directory holding the file.
					clicked, name := name_button(gtx, base_name(f.path), .File)
					if clicked {
						open(m, f.parent)
					}
					row_menu(gtx, m, .Largest, name, {node = f.node, name = base_name(f.path)})
					if ui.widget_state(gtx, name.id).hovered {
						m.row_hover_next = hover_of(f.node, f.within)
					}
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
						if m.colour == .Change {
							if d := delta_text(f.bytes, f.was, r.compared, gtx.allocator);
							   d != "" {
								primer.text(gtx, d, .Small, color = primer.color(.Fg_Color_Muted))
							}
						}
					}
				}
			}
		}
	}
}

// --- small parts ---------------------------------------------------------------

// TITLE is the window's name in the toolbar: Primer's semibold title face at 24px,
// between its medium (20px) and large (32px) steps, a brand rather than a page
// heading.
TITLE :: tok.Type_Style {
	weight      = tok.BASE_TEXT_WEIGHT_SEMIBOLD,
	size        = 24,
	line_height = 32,
}

// title is s set in TITLE, read as the window's one first-level heading.
@(private)
title :: proc(gtx: ^ui.Ctx, s: string, loc := #caller_location) {
	p := ui.widget_open(gtx, loc = loc)
	para := design.layout_style(gtx, s, TITLE, primer.font_for(gtx, TITLE.weight))
	design.draw_paragraph(gtx, para, {0, 0}, primer.color(.Fg_Color_Default))
	ops.tag(gtx.scene, p.id, s)
	ui.semantics(gtx, &p, {role = .Heading, level = 1, label = s})
	ui.widget_close(gtx, &p, {size = {para.width, para.height}})
}

/*
need_held asks for q, a directory's rings or listing, and returns its answer; until
that lands, it asks again for held, the last such query that had one in this scan,
and returns that answer instead, so opening a directory shows what was there until
what is there now arrives rather than nothing for the frames between. A query is
held once it is answered. nil only before anything in this scan has been.
*/
@(private)
need_held :: proc(gtx: ^ui.Ctx, q: $Q, held: ^Q, $R: typeid) -> ^R {
	answered :: proc(r: ^R, generation: u32) -> bool {
		return r != nil && r.generation == generation && len(r.crumbs) > 0
	}
	if r, _ := ui.need(gtx, q, R); answered(r, q.generation) {
		held^ = q
		return r
	}
	if held.generation != q.generation || held^ == q {
		return nil
	}
	if r, _ := ui.need(gtx, held^, R); answered(r, q.generation) {
		return r
	}
	return nil
}

// NO_NODE names no node.
NO_NODE :: max(u32)

// Hover is a hovered row's entry, then the directories it lies in, nearest first,
// so the chart can light the nearest of them it draws when it does not draw the
// entry itself: a largest file is often deeper or smaller than any arc.
Hover :: struct {
	nodes: [65]u32,
	n:     int,
}

hover_of :: proc(node: u32, within: []u32 = nil) -> (h: Hover) {
	h.nodes[0], h.n = node, 1
	for up in within {
		if h.n == len(h.nodes) {
			break
		}
		h.nodes[h.n] = up
		h.n += 1
	}
	return
}

// lit_by_row is the arc the hovered row stands for in r: its entry's, else the
// nearest directory's it lies in that r draws, or -1. The directory at the
// centre has no arc, so a file outside what is drawn lights nothing.
lit_by_row :: proc(r: ^query.Rings_Result, h: Hover) -> int {
	h := h
	for node in h.nodes[:h.n] {
		if i := arc_of(r, node); i >= 0 {
			return i
		}
	}
	return -1
}

// arc_of is the index of the arc for node in r, or -1.
@(private)
arc_of :: proc(r: ^query.Rings_Result, node: u32) -> int {
	if node == NO_NODE {
		return -1
	}
	for a, i in r.arcs {
		if a.node == node {
			return i
		}
	}
	return -1
}

// NAME_FADE is how far a name too long for its cell fades out before its end.
NAME_FADE :: f32(32)

/*
name_button is a list row's name: an invisible button as wide as it is offered,
clipped there, with its last NAME_FADE points fading into the background so a long
name trails off rather than running under what sits beside it. It returns the
button, for a menu anchored to it.
*/
@(private)
name_button :: proc(
	gtx: ^ui.Ctx,
	label: string,
	ic: primer.Icon,
	loc := #caller_location,
) -> (
	clicked: bool,
	button: ui.Last_Widget,
) {
	clip := ui.clip_box_open(gtx, loc = loc)
	width := gtx.constraints.max.x
	clicked = primer.button(
		gtx,
		label,
		.Invisible,
		.Small,
		leading = ic,
		align = .Start,
		block = true,
	)
	button = ui.last_widget(gtx)
	if ui.is_finite(width) && width > NAME_FADE {
		bg := primer.color(.Bg_Color_Default)
		clear := bg
		clear[3] = 0
		stops := make([]ops.Gradient_Stop, 2, gtx.allocator)
		stops[0], stops[1] = {0, clear}, {1, bg}
		edge := ops.Rect{width - NAME_FADE, 0, NAME_FADE, button.size.y}
		ops.fill(gtx.scene, edge, ops.Linear_Gradient{{edge.x, 0}, {width, 0}, stops})
	}
	ui.clip_box_close(&clip)
	return
}

// LOGO is the mark's size in the toolbar, about the heading's cap height
// and a half.
LOGO :: 34

// logo is leita's mark, the found cell, in the scheme's ink, its find in sea.
@(private)
logo :: proc(gtx: ^ui.Ctx, loc := #caller_location) {
	p := ui.widget_open(gtx, loc = loc)
	mark.draw(gtx, {0, 0}, LOGO, primer.color(.Fg_Color_Default), mark.SEA)
	ui.widget_close(gtx, &p, {size = {LOGO, LOGO}})
}

@(private)
base_name :: proc(path: string) -> string {
	i := strings.last_index_any(path, `/\`)
	return path[i + 1:] if i >= 0 && i < len(path) - 1 else path
}
