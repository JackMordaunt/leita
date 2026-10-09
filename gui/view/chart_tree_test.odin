package estoile_view

import "core:fmt"
import "core:strings"
import "core:testing"

import "jm:ui"

import "../query"

// Tree_Case is a sunburst drawn alone, with the entry it lights.
@(private = "file")
Tree_Case :: struct {
	m:   Model,
	r:   query.Rings_Result,
	lit: int,
}

@(private = "file")
tree_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	c := (^Tree_Case)(user)
	sunburst(gtx, &c.m, &c.r, c.lit)
}

/*
big_rings is a directory, top, of 130 KiB: a folder, big, of seventy 1 KiB files
g00 to g69, then sixty 1 KiB files f00 to f59, laid out as the host lays them.
big is node 2, each g node 100 on, each f node 200 on.
*/
@(private = "file")
big_rings :: proc() -> query.Rings_Result {
	arcs := make([dynamic]query.Arc, context.temp_allocator)
	total :: f32(130)
	append(
		&arcs,
		query.Arc {
			node = 2,
			name = "big",
			bytes = 70 * 1024,
			directory = true,
			depth = 1,
			sweep = 70 / total,
			up = -1,
			was = -1,
		},
	)
	for i in 0 ..< 70 {
		append(
			&arcs,
			query.Arc {
				node = u32(100 + i),
				name = fmt.tprintf("g%02d", i),
				bytes = 1024,
				depth = 2,
				start = f32(i) / total,
				sweep = 1 / total,
				up = 0,
				was = -1,
			},
		)
	}
	for i in 0 ..< 60 {
		append(
			&arcs,
			query.Arc {
				node = u32(200 + i),
				name = fmt.tprintf("f%02d", i),
				bytes = 1024,
				depth = 1,
				start = f32(70 + i) / total,
				sweep = 1 / total,
				up = -1,
				was = -1,
			},
		)
	}
	crumbs := make([]query.Crumb, 1, context.temp_allocator)
	crumbs[0] = {1, "/tmp/top"}
	return {generation = 1, dir = 1, crumbs = crumbs, bytes = 130 * 1024, was = -1, arcs = arcs[:]}
}

// said_after is whether, in a semantics report, a line starting with each of
// lines comes straight after one starting with the one before.
@(private = "file")
said_after :: proc(report: string, lines: ..string) -> bool {
	all := strings.split_lines(report, context.temp_allocator)
	for at in 0 ..= len(all) - len(lines) {
		found := true
		for want, i in lines {
			if !strings.has_prefix(all[at + i], want) {
				found = false
				break
			}
		}
		if found {
			return true
		}
	}
	return false
}

@(test)
a_chart_says_its_largest_entries_a_layer_at_a_time_and_sums_the_rest :: proc(t: ^testing.T) {
	c := Tree_Case {
		r   = big_rings(),
		lit = -1,
	}
	defer model_destroy(&c.m)
	p: ui.Probe
	ui.probe_init(&p, tree_frame, &c, {400, 400})
	defer ui.probe_destroy(&p)

	// The top layer: the fifty largest of its 61 entries, big closed, and one item
	// for the eleven left.
	big := `  tree item "big, 70.0 KiB, 53.8% of top" level 1 expandable at`
	f00 := `  tree item "f00, 1.0 KiB, 0.8% of top" level 1 at`
	f48 := `  tree item "f48, 1.0 KiB, 0.8% of top" level 1 at`
	top_rest := `  tree item "and 11 smaller items, 11.0 KiB between them" level 1 at`
	said := ui.probe_semantics(&p, context.temp_allocator)
	testing.expectf(
		t,
		said_after(said, `tree "Sunburst of top, 130.0 KiB, 61 items" at`, big, f00),
		"the chart counts its entries and says the largest first:\n%s",
		said,
	)
	testing.expectf(t, said_after(said, f48, top_rest), "the rest are summed:\n%s", said)
	items := strings.count(said, `tree item "`)
	testing.expectf(t, items == SAID_MOST + 1, "%d items in the top layer", items)

	// Opened, big's own entries are a layer under it, capped and summed the same.
	toggle_said_open(&c.m, 2)
	ui.probe_frame(&p)
	said = ui.probe_semantics(&p, context.temp_allocator)
	open := `  tree item "big, 70.0 KiB, 53.8% of top" level 1 expandable expanded at`
	g00 := `    tree item "g00, 1.0 KiB, 0.8% of top" level 2 at`
	g49 := `    tree item "g49, 1.0 KiB, 0.8% of top" level 2 at`
	big_rest := `    tree item "and 20 smaller items, 20.0 KiB between them" level 2 at`
	testing.expectf(t, said_after(said, open, g00), "big's entries nest under it:\n%s", said)
	testing.expectf(t, said_after(said, g49, big_rest, f00), "and are summed:\n%s", said)
	items = strings.count(said, `tree item "`)
	testing.expectf(t, items == 2 * (SAID_MOST + 1), "%d items with big open", items)

	// An entry lit past the cap selects the summary counting it.
	c.lit = 1 + 60 // g60
	ui.probe_frame(&p)
	said = ui.probe_semantics(&p, context.temp_allocator)
	testing.expectf(
		t,
		said_after(
			said,
			g49,
			`    tree item "and 20 smaller items, 20.0 KiB between them" level 2 selected at`,
		),
		"g60's summary is selected:\n%s",
		said,
	)

	// Closed again, big's entries go; so they do with a new scan.
	toggle_said_open(&c.m, 2)
	ui.probe_frame(&p)
	said = ui.probe_semantics(&p, context.temp_allocator)
	testing.expectf(
		t,
		said_after(
			said,
			`  tree item "big, 70.0 KiB, 53.8% of top" level 1 selected expandable at`,
			f00,
		),
		"closed, big is selected for g60 and holds no layer:\n%s",
		said,
	)
	toggle_said_open(&c.m, 2)
	c.r.generation = 2
	ui.probe_frame(&p)
	said = ui.probe_semantics(&p, context.temp_allocator)
	items = strings.count(said, `tree item "`)
	testing.expectf(t, items == SAID_MOST + 1, "a new scan closes big: %d items", items)
}
