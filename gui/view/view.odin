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
import "core:path/filepath"
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
	// Fewer script faces than SCRIPT_FONTS may be found; the slice is deleted at
	// its length, so it is given the length it is allocated with.
	shrink(&out)
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
	// the deepest, the trail it shows, and whether the path last entered was too
	// long to send, which the status says.
	editing:          bool,
	path_long:        bool,
	edit_focus:       bool,
	location_offset:  f32,
	location_follow:  bool,
	trail:            [dynamic]query.Crumb, // the way to the directory shown, names owned
	trail_generation: u32,
	titled:           string, // the place the window is named after, owned
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
	// The bar's field or the search closed from the keyboard, which was in it:
	// the magnifier takes the keyboard when next drawn, so it is not left on
	// the field that has gone.
	bar_focus:        bool,
	// dark is the appearance drawn. theme is the choice: Light and Dark stay,
	// and Unset and Auto follow the OS (settings.odin, apply_theme).
	dark:             bool,
	theme:            query.Theme_Choice,
	// told is whether the window was asked to match told_dark. The first
	// frame asks; a later frame asks when the appearance changes.
	told:             bool,
	told_dark:        bool,
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
	// The file last clicked in the treemap, by node (0 for none), and how long it has
	// waited for a double click (treemap.odin press_box).
	file_click:       u32,
	file_wait:        f32,
	// The entry the keys have picked in the chart, by node (0 for none), and whether
	// the pick stands for the pointer's: it does until the pointer moves
	// (chart_keys.odin).
	chart_pick:       u32,
	chart_keys:       bool,
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
	drawn:            bool, // a frame is done: no licence answer now means locked (unlocked)
	buy_url:          string,
	about_open:       bool, // the About dialog (about.odin)
	record_open:      bool, // the History dialog (record.odin)
	record_list:      ui.List_State,
	notices_open:     bool, // the licences of what leita is built on (about.odin)
	// The language in use and its text, whether the submenu of languages is open,
	// and the language the host was last told (language.odin).
	locale:           i18n.Locale,
	strings:          ^msg.Strings,
	language_open:    bool,
	theme_open:       bool,
	locale_told:      Maybe(i18n.Locale),
	// What the person chose in an earlier run has been put in use, whether the
	// settings menu is open, and the dialog chosen from it (settings.odin).
	settings_read:    bool,
	settings_open:    bool,
	settings_dialog:  Settings_Dialog,
	// What automatic checks were set to until the host answers (about.odin).
	checks_want:      Maybe(bool),
	// The Monitoring dialog (monitor.odin): whether it is open, the place typed
	// to watch, the change count when one was sent until the host answers,
	// what the switch was set to by the change in flight, if that is what it
	// was, the same of the recorder's switch, and whether the host has answered
	// since the dialog opened.
	monitor_open:     bool,
	watch_text:       ui.Text_State,
	monitor_sent:     Maybe(u32),
	monitor_want:     Maybe(bool),
	recorder_want:    Maybe(bool),
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
	delete(m.titled)
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
	defer m.drawn = true
	recall_settings(gtx, m)
	apply_theme(m)
	theme: primer.Theme = m.dark ? .Dark : .Light
	m.scheme = primer.theme_scheme(theme)
	primer.use(&m.scheme, theme)
	// This frame's appearance. A choice made while the frame draws changes
	// m.dark after this, and is told next frame with the page that frame paints.
	tell_window(gtx, m)
	// primer's scheme is thread-local and m.scheme is the Model's: cleared on return,
	// so no thread reads a Model that has since gone (a test's, on the stack).
	defer primer.use(nil)
	primer.use_fonts(FONTS)
	// The frame's language, cleared on return: words must not outlive the Model.
	words = m.strings
	defer words = nil
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
		m.path_long = false
		// The delete dialogs too: their Confirm would act on the new scan's
		// default selection, which the person has not seen.
		m.clean_open, m.empty_open = false, false
		m.trash_node, m.trash_bytes = 0, 0
		clear(&m.reclaim_pick)
		forget_history(m)
	}
	walk_history(gtx, m, prog)
	name_window(gtx, m, prog)
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
	if chart_lost(prog) && prog.problem != "" {
		// In the chart's place, not above it: a banner in the status column would
		// move the chart, and a scan that failed before it read anything has none to
		// show. One that grew a tree keeps its chart, and says why in the status.
		if ui.inset(gtx, {right = PAD}) {
			primer.banner(gtx, tr(.Scan_Failed), safe(gtx, prog.problem), .Critical)
		}
	} else {
		ui.flexible(gtx, 1)
		if term := search_term(m); term != "" {
			search_results(gtx, m, term)
			dialogs(gtx, m)
			record_dialog(gtx, m)
			monitor_dialog(gtx, m)
			return
		}
		chart_row(gtx, m)
	}
	dialogs(gtx, m)
	reclaim_dialogs(gtx, m)
	export_dialog(gtx, m, prog)
	licence_dialog(gtx, m)
	about_dialog(gtx, m)
	record_dialog(gtx, m)
	notices_dialog(gtx, m)
	monitor_dialog(gtx, m)
}

