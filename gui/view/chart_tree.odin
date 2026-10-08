package sonar_view

import "core:fmt"
import "core:slice"
import "core:strings"

import "jm:ui"
import "jm:ui/ops"

import "../../human"
import "../query"

/*
What a chart says to a screen reader. Each chart is drawn as one input area, so
it says itself as a tree a reader walks a layer at a time: the directory shown's
own entries, and under a folder opened in the tree, the folder's. A sighted
person takes the whole chart in at a glance; a reader takes it an item at a time,
so a layer holds only its largest entries and one item summing the rest.

Folders are opened and closed in the tree by toggle_said_open. Nothing calls it
yet: jm:ui passes a reader's focus and click requests on to the window but not
its expand and collapse (bridge_take_actions, jm/ui/shell/a11y.odin), and the
chart takes no keys of its own. Either, once there, opens a folder through it.
*/

// SAID_MOST is the most items a layer of a chart's tree holds before one item
// sums the rest. A reader hears a layer an item at a time, where a glance takes
// in a chart whole. The entries come largest first, so the fiftieth holds at most
// a fiftieth of the layer: the summary stands for its small end, each entry of it
// under 2% of the layer.
SAID_MOST :: 50

// ENTRY_KEY and REST_KEY mark the ids of a chart's entries and of its layers'
// summaries apart from each other and from the ids its tags use.
ENTRY_KEY :: 0xe7
REST_KEY  :: 0xe8

// entry_id is the id of the item for the entry at in the chart whose id is chart:
// mixed from its node, so it stays the same item from frame to frame.
@(private)
entry_id :: proc(chart: ops.Area_Id, r: ^query.Rings_Result, at: int) -> ops.Area_Id {
	return ui.id_mix(ui.id_mix(chart, ENTRY_KEY), u64(r.arcs[at].node))
}

// rest_id is the id of the item summing what is left of the layer under the
// entry at, or of the top layer for -1.
@(private)
rest_id :: proc(chart: ops.Area_Id, r: ^query.Rings_Result, at: int) -> ops.Area_Id {
	return ui.id_mix(ui.id_mix(chart, REST_KEY), u64(r.arcs[at].node) + 1 if at >= 0 else 0)
}

// toggle_said_open opens the folder node in the chart's tree, so its entries are
// a layer under it, or closes it.
@(private)
toggle_said_open :: proc(m: ^Model, node: u32) {
	if m.said_open[node] {
		delete_key(&m.said_open, node)
	} else {
		m.said_open[node] = true
	}
}

// Chart_Item is one item of a chart's tree as it is worked out, before it is emitted:
// its words end at end in the frame's buffer of them.
@(private)
Chart_Item :: struct {
	id, under: ops.Area_Id,
	rect:      ops.Rect,
	level:     u8,
	states:    ops.States,
	end:       int,
}

/*
Teller is what describe_chart works from. The entries the chart draws are listed
under the one each lies in, slot 0 for the top and an entry's index + 1 for its
own: first is a slot's first entry and next each entry's next, largest first, -1
ending them. rank is an entry's place in its slot, -1 for one not drawn.
*/
@(private)
Teller :: struct {
	gtx:    ^ui.Ctx,
	m:      ^Model,
	r:      ^query.Rings_Result,
	chart:  ops.Area_Id,
	here:   string,
	first:  []int,
	next:   []int,
	rank:   []int,
	rects:  []ops.Rect,
	chosen: ops.Area_Id, // the item said as selected, 0 for none
	words:  strings.Builder,
	items:  [dynamic]Chart_Item,
}

