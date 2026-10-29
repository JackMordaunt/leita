package leita_view

import "core:fmt"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../command"
import "../query"

// The search view in a probe, the host's answers made up by hand.

@(private = "file")
Search_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
searching_open :: proc(s: ^Search_Rig) {
	model_init(&s.m, "/top")
	s.m.settings_read = true
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
	settle(&s.h.p)
}

// settle runs frames until a change has laid out: a row lays out what it holds
// by the sizes they had the frame before.
@(private = "file")
settle :: proc(p: ^ui.Probe) {
	ui.probe_frame(p)
	ui.probe_frame(p)
}

@(private = "file")
searching_close :: proc(s: ^Search_Rig) {
	render.headless_destroy(&s.h)
	model_destroy(&s.m)
}

/*
	/top/src/          node 1
	/top/src/main.odin node 2
	/top/main/         node 4
*/
@(private = "file")
found := query.Search_Result {
	generation = 1,
	term       = "main",
	total      = 2,
	hits       = {
		{
			node = 4,
			parent = 0,
			path = "/top/main",
			name_at = 5,
			marks = {{5, 9}},
			bytes = 4096,
			directory = true,
		},
		{
			node = 2,
			parent = 1,
			path = "/top/src/main.odin",
			name_at = 9,
			marks = {{9, 13}},
			bytes = 100,
		},
	},
}

@(test)
the_magnifier_turns_the_location_into_a_search_and_escape_back :: proc(t: ^testing.T) {
	s: Search_Rig
	searching_open(&s)
	defer searching_close(&s)
	p := &s.h.p

	testing.expect(t, ui.probe_click(p, "Search"), "the magnifier is beside the location")
	settle(p)
	settle(p)
	testing.expect(t, s.m.searching)
	testing.expect_value(t, ui.probe_focus_name(p), "Search")

	// Typing asks the host; until it answers, a skeleton.
	ui.probe_type(p, "main")
	settle(p)
	q := query.Search {
		generation = 1,
		term       = "main",
	}
	testing.expect(t, ui.probe_needs_q(p, q), "the term is asked for")
	ui.probe_deliver(p, q, found)
	settle(p)
	testing.expect(t, ui.probe_tagged(p, "main"), "the folder is listed")
	testing.expect(t, ui.probe_tagged(p, "main.odin"), "the file is listed")
	testing.expect(t, ui.probe_tagged(p, "2 matches"))
	testing.expect(t, !ui.probe_tagged(p, "Sunburst chart"), "the charts give way")

	// A new term keeps what the last found until it is answered.
	ui.probe_type(p, "x")
	settle(p)
	testing.expect(t, ui.probe_needs_q(p, query.Search{generation = 1, term = "mainx"}))
	testing.expect(t, ui.probe_tagged(p, "main.odin"), "the last answer is held")
	ui.probe_deliver(
		p,
		query.Search{generation = 1, term = "mainx"},
		query.Search_Result{generation = 1, term = "mainx", complete = true},
	)
	settle(p)
	testing.expect(t, ui.probe_tagged(p, "Nothing matches “mainx”"))

	ui.probe_key(p, .Escape)
	settle(p)
	testing.expect(t, !s.m.searching, "Escape puts the location back")
	testing.expect_value(t, ui.text_string(&s.m.search), "")

	// Cmd/Ctrl+F opens it again, empty.
	ui.probe_key(p, .F, {ui.SHORTCUT})
	settle(p)
	testing.expect(t, s.m.searching)
	testing.expect_value(t, ui.text_string(&s.m.search), "")
}