// chart_lost is whether the scan failed with nothing read, so there is no chart to
// keep.
@(private)
chart_lost :: proc(prog: ^query.Progress_Result) -> bool {
	return prog.state == .Failed && prog.nodes == 0
}

/*
chart_row is the chart beside its side panel, the grip between them. The chart
takes what the grip and the side column leave, sized from this frame's width: a
weighted chart before them would take its share from the frame before
(ui.flexible), so on the frame a scan first lands in the side column would sit
past the window, and the Fill column, as wide as its widest row, would widen
every banner above it for that frame (card 814).
*/
@(private)
chart_row :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ui.row(gtx, align = .Fill)
	was, was_shown := side_shown(gtx, m)
	offered := ui.offer(gtx).max.x
	if ui.is_finite(offered) {
		chart := max(offered - GRIP - (was if was_shown else 0), 1)
		if ui.sized(gtx, {min = {chart, 0}, max = {chart, ui.INF}}) {
			rings_panel(gtx, m)
		}
	} else {
		ui.flexible(gtx, 1)
		rings_panel(gtx, m)
	}
	// A drag moves the column on the frame it lands, as before, and the chart
	// follows on the next, which it asks for.
	side_grip(gtx, m)

	width, shown := side_shown(gtx, m)
	if width != was || shown != was_shown {
		ui.request_frame(gtx)
	}

	if shown {
		if ui.sized(gtx, {min = {width, 0}, max = {width, ui.INF}}) {
			side(gtx, m)
		}
	}
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
	title(gtx, version.PRODUCT)
	ui.spacer(gtx, 8)
	ui.flexible(gtx, 1)
	location_bar(gtx, m, prog)
	settings_menu(gtx, m, prog)
}

/*
location_bar is the location bar with the magnifier beside it, or the search field
in the place of both. It is one child of the toolbar either way, and sizes the
bar from this frame's width: a row offers a stretched child what its other
children took the frame before (ui.flexible), so were the magnifier the
toolbar's own child, the buttons after it would jump for the frame the search
closes, as the_bar_holds_still_as_the_search_opens_and_closes saw.
*/
@(private)
location_bar :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	ui.row(gtx, gap = 8, align = .Center)
	if m.searching {
		search_field(gtx, m)
		return
	}
	magnifier := prog != nil && prog.generation != 0
	width := gtx.constraints.max.x
	if magnifier {
		width -= tok.CONTROL_MEDIUM_SIZE + 8
	}
	if !ui.is_finite(width) {
		location(gtx, m, prog)
	} else if ui.sized(gtx, {min = {width, 0}, max = {width, ui.INF}}) {
		location(gtx, m, prog)
	}
	if magnifier {
		search_button(gtx, m)
		// Not while a dialog is open or one the settings menu chose is about
		// to: the keyboard is the dialog's.
		if m.bar_focus && !m.editing && !dialog_open(m) && m.settings_dialog == .None {
			ui.focus_request(gtx, ui.last_widget(gtx).id)
		}
	}
	if !m.editing {
		m.bar_focus = false
	}
}

// --- how the scan is going -----------------------------------------------------