/*
describe_chart says what chart p draws to a screen reader. p is a tree named for
the chart, the directory shown, its size and how many entries the chart draws in
it. Its items are the top layer, the directory's entries the chart draws; a
folder opened in m.said_open has its own as a layer under it, down to what the
chart draws. A layer holds its SAID_MOST largest and one item more, "and N
smaller items, X between them" as the contents list says it, which counts only
the entries the chart draws past those: one too small to draw is in neither.

An item says what the info block says of its entry. A folder is expandable, and
expanded while it is open and something in it is drawn. The entry lit is
selected, or, where it is not an item, the item it is hidden in or summed by.
Each item's box is its entry's on screen in p's space, a summary's around all it
sums. The folders opened are forgotten with a new centre or scan.
*/
@(private)
describe_chart :: proc(
	gtx: ^ui.Ctx,
	p: ^ui.Placement,
	m: ^Model,
	r: ^query.Rings_Result,
	boxes: []Box,
	lit: int,
	chart: string,
) {
	if m.said_dir != r.dir || m.said_generation != r.generation {
		clear(&m.said_open)
		m.said_dir, m.said_generation = r.dir, r.generation
	}
	n := len(r.arcs)
	t := Teller {
		gtx   = gtx,
		m     = m,
		r     = r,
		chart = p.id,
		here  = base_name(r.crumbs[len(r.crumbs) - 1].name),
		first = make([]int, n + 1, gtx.allocator),
		next  = make([]int, n, gtx.allocator),
		rank  = make([]int, n, gtx.allocator),
		rects = make([]ops.Rect, n, gtx.allocator),
		words = strings.builder_make(gtx.allocator),
		items = make([dynamic]Chart_Item, gtx.allocator),
	}
	slice.fill(t.first, -1)
	slice.fill(t.rank, -1)
	// Boxes come in the order the host laid the arcs, each after the one it lies
	// in and its contents largest first (lay_ring in gui/app/app.odin; place and
	// lay_icicle keep it), so a slot's entries are in order as they are met.
	count := make([]int, n + 1, gtx.allocator)
	for b in boxes {
		if b.arc >= 0 {
			slot := int(r.arcs[b.arc].up) + 1
			t.rank[b.arc] = count[slot]
			count[slot] += 1
			t.rects[b.arc] = b.rect
		}
	}
	#reverse for b in boxes {
		if b.arc >= 0 {
			slot := int(r.arcs[b.arc].up) + 1
			t.next[b.arc] = t.first[slot]
			t.first[slot] = b.arc
		}
	}
	t.chosen = chosen_id(&t, lit)

	title := fmt.aprintf(
		"%s of %s, %s, %s item%s",
		chart,
		t.here,
		human.bytes(r.bytes),
		human.count(u64(count[0])),
		"" if count[0] == 1 else "s",
		allocator = gtx.allocator,
	)
	ui.semantics(gtx, p, {role = .Tree, label = title})

	// Every item's words go in one buffer, so a layer of fifty makes one string
	// rather than fifty, and are cut from it once it is whole.
	say_layer(&t, 0, 0, 1)
	words := strings.to_string(t.words)
	start := 0
	for it in t.items {
		ui.part_semantics(
			gtx,
			p,
			it.id,
			it.rect,
			{role = .Tree_Item, label = words[start:it.end], level = it.level, states = it.states},
			it.under,
		)
		start = it.end
	}
}

// chosen_id is the id of the item to say as selected for the entry lit, 0 for
// none: the entry's own where it is an item, else the folder it is hidden in or
// the summary it is counted in, whichever is met first on the way down to it.
@(private)
chosen_id :: proc(t: ^Teller, lit: int) -> ops.Area_Id {
	if lit < 0 {
		return 0
	}
	way: [query.RING_DEPTH]int
	n := 0
	for at := lit; at >= 0 && n < len(way); at = int(t.r.arcs[at].up) {
		way[n] = at
		n += 1
	}
	chosen: ops.Area_Id
	#reverse for at in way[:n] {
		if t.rank[at] < 0 {
			break
		}
		if t.rank[at] >= SAID_MOST {
			return rest_id(t.chart, t.r, int(t.r.arcs[at].up))
		}
		chosen = entry_id(t.chart, t.r, at)
		if !t.m.said_open[t.r.arcs[at].node] {
			break
		}
	}
	return chosen
}

// say_layer works out the items for the entries in slot, under the item under at
// level, and for the layer under each open folder among them.
@(private)
say_layer :: proc(t: ^Teller, slot: int, under: ops.Area_Id, level: u8) {
	r := t.r
	rest: int
	rest_bytes: u64
	rest_box: ops.Rect
	for at := t.first[slot]; at >= 0; at = t.next[at] {
		a := r.arcs[at]
		if t.rank[at] >= SAID_MOST {
			rest_box = t.rects[at] if rest == 0 else both_bounds(rest_box, t.rects[at])
			rest += 1
			rest_bytes += a.bytes
			continue
		}
		id := entry_id(t.chart, r, at)
		open := t.m.said_open[a.node] && t.first[at + 1] >= 0
		states: ops.States
		if a.directory {
			states += {.Expandable}
			if open {
				states += {.Expanded}
			}
		}
		if id == t.chosen {
			states += {.Selected}
		}
		share := r.bytes > 0 ? 100 * f64(a.bytes) / f64(r.bytes) : 0
		strings.write_string(&t.words, a.name)
		strings.write_string(&t.words, ", ")
		human.write_bytes(&t.words, a.bytes)
		fmt.sbprintf(&t.words, ", %.1f%% of ", share)
		strings.write_string(&t.words, t.here)
		if note := colour_note(t.gtx, t.m, r, at); note != "" {
			strings.write_string(&t.words, ", ")
			strings.write_string(&t.words, note)
		}
		append(&t.items, Chart_Item{id, under, t.rects[at], level, states, len(t.words.buf)})
		if open {
			say_layer(t, at + 1, id, level + 1)
		}
	}
	if rest > 0 {
		id := rest_id(t.chart, r, slot - 1)
		states: ops.States = {.Selected} if id == t.chosen else {}
		fmt.sbprintf(&t.words, "and %s smaller items, ", human.count(u64(rest)))
		human.write_bytes(&t.words, rest_bytes)
		strings.write_string(&t.words, " between them")
		append(&t.items, Chart_Item{id, under, rest_box, level, states, len(t.words.buf)})
	}
}

// both_bounds is the box around both a and b.
@(private)
both_bounds :: proc(a, b: ops.Rect) -> ops.Rect {
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
	return {x0, y0, x1 - x0, y1 - y0}
}