@(test)
a_click_picks_a_hit_and_a_double_click_opens_it :: proc(t: ^testing.T) {
	s: Search_Rig
	searching_open(&s)
	defer searching_close(&s)
	p := &s.h.p

	open_search(&s.m)
	settle(p)
	settle(p)
	ui.probe_type(p, "main")
	settle(p)
	ui.probe_deliver(p, query.Search{generation = 1, term = "main"}, found)
	settle(p)

	// The grid lays the same hits out as tiles.
	testing.expect(t, ui.probe_click(p, "Grid"))
	settle(p)
	testing.expect(t, s.m.search_grid)
	testing.expect(t, ui.probe_tagged(p, "main.odin"))
	tile := ui.probe_bounds(p, "main.odin")
	testing.expectf(t, tile.w < 200 && tile.h > 100, "a tile, not a row: %v", tile)

	// A click picks, as a file browser's does, and opens nothing.
	testing.expect(t, ui.probe_click(p, "main.odin"))
	settle(p)
	testing.expect_value(t, s.m.search_pick, u32(2))
	testing.expect(t, s.m.searching, "the search stays")
	_, sent := opened(p)
	testing.expect(t, !sent, "a click opens nothing")

	// A double click opens it as the system would, as its second press lands.
	at, _ := ui.probe_center(p, "main.odin")
	ui.router_push(&p.router, {kind = .Press, pos = at, button = .Left, clicks = 2})
	ui.probe_frame(p)
	node, sent_open := opened(p)
	ui.router_push(&p.router, {kind = .Release, pos = at, button = .Left})
	settle(p)
	testing.expect(t, sent_open, "a double click opens")
	testing.expect_value(t, node, u32(2))
}

// many is a result of n hits, f0 to f<n-1>, nodes 10 on.
@(private = "file")
many :: proc(n: int) -> query.Search_Result {
	hits := make([]query.Hit, n, context.temp_allocator)
	// One mark for them all, made where it outlives this call.
	marks := make([]query.Mark, 1, context.temp_allocator)
	marks[0] = {5, 6}
	for &h, i in hits {
		h = {
			node    = u32(10 + i),
			parent  = 1,
			path    = fmt.tprintf("/top/f%d", i),
			name_at = 5,
			marks   = marks,
			bytes   = 1,
		}
	}
	return {generation = 1, term = "f", total = n, hits = hits, complete = true}
}

@(private = "file")
press :: proc(p: ^ui.Probe, key: ui.Key) {
	ui.probe_key(p, key)
	settle(p)
	settle(p)
}

// opened is the node the frame's commands last asked to open.
@(private = "file")
opened :: proc(p: ^ui.Probe) -> (node: u32, ok: bool) {
	for cmd in ui.probe_commands(p) {
		if v, is := ui.command_as(cmd, command.Command); is {
			if o, is_open := v.(command.Open); is_open {
				node, ok = o.entry.node, o.entry.generation == 1
			}
		}
	}
	return
}

@(test)
the_keys_move_through_the_hits_and_return_opens :: proc(t: ^testing.T) {
	s: Search_Rig
	searching_open(&s)
	defer searching_close(&s)
	p := &s.h.p

	open_search(&s.m)
	settle(p)
	settle(p)
	ui.probe_type(p, "f")
	settle(p)
	ui.probe_deliver(p, query.Search{generation = 1, term = "f"}, many(40))
	settle(p)

	// Down from the field picks the best, and focus goes with it.
	press(p, .Down)
	testing.expect_value(t, s.m.search_pick, u32(10))
	testing.expect_value(t, ui.probe_focus_name(p), "f0")
	press(p, .Down)
	testing.expect_value(t, ui.probe_focus_name(p), "f1")
	press(p, .End)
	testing.expect_value(t, ui.probe_focus_name(p), "f39")
	testing.expect(t, s.m.search_list.offset > 0, "the last is scrolled to")
	press(p, .Home)
	testing.expect_value(t, ui.probe_focus_name(p), "f0")
	press(p, .Page_Down)
	page := int(s.m.search_pick) - 10
	testing.expectf(t, page > 2, "a page is the rows in view: %d", page)
	press(p, .Page_Up)
	testing.expect_value(t, ui.probe_focus_name(p), "f0")
	// Left and Right move nothing in a list.
	press(p, .Right)
	testing.expect_value(t, ui.probe_focus_name(p), "f0")

	// Return opens the pick, in the frame it is pressed in.
	ui.probe_key(p, .Enter)
	node, sent := opened(p)
	testing.expect(t, sent, "Return opens")
	testing.expect_value(t, node, u32(10))

	// Typing goes on in the field.
	press(p, .Down)
	ui.probe_type(p, "x")
	settle(p)
	testing.expect_value(t, ui.text_string(&s.m.search), "fx")
	testing.expect_value(t, ui.probe_focus_name(p), "Search")
	ui.probe_deliver(p, query.Search{generation = 1, term = "fx"}, many(40))
	settle(p)
	// Return in the field opens the best, none being picked.
	ui.probe_key(p, .Enter)
	node, sent = opened(p)
	testing.expect(t, sent && node == 10, "Return in the field opens the best")
	settle(p)

	// Up from the first row goes back to the field too, and Escape.
	press(p, .Down)
	testing.expect_value(t, ui.probe_focus_name(p), "f0")
	press(p, .Up)
	testing.expect_value(t, ui.probe_focus_name(p), "Search")
	press(p, .Down)
	press(p, .Escape)
	testing.expect_value(t, ui.probe_focus_name(p), "Search")
	testing.expect(t, s.m.searching, "Escape in the hits keeps the search")

	// In a grid the arrows go across and down by the tiles in a row.
	s.m.search_grid = true
	settle(p)
	press(p, .Down)
	press(p, .Right)
	testing.expect_value(t, ui.probe_focus_name(p), "f1")
	press(p, .Down)
	columns := int(s.m.search_pick) - 11
	testing.expectf(t, columns > 1, "a row holds several tiles: %d", columns)
	press(p, .Left)
	testing.expect_value(t, int(s.m.search_pick), 10 + columns)
}