/*
status is two lines tall, always, so the chart under it keeps its place: a
primer.slot two lines of body text high holds, on the first, how the scan is
going and what it has found, and on the second the one message that matters
most, if any. Messages do not stack: the second line shows the first of them
and says how many more there are, which its tooltip lists. The banner a failed
scan that read nothing shows stands in the chart's place (view), and the trial banner, which the
licence answer brings at startup, keeps its place in flow under the slot.
*/
@(private)
status :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	if prog == nil || prog.generation == 0 {
		if primer.slot(gtx, lines = 2) {
			if m.path_long {
				path_long_line(gtx)
			} else {
				primer.text(gtx, tr(.Status_Empty), color = primer.color(.Fg_Color_Muted))
			}
		}
		renewal_banner(gtx)
		update_notice(gtx)
		return
	}
	if primer.slot(gtx, lines = 2) {
		if ui.column(gtx, align = .Fill) {
			state_line(gtx, prog)
			message_line(gtx, m, prog)
		}
	}
	notice(gtx, m, prog.notice)
	trial_banner(gtx, m)
	renewal_banner(gtx)
	update_notice(gtx)
}

// state_line is the status' first line: the scan's state, its counters, and
// how it read its place as a muted fragment whose tooltip says the whole.
@(private)
state_line :: proc(gtx: ^ui.Ctx, prog: ^query.Progress_Result) {
	ui.row(gtx, gap = 8, align = .Center)
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
	// The counters and how the place was read, with no gap between them: the
	// fragment starts with the " · " that joins the counters, its space a
	// no-break one, since a line's leading plain space is not drawn.
	ui.row(gtx, align = .Center)
	primer.text(gtx, counters(gtx, prog), color = primer.color(.Fg_Color_Muted))
	if tip := retention_tip(gtx, prog); tip != "" {
		primer.tooltip(gtx, tip, ui.last_widget(gtx))
	}
	short, whole := how_read(gtx, prog)
	if short == "" {
		return
	}
	ui.stack(gtx)
	primer.text(
		gtx,
		strings.concatenate({"\u00A0· ", short}, gtx.allocator),
		white_space = .Nowrap,
		color = primer.color(.Fg_Color_Muted),
	)
	primer.tooltip(gtx, whole, ui.last_widget(gtx))
}

// retention_tip is the snapshot and delayed-purge sentence for the counters.
// It is a tooltip, not another status line: the chart keeps the room under
// the two-line status.
@(private)
retention_tip :: proc(gtx: ^ui.Ctx, prog: ^query.Progress_Result) -> string {
	if prog == nil || !prog.retention_known {
		return ""
	}
	key: msg.Msg
	switch prog.snapshots {
	case 1:
		key = .Snap_None
	case 2:
		key = .Snap_Present
	case:
		key = .Snap_Unchecked
	}
	tip := tr(key)
	if prog.purge_known {
		tip = strings.concatenate({tip, " ", trf(gtx, .Purge_Later, human.bytes(prog.purgeable))}, gtx.allocator)
	}
	return tip
}

// Status_Message is one thing the status' second line can say: a warning, in
// the attention colour behind an alert, or a plain muted note. detail is what
// its tooltip adds, "" for nothing.
@(private)
Status_Message :: struct {
	text:    string,
	detail:  string,
	warning: bool,
	danger:  bool, // a warning that is an error
}

// status_messages is what the second line could say, the most pressing first:
// that the scan failed or was stopped and the chart is short for it; folders
// the scan could not open, and on macOS, where a refusal is commonly a folder
// the system guards under the home directory, how to let the window in; that a
// raw read would be far faster; then why the scan read its place whole. The
// problem of a scan that failed with nothing read is the banner's (view).
@(private)
status_messages :: proc(
	gtx: ^ui.Ctx,
	m: ^Model,
	prog: ^query.Progress_Result,
) -> []Status_Message {
	msgs := make([dynamic]Status_Message, gtx.allocator)
	switch {
	case prog.state == .Failed && !chart_lost(prog):
		why := trf(gtx, .Scan_Failed_Why, safe(gtx, prog.problem))
		append(&msgs, Status_Message{text = why, detail = why, warning = true, danger = true})
	case prog.state == .Stopped:
		append(&msgs, Status_Message{text = tr(.Stopped_Incomplete), warning = true})
	}
	if m.path_long {
		append(&msgs, Status_Message{text = tr(.Path_Too_Long), warning = true})
	}
	if prog.unread > 0 {
		detail := ""
		if ODIN_OS == .Darwin && prog.denied {
			detail = trf(gtx, .Unread_Hint, version.PRODUCT)
		}
		append(
			&msgs,
			Status_Message {
				text = trf(gtx, .Unread_Folders, int(prog.unread)),
				detail = detail,
				warning = true,
			},
		)
	}
	if prog.slow {
		append(&msgs, Status_Message{text = tr(.Slow_Hint), warning = true})
	}
	if prog.kept && !prog.updated && prog.why != "" {
		append(&msgs, Status_Message{text = trf(gtx, .Read_Whole, prog.why)})
	}
	return msgs[:]
}

