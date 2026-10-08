package sonar_view

import "core:math"
import "core:testing"

import "jm:ui/ops"

import "../query"

@(test)
a_name_says_what_kind_of_file_it_is :: proc(t: ^testing.T) {
	testing.expect_value(t, kind_of("holiday.MKV", false), Kind.Multimedia)
	testing.expect_value(t, kind_of("libssl.so.3", false), Kind.Binary)
	testing.expect_value(t, kind_of("notes.txt", false), Kind.Text)
	testing.expect_value(t, kind_of("backup.tar.gz", false), Kind.Archive)
	testing.expect_value(t, kind_of("win11.iso", false), Kind.Archive)
	testing.expect_value(t, kind_of("README", false), Kind.Other)
	testing.expect_value(t, kind_of(".bashrc", false), Kind.Other)
	testing.expect_value(t, kind_of("node_modules", true), Kind.Cache)
	testing.expect_value(t, kind_of("photos", true), Kind.Folder)
}

// What a build or cache directory holds is build and cache, whatever it is.
@(test)
a_file_under_a_cache_is_cache :: proc(t: ^testing.T) {
	arcs := []query.Arc {
		{name = "project", directory = true, depth = 1, up = -1},
		{name = "node_modules", directory = true, depth = 2, up = 0},
		{name = "logo.png", depth = 3, up = 1},
		{name = "photo.png", depth = 2, up = 0},
	}
	r := query.Rings_Result {
		arcs = arcs,
	}
	testing.expect_value(t, kind_in(&r, 2), Kind.Cache)
	testing.expect_value(t, kind_in(&r, 3), Kind.Image)
	testing.expect_value(t, kind_in(&r, 0), Kind.Folder)
}

// Every pair of the kinds' colours stays at least 15 apart in OKLab (×100) to the
// eye, the dataviz skill's normal-vision floor. The colour-blind views are not
// checked here: KIND_COLOURS says how to run the skill's validator for them.
@(test)
the_kinds_colours_stay_apart :: proc(t: ^testing.T) {
	oklab :: proc(c: ops.Color) -> [3]f64 {
		lin :: proc(v: u8) -> f64 {
			s := f64(v) / 255
			return s / 12.92 if s <= 0.04045 else math.pow((s + 0.055) / 1.055, 2.4)
		}
		r, g, b := lin(c[0]), lin(c[1]), lin(c[2])
		l := math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
		m := math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
		s := math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
		return {
			0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
			1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
			0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
		}
	}
	coloured := 0
	for c in KIND_COLOURS {
		if c != {} {
			coloured += 1
		}
	}
	testing.expect_value(t, coloured, 7)
	for a in Kind {
		for b in Kind {
			if a >= b || KIND_COLOURS[a] == {} || KIND_COLOURS[b] == {} {
				continue
			}
			x, y := oklab(KIND_COLOURS[a]), oklab(KIND_COLOURS[b])
			d :=
				100 *
				math.sqrt(
					(x[0] - y[0]) * (x[0] - y[0]) +
					(x[1] - y[1]) * (x[1] - y[1]) +
					(x[2] - y[2]) * (x[2] - y[2]),
				)
			testing.expectf(t, d >= 15, "%v and %v are only %.1f apart", a, b, d)
		}
	}
}

// A lit entry always looks different from itself unlit: in either colouring, in a
// layout that frames directories or not, at the first ring and deeper.
@(test)
a_lit_entry_differs_from_itself_unlit :: proc(t: ^testing.T) {
	arcs := []query.Arc {
		{name = "photos", directory = true, depth = 1, up = -1},
		{name = "big.raw", depth = 2, up = 0},
		{name = "notes.txt", depth = 1, up = -1},
	}
	r := query.Rings_Result {
		arcs = arcs,
	}
	m: Model
	for colour in Colouring {
		m.colour = colour
		for framed in ([]bool{false, true}) {
			for _, at in arcs {
				lit, unlit := fill_of(&m, &r, at, true, framed), fill_of(&m, &r, at, false, framed)
				testing.expectf(
					t,
					lit != unlit,
					"%v, framed %v: %s lit is %v, the same as unlit",
					colour,
					framed,
					arcs[at].name,
					lit,
				)
			}
		}
	}
}

// A hovered row's entry lights its own arc, or, where the chart does not draw
// it, the nearest directory it lies in that the chart does.
@(test)
a_row_lights_its_entry_or_the_nearest_drawn_directory :: proc(t: ^testing.T) {
	arcs := []query.Arc {
		{node = 10, name = "photos", directory = true, depth = 1, up = -1},
		{node = 11, name = "big.raw", depth = 2, up = 0},
	}
	r := query.Rings_Result {
		arcs = arcs,
	}
	testing.expect_value(t, lit_by_row(&r, hover_of(11, {10, 1})), 1)
	// A file too deep to draw lights the directory holding it that is drawn.
	testing.expect_value(t, lit_by_row(&r, hover_of(42, {41, 10, 1})), 0)
	// One outside what is drawn lights nothing.
	testing.expect_value(t, lit_by_row(&r, hover_of(99, {98, 1})), -1)
	testing.expect_value(t, lit_by_row(&r, {}), -1)
}