@(test)
icons_say_what_an_entry_is :: proc(t: ^testing.T) {
	testing.expect_value(t, icon_of("x", .Folder), primer.Icon.File_Directory_Fill)
	testing.expect_value(t, icon_of("song.FLAC", .Multimedia), primer.Icon.Unmute)
	testing.expect_value(t, icon_of("film.mkv", .Multimedia), primer.Icon.Video)
	testing.expect_value(t, icon_of("disk.iso", .Archive), primer.Icon.Database)
	testing.expect_value(t, icon_of("a.tar.gz", .Archive), primer.Icon.File_Zip)
	testing.expect_value(t, icon_of("README.md", .Text), primer.Icon.Markdown)
	testing.expect_value(t, icon_of("main.odin", .Text), primer.Icon.File_Code)
	testing.expect(t, thumbnailed("Photo.JPG"))
	testing.expect(t, !thumbnailed("photo.heic"), "Blend2D does not read it")
}

// Switching between the location and the search moves nothing else in the
// bar, not even for the frame the switch is first drawn in.
@(test)
the_bar_holds_still_as_the_search_opens_and_closes :: proc(t: ^testing.T) {
	s: Search_Rig
	searching_open(&s)
	defer searching_close(&s)
	p := &s.h.p
	settle(p)
	was := ui.probe_bounds(p, "Settings")
	testing.expect(t, was.w > 0, "the bar has its Settings button")
	bar := ui.probe_bounds(p, "Location")
	magnifier := ui.probe_bounds(p, "Search")

	still :: proc(t: ^testing.T, p: ^ui.Probe, was: ops.Rect, switching: string) {
		for i in 0 ..< 3 {
			ui.probe_frame(p)
			at := ui.probe_bounds(p, "Settings")
			testing.expectf(t, at == was, "%s, frame %d: Settings at %v, not %v", switching, i, at, was)
		}
	}
	ui.probe_key(p, .F, {ui.SHORTCUT})
	still(t, p, was, "opening")
	testing.expect(t, s.m.searching)
	// The field takes the place of the bar and the magnifier, inside it or
	// beside it.
	field := ui.probe_bounds(p, "Search")
	end := max(bar.x + bar.w, magnifier.x + magnifier.w)
	testing.expectf(t, field.x + field.w == end, "the field ends at %v, not %v", field.x + field.w, end)
	ui.probe_key(p, .Escape)
	still(t, p, was, "closing")
	testing.expect(t, !s.m.searching)

	ui.probe_key(p, .F, {ui.SHORTCUT})
	ui.probe_frame(p)
	at := ui.probe_bounds(p, "Search")
	testing.expectf(t, at == field, "opened again, first frame: field at %v, not %v", at, field)
}