// path_long_line is the status before any scan, when the path typed was too long:
// the warning mark and the reason, in the place of the invitation to name a
// directory.
@(private)
path_long_line :: proc(gtx: ^ui.Ctx) {
	fg := primer.color(.Fg_Color_Attention)
	ui.row(gtx, gap = 8, align = .Center)
	alert(gtx, fg)
	primer.text(gtx, tr(.Path_Too_Long), color = fg)
}

// message_line is the status' second line: the first of status_messages on one
// line, cut with an ellipsis rather than wrapped so the slot never grows, then
// "+N more" when others apply, listed in its tooltip. Nothing when there is
// nothing to say; the slot keeps the line's height.
@(private)
message_line :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	msgs := status_messages(gtx, m, prog)
	if len(msgs) == 0 {
		return
	}
	ui.row(gtx, gap = 8, align = .Center)
	top := msgs[0]
	role: tok.Role = .Fg_Color_Muted
	if top.warning {
		role = .Fg_Color_Danger if top.danger else .Fg_Color_Attention
	}
	fg := primer.color(role)
	if top.warning {
		alert(gtx, fg)
	}
	ui.flexible(gtx, 1)
	if ui.stack(gtx) {
		primer.truncate(
			gtx,
			top.text,
			title = top.detail,
			max_width = ui.INF,
			inline = true,
			color = fg,
		)
		primer.tooltip(gtx, top.detail, ui.last_widget(gtx))
	}
	if len(msgs) == 1 {
		return
	}
	rest := make([dynamic]string, gtx.allocator)
	for it in msgs[1:] {
		append(&rest, it.text)
	}
	ui.stack(gtx)
	primer.text(
		gtx,
		trf(gtx, .More_Messages, len(rest)),
		white_space = .Nowrap,
		color = primer.color(.Fg_Color_Muted),
	)
	primer.tooltip(gtx, strings.join(rest[:], "\n", gtx.allocator), ui.last_widget(gtx))
}

// alert is the second line's warning mark: a filled alert 12px high, as
// primer.inline_message draws it at small, centred on a line of body text.
@(private)
alert :: proc(gtx: ^ui.Ctx, fg: ops.Color, loc := #caller_location) {
	p := ui.widget_open(gtx, loc = loc)
	side := f32(12)
	line := primer.text_style(.Medium).line_height
	primer.icon(gtx, .Alert_Fill, {0, (line - side) / 2}, side, fg)
	ui.widget_close(gtx, &p, {size = {side, line}})
}

// how_read is how a scan with history on read its place, as the command line's
// summary says it (survey.how_read), in the window's language: short is the
// fragment the counters line carries, whole the sentence its tooltip says, with
// the count and date of an update or the reason for a whole read. Both "" with
// history off.
@(private)
how_read :: proc(gtx: ^ui.Ctx, prog: ^query.Progress_Result) -> (short, whole: string) {
	if !prog.kept {
		return
	}
	if prog.updated {
		since := taken_text(prog.since, gtx.allocator)
		return tr(.Read_Updated_Short), trf(gtx, .Read_Updated, int(prog.reread), since)
	}
	short = tr(.Read_Whole_Short)
	if prog.why != "" {
		whole = trf(gtx, .Read_Whole, prog.why)
	}
	return
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
		// Within the gutter the rows will keep.
		ui.inset(gtx, {right = PAD})
		ui.column(gtx, gap = 8, align = .Fill)
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
// any name opens the entry's menu. The name and the bar share what the size
// leaves, 3 to 2, sized from this frame's width: a weighted child before the
// size would take its share from the frame before, so the frame a listing
// lands in would lay the row out wider than the column (ui.flexible).
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
	GAP :: 12
	ui.row(gtx, gap = GAP, align = .Center)
	width := ui.offer(gtx).max.x
	// A size limit of 0 is none: an unbounded width leaves the cells natural.
	free := max(width - SIZE_WIDTH - 2 * GAP, 1) if ui.is_finite(width) else 0

	name_cell := ui.sized_open(gtx, {min = {free * 3 / 5, 0}, max = {free * 3 / 5, ui.INF}})
	clicked, name := name_button(gtx, e.name, e.directory ? .File_Directory_Fill : .File)
	ui.close(&name_cell)

	opened = clicked && e.directory
	row_menu(gtx, m, .Contents, name, {node = e.node, name = e.name, directory = e.directory})
	if ui.widget_state(gtx, name.id).hovered {
		m.row_hover_next = hover_of(e.node)
	}
	share := total > 0 ? 100 * f32(f64(e.bytes) / f64(total)) : 0
	if ui.sized(gtx, {min = {free * 2 / 5, 0}, max = {free * 2 / 5, ui.INF}}) {
		primer.progress_bar(
			gtx,
			share,
			bg = e.directory ? .Bg_Color_Accent_Emphasis : .Bg_Color_Neutral_Emphasis,
			label = trf(gtx, .Share_Of, safe(gtx, e.name)),
		)
	}
	if ui.sized(gtx, {min = {SIZE_WIDTH, 0}, max = {SIZE_WIDTH, ui.INF}}) {
		if ui.column(gtx, align = .End) {
			primer.text(gtx, human.bytes(e.bytes), .Small)
			if e.directory {
				primer.tooltip(gtx, tr(.Folder_Charged), ui.last_widget(gtx))
			}
			size_notes(gtx, e.bytes, e.logical, e.logical_known, e.frees, e.frees_known)
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
					// The path starts under the icon, where the name's button
					// starts its contents, not at the button's edge.
					ui.inset(gtx, {left = tok.CONTROL_SMALL_PADDING_INLINE_CONDENSED})
					file_line(gtx, m, f, r.compared)
				}
			}
		}
	}
}

/*
file_line is a largest file's line under its name: its path, then its size and
notes. The sizes are recorded first and the path takes the width they leave, so
the line fits on the frame it lands in, where a weighted path before them would
take its share from the frame before (ui.flexible). Sizes that would leave the
path less than half the line go on lines of their own under it, wrapping.
*/
@(private)
file_line :: proc(gtx: ^ui.Ctx, m: ^Model, f: query.File, compared: bool) {
	GAP :: 8
	width := ui.offer(gtx).max.x
	finite := ui.is_finite(width)
	rec := ui.record_open(gtx, {max = {width if finite else ui.INF, ui.INF}})
	if ui.wrap(gtx, gap = GAP, line_gap = 0, align = .Center) {
		primer.text(gtx, human.bytes(f.bytes), .Small)
		size_notes(gtx, f.bytes, f.logical, f.logical_known, f.frees, f.frees_known)
		if m.colour == .Change {
			if d := delta_text(f.bytes, f.was, compared, gtx.allocator); d != "" {
				primer.text(gtx, d, .Small, color = primer.color(.Fg_Color_Muted))
			}
		}
	}
	sizes, dims := ui.record_close(&rec)

	if !finite || dims.size.x + GAP <= width / 2 {
		ui.row(gtx, gap = GAP, align = .Center)
		// A size limit of 0 is none, so an unbounded width leaves the path natural.
		path := width - dims.size.x - GAP if finite else 0
		if ui.sized(gtx, {min = {path, 0}, max = {path, ui.INF}}) {
			file_path(gtx, f.path)
		}
		place_recording(gtx, sizes, dims)
	} else {
		ui.column(gtx, align = .Fill)
		file_path(gtx, f.path)
		place_recording(gtx, sizes, dims)
	}
}

// file_path is a largest file's path, cut to its width, the raw path in its tip.
@(private)
file_path :: proc(gtx: ^ui.Ctx, path: string) {
	stack := ui.stack_open(gtx)
	defer ui.close(&stack)

	primer.truncate(
		gtx,
		safe(gtx, path),
		title = raw_tip_text(gtx, path),
		max_width = ui.INF,
		size = .Small,
		color = primer.color(.Fg_Color_Muted),
	)
	show_raw_tip(gtx, path, ui.last_widget(gtx))
}

// --- small parts ---------------------------------------------------------------

// place_recording is a widget the size of a recorded run (ui.record_open) that
// draws it.
@(private)
place_recording :: proc(gtx: ^ui.Ctx, run: ops.Macro_Id, dims: ui.Dims, loc := #caller_location) {
	p := ui.widget_open(gtx, loc = loc)
	ops.call(gtx.scene, run)
	ui.widget_close(gtx, &p, dims)
}

// TITLE is the window's name in the toolbar: Primer's semibold title face at 24px,
// between its medium (20px) and large (32px) steps, a brand rather than a page
// heading.
TITLE :: tok.Type_Style {
	weight      = tok.BASE_TEXT_WEIGHT_SEMIBOLD,
	size        = 24,
	line_height = 32,
}

// window_title is the window's name for a scan of path: on macOS the folder's
// own name alone, as a Finder window carries its folder's and a TextEdit window
// its file's; elsewhere the name and then the product, as Notepad and Explorer
// title theirs. The title bar alone shows it; the toolbar keeps the product.
window_title :: proc(path: string, allocator := context.temp_allocator) -> string {
	name := filepath.base(path)
	when ODIN_OS == .Darwin {
		return strings.clone(name, allocator)
	} else {
		return strings.concatenate({name, " — ", version.PRODUCT}, allocator)
	}
}

// name_window names the window after the place scanned, as each scan starts.
@(private)
name_window :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	if prog == nil || prog.target == "" || prog.target == m.titled {
		return
	}
	delete(m.titled)
	m.titled = strings.clone(prog.target)
	ui.set_window_title(gtx, window_title(human.shown(prog.target)))
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

// size_notes is the length, and what deleting this one entry frees, under its
// charged size. A frees quantity is shown only when it is exact and differs
// from the charge. Unknown is a phrase, and only when a known length differs.
@(private)
size_notes :: proc(
	gtx: ^ui.Ctx,
	charged, logical: u64,
	logical_known: bool,
	frees: u64,
	frees_known: bool,
) {
	muted := primer.color(.Fg_Color_Muted)
	if logical_known && logical != charged {
		primer.text(gtx, trf(gtx, .Listing_Length, human.bytes(logical)), .Small, color = muted)
	}
	if frees_known && frees != charged {
		primer.text(gtx, trf(gtx, .Deleting_Frees, human.bytes(frees)), .Small, color = muted)
	} else if !frees_known && logical_known && logical != charged {
		primer.text(gtx, tr(.Deleting_Unknown), .Small, color = muted)
	}
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
	stack := ui.stack_open(gtx)
	clicked = primer.button(
		gtx,
		safe(gtx, label),
		.Invisible,
		.Small,
		leading = ic,
		align = .Start,
		block = true,
	)
	button = ui.last_widget(gtx)
	show_raw_tip(gtx, label, button)
	if ui.is_finite(width) && width > NAME_FADE {
		bg := primer.color(.Bg_Color_Default)
		clear := bg
		clear[3] = 0
		stops := make([]ops.Gradient_Stop, 2, gtx.allocator)
		stops[0], stops[1] = {0, clear}, {1, bg}
		edge := ops.Rect{width - NAME_FADE, 0, NAME_FADE, button.size.y}
		ops.fill(gtx.scene, edge, ops.Linear_Gradient{{edge.x, 0}, {width, 0}, stops})
	}
	ui.close(&stack)
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

/*
safe is name as the window draws it: a line break, an escape or a bidi override
in it, which a disk allows in a name, is a picture of itself (human.shown), so a
name cannot split a dialog, a row or a menu, or make the text around it read
differently. A bounded tooltip exposes the original bytes separately. What is
sent to the host, and what a field edits to be sent, is the real name.
*/
@(private)
safe :: proc(gtx: ^ui.Ctx, name: string) -> string {
	return human.shown(name, gtx.allocator)
}

// Raw names stay inside a tooltip, capped at 128 runes and four explicit lines.
// An ellipsis marks a shortened preview, including pathological disk names.
@(private)
raw_tip_text :: proc(gtx: ^ui.Ctx, name: string) -> string {
	count, lines := 0, 1
	for r, i in name {
		line_break := r == '\n' || r == '\r' || r == '\u0085' || r == '\u2028' || r == '\u2029'
		if count == 128 || (line_break && lines == 4) {
			return strings.concatenate({name[:i], "…"}, gtx.allocator)
		}
		count += 1
		if line_break {
			lines += 1
		}
	}
	return name
}

@(private)
show_raw_tip :: proc(gtx: ^ui.Ctx, name: string, anchor: ui.Last_Widget) {
	primer.tooltip(gtx, raw_tip_text(gtx, name), anchor)
}

@(private)
base_name :: proc(path: string) -> string {
	i := strings.last_index_any(path, `/\`)
	return path[i + 1:] if i >= 0 && i < len(path) - 1 else path
}
